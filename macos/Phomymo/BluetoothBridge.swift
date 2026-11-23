// SPDX-License-Identifier: Apache-2.0

import AppKit
import CoreBluetooth
import SwiftUI
import WebKit

/// Native half of the Web Bluetooth polyfill (WebBluetoothPolyfill.js).
///
/// Each editor window owns one bridge. The page posts `{op: ..., ...}` messages
/// to the `phomymoBLE` handler and gets a promise back; values and disconnects
/// travel the other way through `window.__phomymoBLE.event(...)`.
///
/// Errors are replied as "ErrorName|message" so the polyfill can rebuild a
/// DOMException with the name Web Bluetooth callers expect.
final class BluetoothBridge: NSObject, WKScriptMessageHandlerWithReply {
    typealias Reply = (Any?, String?) -> Void

    static let handlerName = "phomymoBLE"

    weak var webView: WKWebView?

    private var central: CBCentralManager?
    private var peripherals: [String: CBPeripheral] = [:]

    /// Replies waiting on a CoreBluetooth delegate callback, keyed by operation.
    private var pending: [String: Reply] = [:]
    private var connectTimeouts: [String: DispatchWorkItem] = [:]

    /// Writes without response queued until the peripheral can accept more.
    private struct QueuedWrite {
        let characteristic: CBCharacteristic
        var pieces: [Data]
        let reply: Reply
    }
    private var writeQueues: [String: [QueuedWrite]] = [:]

    // Device chooser state
    private var chooserRequest: Reply?
    private var chooserModel: DeviceChooserModel?
    private var chooserController: NSViewController?

    // Printers this Mac has used before (see KnownPrinters)
    private var names: [String: String] = [:]
    private var isLookingForKnownPrinters = false
    private var knownPrinterDeadline: DispatchWorkItem?
    /// A known printer just seen advertising; the next requestDevice returns it without a chooser.
    private var offered: (id: String, at: Date)?

    private static let connectTimeout: TimeInterval = 15
    private static let knownPrinterScanTime: TimeInterval = 10
    private static let offerLifetime: TimeInterval = 15

