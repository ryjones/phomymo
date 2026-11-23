// SPDX-License-Identifier: Apache-2.0

/**
 * Web Bluetooth polyfill for the Phomymo macOS app.
 *
 * WebKit has no Web Bluetooth, so the app injects this before the page's own
 * scripts run. It implements the subset of the API that src/web/ble.js uses
 * and forwards every operation to CoreBluetooth through the `phomymoBLE`
 * script message handler (see BluetoothBridge.swift).
 *
 * Native replies reject with a string of the form "ErrorName|message", which
 * is turned back into a DOMException here.
 */
(() => {
  'use strict';

  const native = window.webkit?.messageHandlers?.phomymoBLE;
  if (!native || navigator.bluetooth) return;

  const BASE_UUID_SUFFIX = '-0000-1000-8000-00805f9b34fb';

  /** Canonical 128-bit lowercase UUID from a 16/32-bit alias or a string. */
  function canonicalUUID(uuid) {
    if (typeof uuid === 'number') {
      return uuid.toString(16).padStart(8, '0') + BASE_UUID_SUFFIX;
    }
    const s = String(uuid).toLowerCase();
    if (/^[0-9a-f]{4}$/.test(s)) return '0000' + s + BASE_UUID_SUFFIX;
    if (/^[0-9a-f]{8}$/.test(s)) return s + BASE_UUID_SUFFIX;
    return s;
  }

  async function call(op, args = {}) {
    try {
      return await native.postMessage({ op, ...args });
    } catch (e) {
      const text = String(e?.message ?? e);
      const split = text.indexOf('|');
      if (split > 0) {
        throw new DOMException(text.slice(split + 1), text.slice(0, split));
      }
      throw new DOMException(text, 'NetworkError');
    }
  }

  function toBase64(data) {
    const bytes = data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    let binary = '';
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function fromBase64(text) {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new DataView(bytes.buffer);
  }

  const devices = new Map();          // device id -> BluetoothDevice
  const characteristics = new Map();  // "deviceId/serviceUUID/charUUID" -> characteristic

  class BluetoothRemoteGATTCharacteristic extends EventTarget {
    constructor(service, uuid, properties) {
      super();
      this.service = service;
      this.uuid = uuid;
      this.properties = properties;
      this.value = null;
    }

    get _address() {
      return {
        device: this.service.device.id,
        service: this.service.uuid,
        characteristic: this.uuid,
      };
    }

    writeValue(data) {
      return this.writeValueWithResponse(data);
    }

    async writeValueWithResponse(data) {
      await call('write', { ...this._address, data: toBase64(data), withResponse: true });
    }

    async writeValueWithoutResponse(data) {
      await call('write', { ...this._address, data: toBase64(data), withResponse: false });
    }

    async readValue() {
      const reply = await call('read', this._address);
      this.value = fromBase64(reply.data);
      return this.value;
    }

    async startNotifications() {
      await call('setNotify', { ...this._address, enabled: true });
      return this;
    }

    async stopNotifications() {
      await call('setNotify', { ...this._address, enabled: false });
      return this;
    }
  }

  class BluetoothRemoteGATTService {
    constructor(device, uuid) {
      this.device = device;
      this.uuid = uuid;
      this.isPrimary = true;
    }

    async getCharacteristic(uuid) {
      const charUUID = canonicalUUID(uuid);
      const reply = await call('getCharacteristic', {
        device: this.device.id,
        service: this.uuid,
        characteristic: charUUID,
      });
      const key = `${this.device.id}/${this.uuid}/${charUUID}`;
      let characteristic = characteristics.get(key);
      if (!characteristic) {
        characteristic = new BluetoothRemoteGATTCharacteristic(this, charUUID, reply.properties);
        characteristics.set(key, characteristic);
      } else {
        characteristic.properties = reply.properties;
      }
      return characteristic;
    }
  }

  class BluetoothRemoteGATTServer {
    constructor(device) {
      this.device = device;
      this.connected = false;
    }

    async connect() {
      await call('connect', { device: this.device.id });
      this.connected = true;
      return this;
    }

    disconnect() {
      if (!this.connected) return;
      this.connected = false;
      call('disconnect', { device: this.device.id }).catch(() => {});
      this.device.dispatchEvent(new Event('gattserverdisconnected'));
    }

    async getPrimaryService(uuid) {
      const serviceUUID = canonicalUUID(uuid);
      await call('getPrimaryService', { device: this.device.id, service: serviceUUID });
      return new BluetoothRemoteGATTService(this.device, serviceUUID);
    }
  }

  class BluetoothDevice extends EventTarget {
    constructor(id, name) {
      super();
      this.id = id;
      this.name = name;
      this.gatt = new BluetoothRemoteGATTServer(this);
    }

    // The native chooser only lists devices it has just seen advertising, so
    // the device is ready as soon as it has been picked.
    watchAdvertisements() {
      setTimeout(() => this.dispatchEvent(new Event('advertisementreceived')), 0);
      return Promise.resolve();
    }
  }

  const bluetooth = {
    async getAvailability() {
      return true;
    },

    async getDevices() {
      return Array.from(devices.values());
    },

    async requestDevice(options = {}) {
      const namePrefixes = [];
      const names = [];
      for (const filter of options.filters || []) {
        if (filter.namePrefix) namePrefixes.push(filter.namePrefix);
        if (filter.name) names.push(filter.name);
      }
      const reply = await call('requestDevice', {
        acceptAllDevices: !!options.acceptAllDevices,
        namePrefixes,
        names,
      });
      let device = devices.get(reply.id);
      if (!device) {
        device = new BluetoothDevice(reply.id, reply.name);
        devices.set(reply.id, device);
      } else {
        device.name = reply.name;
      }
      return device;
    },
  };

  Object.defineProperty(navigator, 'bluetooth', { value: bluetooth, configurable: true });

  /** Events pushed from the native side. */
  window.__phomymoBLE = {
    event(message) {
      if (message.type === 'disconnected') {
        const device = devices.get(message.device);
        if (!device) return;
        const wasConnected = device.gatt.connected;
        device.gatt.connected = false;
        for (const key of Array.from(characteristics.keys())) {
          if (key.startsWith(message.device + '/')) characteristics.delete(key);
        }
        if (wasConnected) device.dispatchEvent(new Event('gattserverdisconnected'));
      } else if (message.type === 'available') {
        // A printer used before is advertising; src/web/native.js connects to it.
        window.dispatchEvent(new CustomEvent('phomymo-printer-available', {
          detail: { id: message.device, name: message.name },
        }));
      } else if (message.type === 'value') {
        const key = `${message.device}/${message.service}/${message.characteristic}`;
        const characteristic = characteristics.get(key);
        if (!characteristic) return;
        characteristic.value = fromBase64(message.data);
        characteristic.dispatchEvent(new Event('characteristicvaluechanged'));
      }
    },
  };
})();
