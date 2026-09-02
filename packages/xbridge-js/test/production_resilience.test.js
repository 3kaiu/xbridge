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
  let originalGlobalXBridgeSync;
  let originalGlobalDsbridge;

  const safeDeleteGlobals = () => {
    try { delete globalThis.XBridge; } catch {}
    try { delete globalThis.flutter_inappwebview; } catch {}
    try { delete globalThis.__xbridge_ready__; } catch {}
    try { delete globalThis.__XBridge__; } catch {}
    try { delete globalThis.__XBridgeInbound__; } catch {}
    try { delete globalThis.__xbridge_initialized__; } catch {}
    try { delete globalThis.XBridgeSync; } catch {}
    try { delete globalThis.dsbridge; } catch {}
  };

  beforeEach(() => {
    resetSniffCache();
    originalGlobalXBridge = globalThis.XBridge;
    originalGlobalInapp = globalThis.flutter_inappwebview;
    originalGlobalReady = globalThis.__xbridge_ready__;
    originalGlobalXBridgeSync = globalThis.XBridgeSync;
    originalGlobalDsbridge = globalThis.dsbridge;
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
    if (originalGlobalXBridgeSync !== undefined) {
      globalThis.XBridgeSync = originalGlobalXBridgeSync;
    }
    if (originalGlobalDsbridge !== undefined) {
      globalThis.dsbridge = originalGlobalDsbridge;
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

  test("7b. Object-literal inbound: host injects {..} (not JSON string) via __XBridgeInbound__, must route correctly", async () => {
    // Dart 宿主注入的是对象字面量（非 JSON 字符串）。内核必须规整对象
    // 后再解析，否则对象被 ToString 成 "[object Object]" 而静默丢弃。
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

    // 以对象字面量（而非字符串）调用 __XBridgeInbound__
    globalThis.__XBridgeInbound__({
      jsonrpc: "2.0",
      id: "obj-inbound-1",
      method: "confirmAction",
      params: { item: "order_2" },
    });

    await new Promise((r) => setTimeout(r, 15));
    assert.deepEqual(sentBack, {
      jsonrpc: "2.0",
      id: "obj-inbound-1",
      result: { confirmed: true, target: "order_2" },
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

  test("11. Void method: host resolve(id) WITHOUT result must settle instead of hanging to timeout", async () => {
    // F1 regression: `resolve(id)` with no `result` used to serialize a payload
    // missing the `result` key, so `isResponse` rejected the message and the
    // pending call hung until the 30s (here overridden) timeout.
    let resolveRaw;
    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        resolveRaw = raw;
        // Host resolves a void method without returning any value.
        setTimeout(() => globalThis.__XBridge__.resolve(req.id), 2);
      },
    };
    const bridge = new XBridge();
    const t0 = Date.now();
    const res = await bridge.call("voidMethod", {}, { timeout: 1000 });
    const elapsed = Date.now() - t0;
    // Must settle promptly (not after the 1000ms timeout).
    assert.ok(elapsed < 900, `void call took ${elapsed}ms (should resolve quickly)`);
    assert.equal(res, null);
    assert.ok((JSON.parse(resolveRaw)).method === "voidMethod");
    bridge.dispose();
  });

  test("12. dispose() rejecting a pending call must NOT fire unhandledrejection when caller awaits later", async () => {
    // F2 regression: the no-op catch must attach to the promise the caller
    // actually holds; otherwise an async (delayed) await fires a global
    // unhandledrejection.
    const fired = [];
    const onUnhandled = (reason) => { fired.push(reason); };
    process.on("unhandledRejection", onUnhandled);
    try {
      globalThis.XBridge = {
        postMessage: () => { /* host never responds, call stays pending */ },
      };
      const bridge = new XBridge();
      const p = bridge.call("neverResolves", {}, { timeout: 2000 });
      bridge.dispose(); // reject the pending call
      // Caller awaits asynchronously (after a macrotask), reproducing the gap
      // that previously triggered a global unhandledrejection.
      await new Promise((r) => setTimeout(r, 20));
      await p.catch(() => {});
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
    assert.equal(fired.length, 0, "dispose() rejection leaked an unhandledrejection");
  });

  test("13. callSync routes to Android XBridgeSync and unwraps the result envelope (M1)", () => {
    // Android `@JavascriptInterface` exposes a genuinely synchronous
    // `XBridgeSync.callSync(method, paramsJson)` returning a JSON envelope string.
    const calls = [];
    globalThis.XBridgeSync = {
      callSync: (method, paramsJson) => {
        calls.push({ method, paramsJson });
        return JSON.stringify({ result: { token: "sync_token_1" } });
      },
    };
    const bridge = new XBridge();
    const res = bridge.callSync("getToken");
    assert.deepEqual(res, { token: "sync_token_1" });
    // Params were encoded to a JSON string for the @JavascriptInterface.
    assert.equal(calls[0].method, "getToken");
    assert.equal(calls[0].paramsJson, "");
    bridge.dispose();
  });

  test("14. callSync encodes params and throws on an Android XBridgeSync error envelope (M1)", () => {
    const calls = [];
    globalThis.XBridgeSync = {
      callSync: (method, paramsJson) => {
        calls.push(paramsJson);
        return JSON.stringify({
          error: { code: "NO_NATIVE_BRIDGE", message: "XBridgeNativeBridge not set" },
        });
      },
    };
    const bridge = new XBridge();

    // Error envelope → core.callSync throws with code attached.
    assert.throws(() => bridge.callSync("doThing", { x: 1 }), (e) => {
      assert.equal(e.code, "NO_NATIVE_BRIDGE");
      assert.ok(e.message.includes("XBridgeNativeBridge not set"));
      return true;
    });

    // Params object was JSON-encoded → string "{"x":1}".
    assert.equal(JSON.parse(calls[0]).x, 1);
    bridge.dispose();
  });

  test("15. iOS XBridgeSync (async Promise) degrades gracefully with a warning (M1)", () => {
    // iOS WKWebView delivers script messages asynchronously, so its
    // `XBridgeSync.callSync` returns a Promise, which a synchronous adapter
    // cannot consume. It must warn and return undefined, not a dangling Promise.
    globalThis.XBridgeSync = {
      callSync: () => Promise.resolve({ result: "should-not-be-returned" }),
    };
    const warnings = [];
    const origWarn = console.warn;
    console.warn = (msg) => { warnings.push(msg); };
    try {
      const bridge = new XBridge();
      const res = bridge.callSync("asyncOnly", {});
      assert.equal(res, undefined);
      assert.ok(
        warnings.some((w) => typeof w === "string" && w.includes("asynchronous")),
        "expected a warning guiding callers to the async channel",
      );
      bridge.dispose();
    } finally {
      console.warn = origWarn;
    }
  });

  test("16. legacy dsbridge still routes through callSync when XBridgeSync is absent", () => {
    const calls = [];
    globalThis.dsbridge = {
      call: (method, args) => {
        calls.push({ method, args });
        return { value: 42 };
      },
    };
    const bridge = new XBridge();
    const res = bridge.callSync("legacyMethod", { a: 1 });
    assert.deepEqual(res, { value: 42 });
    assert.deepEqual(calls[0], { method: "legacyMethod", args: { a: 1 } });
    bridge.dispose();
  });
});