    // MARK: - Script messages

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "TypeError|Malformed Bluetooth request")
            return
        }

        switch op {
        case "requestDevice": requestDevice(body, reply: replyHandler)
        case "connect": connect(body, reply: replyHandler)
        case "disconnect": disconnect(body, reply: replyHandler)
        case "getPrimaryService": getPrimaryService(body, reply: replyHandler)
        case "getCharacteristic": getCharacteristic(body, reply: replyHandler)
        case "write": write(body, reply: replyHandler)
        case "read": read(body, reply: replyHandler)
        case "setNotify": setNotify(body, reply: replyHandler)
        default: replyHandler(nil, "NotSupportedError|Unknown Bluetooth operation \(op)")
        }
    }

    /// Look briefly for printers that have been connected before. If one is
    /// advertising, the page is told (`available` event) and connects to it
    /// as though the user had picked it in the chooser.
    ///
    /// Does nothing until a printer has been used once, so the system
    /// Bluetooth permission prompt still only appears on the first Connect.
    func lookForKnownPrinters() {
        guard !KnownPrinters.all.isEmpty, chooserRequest == nil, !isLookingForKnownPrinters else { return }
        isLookingForKnownPrinters = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        let deadline = DispatchWorkItem { [weak self] in self?.stopLookingForKnownPrinters() }
        knownPrinterDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.knownPrinterScanTime, execute: deadline)
        startKnownPrinterScanIfPossible()
    }

    private func startKnownPrinterScanIfPossible() {
        guard isLookingForKnownPrinters, let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    private func stopLookingForKnownPrinters() {
        guard isLookingForKnownPrinters else { return }
        isLookingForKnownPrinters = false
        knownPrinterDeadline?.cancel()
        knownPrinterDeadline = nil
        if chooserRequest == nil {
            central?.stopScan()
        }
    }

    /// Drop every connection and answer anything still outstanding. Called when the window closes.
    func shutdown() {
        stopLookingForKnownPrinters()
        dismissChooser()
        chooserRequest?(nil, "AbortError|Window closed")
        chooserRequest = nil
        central?.stopScan()
        for peripheral in peripherals.values {
            failPending(for: peripheral, message: "NetworkError|Window closed")
            central?.cancelPeripheralConnection(peripheral)
        }
        peripherals.removeAll()
    }

    // MARK: - Operations

    private func requestDevice(_ body: [String: Any], reply: @escaping Reply) {
        if chooserRequest != nil {
            reply(nil, "InvalidStateError|A device chooser is already open")
            return
        }

        // Answering the page's connect that followed an `available` event.
        if let offer = offered {
            offered = nil
            if Date().timeIntervalSince(offer.at) < Self.offerLifetime, peripherals[offer.id] != nil {
                reply(["id": offer.id, "name": names[offer.id] ?? "Printer"], nil)
                return
            }
        }
        stopLookingForKnownPrinters()
        chooserRequest = reply

        let model = DeviceChooserModel(
            namePrefixes: body["namePrefixes"] as? [String] ?? [],
            names: body["names"] as? [String] ?? [],
            showAll: body["acceptAllDevices"] as? Bool ?? false
        )
        chooserModel = model

        if central == nil {
            // Creating the manager is what triggers the system Bluetooth permission prompt.
            central = CBCentralManager(delegate: self, queue: .main)
        }
        presentChooser(model)
        updateForCentralState()
    }

    private func connect(_ body: [String: Any], reply: @escaping Reply) {
        guard let (id, peripheral) = peripheral(in: body, reply: reply) else { return }
        if peripheral.state == .connected {
            reply(NSNull(), nil)
            return
        }
        guard let central, central.state == .poweredOn else {
            reply(nil, "NetworkError|Bluetooth is not available")
            return
        }

        setPending("connect:\(id)", reply)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.connectTimeouts[id] = nil
            self.central?.cancelPeripheralConnection(peripheral)
            self.resolve("connect:\(id)", error: "NetworkError|Connection attempt timed out")
        }
        connectTimeouts[id] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeout)
        central.connect(peripheral, options: nil)
    }

    private func disconnect(_ body: [String: Any], reply: @escaping Reply) {
        if let id = body["device"] as? String, let peripheral = peripherals[id] {
            central?.cancelPeripheralConnection(peripheral)
        }
        reply(NSNull(), nil)
    }

    private func getPrimaryService(_ body: [String: Any], reply: @escaping Reply) {
        guard let (id, peripheral) = connectedPeripheral(in: body, reply: reply),
              let uuid = uuid(body["service"], reply: reply) else { return }

        if peripheral.services?.contains(where: { Self.canonical($0.uuid) == Self.canonical(uuid) }) == true {
            reply(NSNull(), nil)
            return
        }
        setPending("service:\(id):\(Self.canonical(uuid))", reply)
        peripheral.discoverServices([uuid])
    }

    private func getCharacteristic(_ body: [String: Any], reply: @escaping Reply) {
        guard let (id, peripheral) = connectedPeripheral(in: body, reply: reply),
              let serviceUUID = uuid(body["service"], reply: reply),
              let charUUID = uuid(body["characteristic"], reply: reply) else { return }
        guard let service = peripheral.services?.first(where: { Self.canonical($0.uuid) == Self.canonical(serviceUUID) }) else {
            reply(nil, "NotFoundError|No Services matching UUID \(serviceUUID.uuidString) found in Device.")
            return
        }

        if let characteristic = service.characteristics?.first(where: { Self.canonical($0.uuid) == Self.canonical(charUUID) }) {
            KnownPrinters.remember(id: id, name: names[id])
            reply(["properties": Self.describe(characteristic.properties)], nil)
            return
        }
        setPending("characteristic:\(id):\(Self.canonical(serviceUUID)):\(Self.canonical(charUUID))", reply)
        peripheral.discoverCharacteristics([charUUID], for: service)
    }

    private func write(_ body: [String: Any], reply: @escaping Reply) {
        guard let (id, peripheral, characteristic) = characteristic(in: body, reply: reply) else { return }
        guard let encoded = body["data"] as? String, let data = Data(base64Encoded: encoded) else {
            reply(nil, "TypeError|Write data was not valid")
            return
        }

        if body["withResponse"] as? Bool ?? true {
            setPending("write:\(id):\(Self.canonical(characteristic.uuid))", reply)
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            return
        }

        // CoreBluetooth silently drops whatever does not fit in one packet, so
        // split to the negotiated size and feed the pieces in as the peripheral
        // signals it has room.
        let limit = max(peripheral.maximumWriteValueLength(for: .withoutResponse), 1)
        var pieces: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + limit, data.count)
            pieces.append(data.subdata(in: offset..<end))
            offset = end
        }
        writeQueues[id, default: []].append(
            QueuedWrite(characteristic: characteristic, pieces: pieces, reply: reply)
        )
        pumpWrites(for: peripheral)
    }

    private func read(_ body: [String: Any], reply: @escaping Reply) {
        guard let (id, peripheral, characteristic) = characteristic(in: body, reply: reply) else { return }
        setPending("read:\(id):\(Self.canonical(characteristic.uuid))", reply)
        peripheral.readValue(for: characteristic)
    }

    private func setNotify(_ body: [String: Any], reply: @escaping Reply) {
        guard let (id, peripheral, characteristic) = characteristic(in: body, reply: reply) else { return }
        let enabled = body["enabled"] as? Bool ?? true
        if characteristic.isNotifying == enabled {
            reply(NSNull(), nil)
            return
        }
        setPending("notify:\(id):\(Self.canonical(characteristic.uuid))", reply)
        peripheral.setNotifyValue(enabled, for: characteristic)
    }

    private func pumpWrites(for peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        while var current = writeQueues[id]?.first {
            while !current.pieces.isEmpty {
                guard peripheral.canSendWriteWithoutResponse else {
                    // Resumed from peripheralIsReady(toSendWriteWithoutResponse:)
                    writeQueues[id]?[0] = current
                    return
                }
                peripheral.writeValue(current.pieces.removeFirst(), for: current.characteristic, type: .withoutResponse)
            }
            writeQueues[id]?.removeFirst()
            current.reply(NSNull(), nil)
        }
    }

    // MARK: - Lookup helpers

    private func peripheral(in body: [String: Any], reply: Reply) -> (String, CBPeripheral)? {
        guard let id = body["device"] as? String, let peripheral = peripherals[id] else {
            reply(nil, "NotFoundError|Bluetooth device is no longer known")
            return nil
        }
        return (id, peripheral)
    }

    private func connectedPeripheral(in body: [String: Any], reply: Reply) -> (String, CBPeripheral)? {
        guard let found = peripheral(in: body, reply: reply) else { return nil }
        guard found.1.state == .connected else {
            reply(nil, "NetworkError|GATT Server is disconnected. Cannot perform GATT operations.")
            return nil
        }
        return found
    }

    private func characteristic(
        in body: [String: Any], reply: Reply
    ) -> (String, CBPeripheral, CBCharacteristic)? {
        guard let (id, peripheral) = connectedPeripheral(in: body, reply: reply),
              let serviceUUID = uuid(body["service"], reply: reply),
              let charUUID = uuid(body["characteristic"], reply: reply) else { return nil }
        guard let characteristic = peripheral.services?
            .first(where: { Self.canonical($0.uuid) == Self.canonical(serviceUUID) })?
            .characteristics?.first(where: { Self.canonical($0.uuid) == Self.canonical(charUUID) }) else {
            reply(nil, "NotFoundError|Characteristic \(charUUID.uuidString) not found")
            return nil
        }
        return (id, peripheral, characteristic)
    }

    private func uuid(_ value: Any?, reply: Reply) -> CBUUID? {
        guard let text = value as? String, UUID(uuidString: text) != nil else {
            reply(nil, "TypeError|Invalid UUID")
            return nil
        }
        return CBUUID(string: text)
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> [String: Bool] {
        [
            "broadcast": properties.contains(.broadcast),
            "read": properties.contains(.read),
            "writeWithoutResponse": properties.contains(.writeWithoutResponse),
            "write": properties.contains(.write),
            "notify": properties.contains(.notify),
            "indicate": properties.contains(.indicate),
            "authenticatedSignedWrites": properties.contains(.authenticatedSignedWrites),
        ]
    }

    // MARK: - Pending replies

    private func setPending(_ key: String, _ reply: @escaping Reply) {
        // The page awaits each operation, so a duplicate key means the earlier
        // one was abandoned; answer it rather than leak its reply handler.
        pending.removeValue(forKey: key)?(nil, "AbortError|Superseded by a newer request")
        pending[key] = reply
    }

    private func resolve(_ key: String, value: Any = NSNull(), error: String? = nil) {
        guard let reply = pending.removeValue(forKey: key) else { return }
        if let error {
            reply(nil, error)
        } else {
            reply(value, nil)
        }
    }

    private func failPending(for peripheral: CBPeripheral, message: String) {
        let id = peripheral.identifier.uuidString
        connectTimeouts.removeValue(forKey: id)?.cancel()
        for key in pending.keys where key.split(separator: ":").dropFirst().first.map(String.init) == id {
            resolve(key, error: message)
        }
        for queued in writeQueues.removeValue(forKey: id) ?? [] {
            queued.reply(nil, message)
        }
    }

    private func emit(_ message: [String: Any]) {
        guard let webView,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__phomymoBLE && window.__phomymoBLE.event(\(json))", completionHandler: nil)
    }

    // MARK: - Device chooser

    private func presentChooser(_ model: DeviceChooserModel) {
        guard let presenter = webView?.window?.contentViewController else {
            finishChooser(with: nil)
            return
        }
        let view = DeviceChooserView(
            model: model,
            onCancel: { [weak self] in self?.finishChooser(with: nil) },
            onConnect: { [weak self] device in self?.finishChooser(with: device) }
        )
        let controller = NSHostingController(rootView: view)
        chooserController = controller
        presenter.presentAsSheet(controller)
    }

    private func dismissChooser() {
        if let controller = chooserController {
            controller.presentingViewController?.dismiss(controller)
        }
        chooserController = nil
        chooserModel = nil
    }

    private func finishChooser(with device: DeviceChooserModel.Device?) {
        central?.stopScan()
        dismissChooser()
        guard let reply = chooserRequest else { return }
        chooserRequest = nil
        if let device {
            reply(["id": device.id, "name": device.name], nil)
        } else {
            reply(nil, "NotFoundError|User cancelled the requestDevice() chooser.")
        }
    }

    private func updateForCentralState() {
        guard let central, let model = chooserModel else { return }
        switch central.state {
        case .poweredOn:
            model.problem = nil
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff:
            model.problem = "Bluetooth is turned off. Turn it on in Control Centre or System Settings."
        case .unauthorized:
            model.problem = "Phomymo is not allowed to use Bluetooth. "
                + "Allow it in System Settings › Privacy & Security › Bluetooth."
        case .unsupported:
            model.problem = "This Mac does not support Bluetooth Low Energy."
        default:
            model.problem = nil  // .unknown / .resetting: a state update follows
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateForCentralState()
        startKnownPrinterScanIfPossible()
        if central.state != .poweredOn {
            for peripheral in peripherals.values {
                failPending(for: peripheral, message: "NetworkError|Bluetooth became unavailable")
                emit(["type": "disconnected", "device": peripheral.identifier.uuidString])
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier.uuidString
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let known = KnownPrinters.all.first { $0.id == id }
        guard let name = advertised ?? peripheral.name ?? known?.name, !name.isEmpty else { return }
        if peripherals[id] == nil {
            peripheral.delegate = self
            peripherals[id] = peripheral  // CoreBluetooth does not retain discovered peripherals
        }
        names[id] = name
        chooserModel?.saw(id: id, name: name, rssi: RSSI.intValue)

        if isLookingForKnownPrinters, known != nil {
            stopLookingForKnownPrinters()
            offered = (id, Date())
            emit(["type": "available", "device": id, "name": name])
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        connectTimeouts.removeValue(forKey: id)?.cancel()
        resolve("connect:\(id)")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier.uuidString
        connectTimeouts.removeValue(forKey: id)?.cancel()
        resolve("connect:\(id)", error: "NetworkError|\(error?.localizedDescription ?? "Connection failed")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        failPending(for: peripheral, message: "NetworkError|GATT Server is disconnected.")
        emit(["type": "disconnected", "device": peripheral.identifier.uuidString])
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier.uuidString
        let prefix = "service:\(id):"
        for key in pending.keys where key.hasPrefix(prefix) {
            let wanted = CBUUID(string: String(key.dropFirst(prefix.count)))
            if let error {
                resolve(key, error: "NetworkError|\(error.localizedDescription)")
            } else if peripheral.services?.contains(where: { Self.canonical($0.uuid) == Self.canonical(wanted) }) == true {
                resolve(key)
            } else {
                resolve(key, error: "NotFoundError|No Services matching UUID \(wanted.uuidString) found in Device.")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier.uuidString
        let prefix = "characteristic:\(id):\(Self.canonical(service.uuid)):"
        for key in pending.keys where key.hasPrefix(prefix) {
            let wanted = CBUUID(string: String(key.dropFirst(prefix.count)))
            if let error {
                resolve(key, error: "NetworkError|\(error.localizedDescription)")
            } else if let found = service.characteristics?.first(where: { Self.canonical($0.uuid) == Self.canonical(wanted) }) {
                // Having the printer service and characteristic is what marks a device as a printer.
                KnownPrinters.remember(id: id, name: names[id])
                resolve(key, value: ["properties": Self.describe(found.properties)])
            } else {
                resolve(key, error: "NotFoundError|No Characteristics matching UUID \(wanted.uuidString) found in Service.")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = "write:\(peripheral.identifier.uuidString):\(Self.canonical(characteristic.uuid))"
        resolve(key, error: error.map { "NetworkError|\($0.localizedDescription)" })
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWrites(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = "notify:\(peripheral.identifier.uuidString):\(Self.canonical(characteristic.uuid))"
        resolve(key, error: error.map { "NotSupportedError|\($0.localizedDescription)" })
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier.uuidString
        let readKey = "read:\(id):\(Self.canonical(characteristic.uuid))"
        let encoded = (characteristic.value ?? Data()).base64EncodedString()

        if pending[readKey] != nil {
            if let error {
                resolve(readKey, error: "NetworkError|\(error.localizedDescription)")
            } else {
                resolve(readKey, value: ["data": encoded])
            }
            return
        }
        guard error == nil, let service = characteristic.service else { return }
        emit([
            "type": "value",
            "device": id,
            "service": Self.canonical(service.uuid),
            "characteristic": Self.canonical(characteristic.uuid),
            "data": encoded,
        ])
    }

    /// 128-bit lowercase form, matching canonicalUUID() in the polyfill.
    fileprivate static func canonical(_ uuid: CBUUID) -> String {
        let text = uuid.uuidString.lowercased()
        switch text.count {
        case 4: return "0000\(text)-0000-1000-8000-00805f9b34fb"
        case 8: return "\(text)-0000-1000-8000-00805f9b34fb"
        default: return text
        }
    }
}

// MARK: - Chooser UI

final class DeviceChooserModel: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: String
        var name: String
        var rssi: Int
    }

    @Published private(set) var seen: [Device] = []
    @Published var showAll: Bool
    @Published var selection: String?
    @Published var problem: String?

    private let namePrefixes: [String]
    private let names: [String]

    init(namePrefixes: [String], names: [String], showAll: Bool) {
        self.namePrefixes = namePrefixes
        self.names = names
        self.showAll = showAll || (namePrefixes.isEmpty && names.isEmpty)
    }

    var hasFilter: Bool { !(namePrefixes.isEmpty && names.isEmpty) }

    var visible: [Device] {
        let matching = showAll ? seen : seen.filter { device in
            names.contains(device.name) || namePrefixes.contains { device.name.hasPrefix($0) }
        }
        return matching.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func saw(id: String, name: String, rssi: Int) {
        if let index = seen.firstIndex(where: { $0.id == id }) {
            // 127 is CoreBluetooth's "RSSI unavailable"; keep the last real reading.
            let updated = Device(id: id, name: name, rssi: rssi == 127 ? seen[index].rssi : rssi)
            if seen[index] != updated { seen[index] = updated }
        } else {
            seen.append(Device(id: id, name: name, rssi: rssi))
        }
    }
}

struct DeviceChooserView: View {
    @ObservedObject var model: DeviceChooserModel
    let onCancel: () -> Void
    let onConnect: (DeviceChooserModel.Device) -> Void

    private var selected: DeviceChooserModel.Device? {
        model.visible.first { $0.id == model.selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to a Printer")
                .font(.headline)

            if let problem = model.problem {
                Text(problem)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                    .multilineTextAlignment(.center)
            } else {
                List(model.visible, selection: $model.selection) { device in
                    HStack {
                        Text(device.name)
                        Spacer()
                        Image(systemName: "cellularbars", variableValue: Self.strength(device.rssi))
                            .foregroundStyle(.secondary)
                            .help("\(device.rssi) dBm")
                    }
                    .tag(device.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onConnect(device) }
                    .onTapGesture { model.selection = device.id }
                }
                .frame(minHeight: 220)
                .overlay {
                    if model.visible.isEmpty {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for printers…").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                if model.hasFilter {
                    Toggle("Show all devices", isOn: $model.showAll)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let selected { onConnect(selected) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    /// Map RSSI (roughly -100…-40 dBm) onto the 0…1 range of the bars symbol.
    private static func strength(_ rssi: Int) -> Double {
        min(max((Double(rssi) + 100) / 60, 0), 1)
    }
}

// MARK: - Known printers

/// Printers that have been connected successfully, most recent first, kept in
/// the app's preferences so every window and every launch shares them.
///
/// The identifier is the one CoreBluetooth assigns to the peripheral on this
/// Mac; it is stable across launches but means nothing on another machine.
enum KnownPrinters {
    struct Printer: Codable, Equatable {
        let id: String
        var name: String
    }

    private static let defaultsKey = "KnownPrinters"
    private static let limit = 10

    static var all: [Printer] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let printers = try? JSONDecoder().decode([Printer].self, from: data) else { return [] }
        return printers
    }

    static func remember(id: String, name: String?) {
        var printers = all
        let previous = printers.first { $0.id == id }
        let printer = Printer(id: id, name: name ?? previous?.name ?? "Printer")
        if printers.first == printer { return }
        printers.removeAll { $0.id == id }
        printers.insert(printer, at: 0)
        if let data = try? JSONEncoder().encode(Array(printers.prefix(limit))) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    static func forgetAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
