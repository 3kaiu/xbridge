import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  XBridge,
  XBridgeCore,
  StandardAdapter,
  resetSniffCache,
  XBridgeSendError,
  XBRIDGE_PROTOCOL_VERSION,
} from "../dist/index.js";

describe("XBridge Production-Grade Resilience & Backward Compatibility", () => {
  let originalGlobalXBridge;
  let originalGlobalInapp;
  let originalGlobalReady;

  const safeDeleteGlobals = () => {
    try { delete globalThis.XBridge; } catch {}
    try { delete globalThis.flutter_inappwebview; } catch {}
    try { delete globalThis.__xbridge_ready__; } catch {}
    try { delete globalThis.__XBridge__; } catch {}
    try { delete globalThis.__XBridgeInbound__; } catch {}
    try { delete globalThis.__xbridge_initialized__; } catch {}
  };

  beforeEach(() => {
    resetSniffCache();
    originalGlobalXBridge = globalThis.XBridge;
    originalGlobalInapp = globalThis.flutter_inappwebview;
    originalGlobalReady = globalThis.__xbridge_ready__;
    safeDeleteGlobals();
  });

  afterEach(() => {
    safeDeleteGlobals();
    if (originalGlobalXBridge !== undefined) {
      globalThis.XBridge = originalGlobalXBridge;
    }
    if (originalGlobalInapp !== undefined) {
      globalThis.flutter_inappwebview = originalGlobalInapp;
    }
    if (originalGlobalReady !== undefined) {
      globalThis.__xbridge_ready__ = originalGlobalReady;
    }
    resetSniffCache();
  });

  test("1. Standard happy path: send and receive JSON-RPC response", async () => {
    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        setTimeout(() => {
          globalThis.__XBridge__.resolve(req.id, { token: "secret_123" });
        }, 5);
      },
    };

    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), true);

    const res = await bridge.call("getToken");
    assert.deepEqual(res, { token: "secret_123" });
    bridge.dispose();
  });

  test("2. Late injection: new XBridge() instantiated BEFORE container injects postMessage", async () => {
    // At T=0, window.XBridge is NOT present
    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), false);

    // Simulate native container injecting postMessage after 30ms
    setTimeout(() => {
      globalThis.XBridge = {
        postMessage: (raw) => {
          const req = JSON.parse(raw);
          globalThis.__XBridge__.resolve(req.id, { safeArea: { top: 44, bottom: 34 } });
        },
      };
      globalThis.__xbridge_ready__ = true;
      if (typeof globalThis.dispatchEvent === "function") {
        globalThis.dispatchEvent(new Event("XBridgeReady"));
      }
    }, 30);

    // ready() should resolve once injected
    await bridge.ready(1000);
    assert.equal(bridge.isConnected(), true);

    const res = await bridge.call("getSafeArea");
    assert.deepEqual(res, { safeArea: { top: 44, bottom: 34 } });
    bridge.dispose();
  });

  test("3. Early call auto-buffering: bridge.call() issued immediately on cold start waits and succeeds", async () => {
    // Cold start: H5 calls bridge.call before native injection
    const bridge = new XBridge();

    // Native container finishes injection at 40ms
    setTimeout(() => {
      globalThis.XBridge = {
        postMessage: (raw) => {
          const req = JSON.parse(raw);
          globalThis.__XBridge__.resolve(req.id, { user: "alice" });
        },
      };
      globalThis.__xbridge_ready__ = true;
      if (typeof globalThis.dispatchEvent === "function") {
        globalThis.dispatchEvent(new Event("XBridgeReady"));
      }
    }, 40);

    // Initial call will automatically buffer and await readiness (default readyTimeout: 1500ms)
    const res = await bridge.call("getUserInfo");
    assert.deepEqual(res, { user: "alice" });
    bridge.dispose();
  });

  test("4. Circuit breaker: missing postMessage does NOT trip circuit breaker into 1s OPEN lockout", async () => {
    const adapter = new StandardAdapter();
    assert.equal(adapter.isAvailable(), false);
    assert.equal(adapter.state, "CLOSED");

    // send() when not ready throws XBridgeSendError
    assert.throws(
      () => adapter.send(JSON.stringify({ jsonrpc: "2.0", id: "1", method: "test" })),
      (err) => err instanceof XBridgeSendError,
    );

    // Circuit breaker must REMAIN CLOSED (not tripped into OPEN)
    assert.equal(adapter.state, "CLOSED");
    assert.equal(adapter.isBroken, false);

    // As soon as window.XBridge is injected, next send immediately works
    globalThis.XBridge = {
      postMessage: () => {},
    };
    assert.equal(adapter.isAvailable(), true);
    assert.doesNotThrow(() =>
      adapter.send(JSON.stringify({ jsonrpc: "2.0", id: "2", method: "test" })),
    );
    adapter.destroy();
  });

  test("5. Transparent flutter_inappwebview support without standard postMessage", async () => {
    let receivedPayload = null;
    globalThis.flutter_inappwebview = {
      callHandler: (handlerName, message) => {
        assert.equal(handlerName, "XBridge");
        receivedPayload = JSON.parse(message);
        setTimeout(() => {
          globalThis.__XBridge__.resolve(receivedPayload.id, { from: "inappwebview" });
        }, 5);
      },
    };

    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), true);

    const res = await bridge.call("testInApp");
    assert.deepEqual(res, { from: "inappwebview" });
    assert.equal(receivedPayload.method, "testInApp");
    bridge.dispose();
  });

  test("6. Non-configurable properties in destroy(): does not throw strict-mode TypeError", () => {
    globalThis.__XBridge__ = {};
    Object.defineProperty(globalThis.__XBridge__, "resolve", {
      value: () => {},
      writable: false,
      configurable: false,
    });
    Object.defineProperty(globalThis.__XBridge__, "reject", {
      value: () => {},
      writable: false,
      configurable: false,
    });

    const adapter = new StandardAdapter();
    adapter.onMessage(() => {});
    assert.doesNotThrow(() => {
      adapter.destroy();
    });
  });

  test("7. JSON-RPC numeric ID compatibility", async () => {
    let sentBack;
    globalThis.XBridge = {
      postMessage: (raw) => {
        sentBack = JSON.parse(raw);
      },
    };

    const bridge = new XBridge();
    bridge.registerHandler("confirmAction", (params) => {
      return { confirmed: true, target: params.item };
    });

    // Native host sends inbound request with numeric ID 99999
    globalThis.__XBridgeInbound__(
      JSON.stringify({ jsonrpc: "2.0", id: 99999, method: "confirmAction", params: { item: "order_1" } }),
    );

    await new Promise((r) => setTimeout(r, 15));
    assert.deepEqual(sentBack, {
      jsonrpc: "2.0",
      id: 99999,
      result: { confirmed: true, target: "order_1" },
    });

    bridge.dispose();
  });

  test("8. Fallback adapter failover when primary adapter send() fails", async () => {
    const primaryAdapter = {
      name: "FailingPrimary",
      isAvailable: () => true,
      send: () => {
        throw new XBridgeSendError("Primary send failed");
      },
      onMessage: () => {},
    };

    let fallbackCalled = false;
    const fallbackAdapter = {
      name: "WorkingFallback",
      isAvailable: () => true,
      send: (raw) => {
        fallbackCalled = true;
        const req = JSON.parse(raw);
        setTimeout(() => {
          fallbackHandler(
            JSON.stringify({ jsonrpc: XBRIDGE_PROTOCOL_VERSION, id: req.id, result: "ok_from_fallback" }),
          );
        }, 5);
      },
      onMessage: (h) => {
        fallbackHandler = h;
      },
    };
    let fallbackHandler;

    const bridge = new XBridge({
      adapter: primaryAdapter,
      fallbackAdapter,
    });

    const res = await bridge.call("testFailover");
    assert.equal(fallbackCalled, true);
    assert.equal(res, "ok_from_fallback");
    bridge.dispose();
  });

  test("9. Fire-and-forget (noCallback: true) resolves immediately", async () => {
    let sent = false;
    globalThis.XBridge = {
      postMessage: () => {
        sent = true;
      },
    };

    const bridge = new XBridge();
    const res = await bridge.call("logMetrics", { count: 1 }, { noCallback: true });
    assert.equal(res, undefined);
    assert.equal(sent, true);
    bridge.dispose();
  });

  test("10. options.fallback returned on total failure outside app", async () => {
    // Pure browser environment where bridge never injects
    const bridge = new XBridge();
    const res = await bridge.call(
      "getSafeArea",
      {},
      { readyTimeout: 10, fallback: { top: 0, bottom: 0 } },
    );
    assert.deepEqual(res, { top: 0, bottom: 0 });
    bridge.dispose();
  });
});
