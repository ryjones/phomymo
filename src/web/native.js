// SPDX-License-Identifier: Apache-2.0

/**
 * Document bridge for the native macOS app (see /macos).
 *
 * When the page is hosted in the app's WKWebView, the app owns the file on
 * disk: it asks this bridge for the current design when saving, pushes a
 * design in when a file is opened, and is told when the design differs from
 * the last saved state so it can show the unsaved-changes indicator.
 *
 * In a normal browser none of this is present and initNativeBridge() is a no-op.
 */

const DIRTY_CHECK_DEBOUNCE_MS = 150;
const DIRTY_CHECK_INTERVAL_MS = 1000;

/**
 * @param {object} hooks
 * @param {function(): object} hooks.serializeDesign - Returns the saveable design data
 * @param {function(object, string|null): void} hooks.applyDesign - Replaces the current design
 * @param {function(): void} hooks.connectKnownPrinter - Starts a Bluetooth connect if none is active
 * @returns {boolean} true if running inside the native app
 */
export function initNativeBridge({ serializeDesign, applyDesign, connectKnownPrinter }) {
  const handler = window.webkit?.messageHandlers?.phomymoDocument;
  if (!handler) return false;

  const snapshot = () => JSON.stringify({ version: 3, ...serializeDesign() }, null, 2);

  let baseline = snapshot();   // What is on disk (or the blank starting state)
  let dirty = false;
  let debounceTimer = null;

  const checkDirty = () => {
    debounceTimer = null;
    const nowDirty = snapshot() !== baseline;
    if (nowDirty !== dirty) {
      dirty = nowDirty;
      handler.postMessage({ type: 'dirty', dirty });
    }
  };

  const scheduleCheck = () => {
    if (debounceTimer === null) {
      debounceTimer = setTimeout(checkDirty, DIRTY_CHECK_DEBOUNCE_MS);
    }
  };

  window.phomymoNative = {
    /** Current design as a JSON string, for the app to write to disk. */
    serialize() {
      return snapshot();
    },

    /** The app wrote `json` to disk; it is the new clean state. */
    markSaved(json) {
      baseline = json;
      checkDirty();
    },

    /** Replace the design with one read from disk. */
    load(json, name) {
      const data = JSON.parse(json);
      if (!data.elements || !Array.isArray(data.elements)) {
        throw new Error('Invalid design file: missing elements');
      }
      applyDesign(data, name || null);
      baseline = snapshot();
      dirty = false;
      handler.postMessage({ type: 'dirty', dirty: false });
    },
  };

  // Edits arrive through pointer and keyboard input; check shortly after any
  // of them, with a slow timer as a backstop for anything asynchronous
  // (image decoding, CSV import).
  for (const type of ['pointerup', 'keyup', 'input', 'change', 'paste', 'drop']) {
    window.addEventListener(type, scheduleCheck, true);
  }
  setInterval(() => {
    if (!document.hidden) checkDirty();
  }, DIRTY_CHECK_INTERVAL_MS);

  // The app looks for previously used printers once the page is ready. When
  // one is advertising it raises this event and answers the connect that
  // follows with that printer, so no chooser appears.
  window.addEventListener('phomymo-printer-available', () => connectKnownPrinter());

  handler.postMessage({ type: 'ready' });
  return true;
}
