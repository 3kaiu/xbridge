import { test, describe, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import {
  XBridge,
  XBridgeCore,
  StandardAdapter,
  resetSniffCache,
  XBridgeSendError,
  isInvalidAccessError,
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

  test("17. Probe-verified availability: postMessage throwing InvalidAccessError marks env broken, then self-heals after cooldown", () => {
    // A "present-but-broken" bridge: postMessage exists but throws synchronously
    // (WKWebView does this when the webkit.messageHandlers.XBridge handler is
    // not actually registered in a third-party host like XiaoeEmbed).
    const originalNow = Date.now;
    let now = 1_000_000;
    Date.now = () => now;

    let nativeReady = false;
    globalThis.XBridge = {
      postMessage: (raw) => {
        // Once the (simulated) native handler is injected, the probe succeeds.
        if (!nativeReady) {
          const err = new Error("The object does not support the operation or argument.");
          err.name = "InvalidAccessError";
          throw err;
        }
      },
    };

    const adapter = new StandardAdapter();
    assert.equal(adapter.availabilityProbe, "unprobed");
    // First isAvailable() sends the synchronous probe, catches InvalidAccessError
    // and marks the environment broken -> returns false WITHOUT throwing.
    assert.equal(adapter.isAvailable(), false);
    assert.equal(adapter.availabilityProbe, "broken");

    // Before cooldown elapses, availability stays broken and does NOT re-probe.
    now += 1000; // < 5000ms cooldown
    assert.equal(adapter.isAvailable(), false);
    assert.equal(adapter.availabilityProbe, "broken");

    // Simulate the host injecting the native handler after the initial failure.
    nativeReady = true;

    // Before cooldown elapses the verdict is still broken (no re-probe fired).
    assert.equal(adapter.isAvailable(), false);
    assert.equal(adapter.availabilityProbe, "broken");

    // After cooldown elapses, isAvailable() re-probes and sees the working
    // transport -> the same engine self-heals to healthy.
    now += 5000;
    assert.equal(adapter.isAvailable(), true);
    assert.equal(adapter.availabilityProbe, "healthy");

    // A fresh healthy verdict is stable and does not re-probe again.

    // And the bridge reports connected, so callers use the bridge.
    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), true);
    bridge.dispose();
    adapter.destroy();
    Date.now = originalNow;
  });

  test("18. Probe-verified availability: healthy postMessage marks env healthy and sends __xbridge_probe__", () => {
    const sent = [];
    globalThis.XBridge = {
      postMessage: (raw) => { sent.push(JSON.parse(raw)); },
    };

    const adapter = new StandardAdapter();
    assert.equal(adapter.isAvailable(), true);
    assert.equal(adapter.availabilityProbe, "healthy");

    // Probe transmitted exactly once, with the reserved probe method.
    assert.equal(sent.length, 1);
    assert.equal(sent[0].method, "__xbridge_probe__");
    assert.equal(sent[0].id, null);

    // Second check does not re-probe (transmit-once semantics).
    adapter.isAvailable();
    assert.equal(sent.length, 1);

    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), true);
    bridge.dispose();
    adapter.destroy();
  });

  test("19. Probe-verified availability: non-XBridge signals (inappwebview) stay available without probe", () => {
    // flutter_inappwebview path should remain available without a probe message.
    globalThis.flutter_inappwebview = {
      callHandler: () => {},
    };
    const adapter = new StandardAdapter();
    assert.equal(adapter.isAvailable(), true);
    assert.equal(adapter.availabilityProbe, "unprobed");
    adapter.destroy();
  });
  test("20. postMessage InvalidAccessError must NEVER fire global unhandledrejection", async () => {
    let unhandledCaught = false;
    const onUnhandled = (reason) => { unhandledCaught = true; };
    process.on("unhandledRejection", onUnhandled);

    try {
      const mockPostMessage = () => {
        const err = new Error("The object does not support the operation or argument.");
        err.name = "InvalidAccessError";
        throw err;
      };

      globalThis.window = globalThis;
      globalThis.XBridge = { postMessage: mockPostMessage };

      const adapter = new StandardAdapter();
      const bridge = new XBridgeCore(adapter);

      // Call method without fallback; should safely settle without unhandled rejection
      const res = await bridge.call("testSafeHeight", {}, { timeout: 100, readyTimeout: 100 });
      assert.strictEqual(res, undefined);

      // Wait 150ms to cross all microtask and timer boundaries
      await new Promise(r => setTimeout(r, 150));
      assert.strictEqual(unhandledCaught, false, "Must not fire unhandledRejection");

      bridge.dispose();
    } finally {
      process.off("unhandledRejection", onUnhandled);
      delete globalThis.XBridge;
      delete globalThis.window;
    }
  });
  test("21. noCallback: true with InvalidAccessError must NEVER fire global unhandledrejection", async () => {
    let unhandledCaught = false;
    const onUnhandled = (reason) => { unhandledCaught = true; };
    process.on("unhandledRejection", onUnhandled);

    try {
      const mockPostMessage = () => {
        const err = new Error("The object does not support the operation or argument.");
        err.name = "InvalidAccessError";
        throw err;
      };

      globalThis.window = globalThis;
      globalThis.XBridge = { postMessage: mockPostMessage };

      const adapter = new StandardAdapter();
      const bridge = new XBridgeCore(adapter);

      const res = await bridge.call("stopSound", {}, { noCallback: true, timeout: 100, readyTimeout: 100 });
      assert.strictEqual(res, undefined);

      await new Promise(r => setTimeout(r, 150));
      assert.strictEqual(unhandledCaught, false, "Must not fire unhandledRejection");

      bridge.dispose();
    } finally {
      process.off("unhandledRejection", onUnhandled);
      delete globalThis.XBridge;
      delete globalThis.window;
    }
  });

  test("22. Regular business errors must still be properly thrown and not suppressed", async () => {
    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        setTimeout(() => {
          globalThis.__XBridge__.reject(req.id, { code: 403, message: "Permission Denied" });
        }, 5);
      },
    };

    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), true);

    await assert.rejects(
      bridge.call("getUserToken", {}),
      (err) => {
        assert.strictEqual(err.code, 403);
        assert.strictEqual(err.message, "Permission Denied");
        return true;
      },
      "Business error must be thrown normally"
    );

    bridge.dispose();
  });
  test("23. Concurrency storm: 10 simultaneous calls with InvalidAccessError must NEVER fire unhandledrejection", async () => {
    let unhandledCount = 0;
    const onUnhandled = () => { unhandledCount++; };
    process.on("unhandledRejection", onUnhandled);

    try {
      const mockPostMessage = () => {
        const err = new Error("The object does not support the operation or argument.");
        err.name = "InvalidAccessError";
        throw err;
      };

      globalThis.window = globalThis;
      globalThis.XBridge = { postMessage: mockPostMessage };

      const adapter = new StandardAdapter();
      const bridge = new XBridgeCore(adapter);

      // Launch 10 concurrent requests at the exact same microtask tick
      const promises = Array.from({ length: 10 }, (_, i) =>
        bridge.call(`batchMethod_${i}`, { index: i }, { timeout: 100, readyTimeout: 100, fallback: `fallback_${i}` })
      );

      const results = await Promise.all(promises);
      for (let i = 0; i < 10; i++) {
        assert.strictEqual(results[i], `fallback_${i}`);
      }

      await new Promise(r => setTimeout(r, 200));
      assert.strictEqual(unhandledCount, 0, "No unhandled rejection must escape during concurrent storm");

      bridge.dispose();
    } finally {
      process.off("unhandledRejection", onUnhandled);
      delete globalThis.XBridge;
      delete globalThis.window;
    }
  });

  test("24. Legacy iOS App startup race self-healing: transient error recovers on 120ms backoff retry", async () => {
    let bizAttempts = 0;
    let bizCalls = 0;

    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        // Probe message passes (host has injected handle)
        if (req.method === "__xbridge_probe__") {
          return;
        }
        bizCalls++;
        // First business attempt throws InvalidAccessError (Provisional Navigation)
        if (bizAttempts === 0) {
          bizAttempts++;
          const err = new Error("The object does not support the operation or argument.");
          err.name = "InvalidAccessError";
          throw err;
        }
        // Second business attempt (after ~120ms backoff) succeeds!
        setTimeout(() => {
          globalThis.__XBridge__.resolve(req.id, { height: 44 });
        }, 10);
      },
    };

    const bridge = new XBridge();
    assert.equal(bridge.isConnected(), true);

    // Caller issues getStatusBarHeight during page startup
    const res = await bridge.call("getStatusBarHeight", {});
    assert.deepStrictEqual(res, { height: 44 }, "Must successfully recover and return response after retry");
    assert.strictEqual(bizCalls, 2, "Business call must have retried exactly once and succeeded");

    bridge.dispose();
  });

  test("25. Circuit breaker immunity: consecutive InvalidAccessError must NEVER trip circuit breaker to OPEN", async () => {
    let callCount = 0;
    const adapter = new StandardAdapter();

    globalThis.window = globalThis;
    globalThis.XBridge = {
      postMessage: () => {
        callCount++;
        if (callCount <= 5) {
          const err = new Error("The object does not support the operation or argument.");
          err.name = "InvalidAccessError";
          throw err;
        }
        // Call 6 succeeds
      },
    };

    // Send 5 transient errors (exceeding MAX_FAILURES = 2)
    for (let i = 0; i < 5; i++) {
      assert.throws(
        () => adapter.send(JSON.stringify({ jsonrpc: "2.0", id: `test_${i}`, method: "testMethod" })),
        (err) => err.name === "XBridgeSendError"
      );
    }

    // Circuit state must remain CLOSED and healthy
    assert.strictEqual(adapter.state, "CLOSED", "Transient errors must not trip circuit breaker");

    // Call 6 must send without being rejected by circuit breaker
    assert.doesNotThrow(() => {
      adapter.send(JSON.stringify({ jsonrpc: "2.0", id: "test_6", method: "testMethod" }));
    });

    adapter.destroy();
    delete globalThis.XBridge;
    delete globalThis.window;
  });

  test("26. Heterogeneous InvalidAccessError detection: DOMException code 15 and deeply nested cause", async () => {
    const adapter = new StandardAdapter();
    const bridge = new XBridgeCore(adapter);

    // Deeply nested cause: Error -> SendError -> DOMException-like
    const nestedError = new Error("Top level failure", {
      cause: new Error("Wrapper failure", {
        cause: { name: "InvalidAccessError", code: 15, message: "native denied" }
      })
    });

    assert.strictEqual(bridge["isInvalidAccessError"](nestedError), true, "Deeply nested cause must be detected");

    // Irrelevant errors must NOT be detected
    const typeError = new TypeError("Cannot read property of undefined");
    assert.strictEqual(bridge["isInvalidAccessError"](typeError), false, "TypeError must not match");

    const networkError = new Error("Network request failed");
    assert.strictEqual(bridge["isInvalidAccessError"](networkError), false, "NetworkError must not match");

    // Circular cause must not cause RangeError stack overflow
    const circularError = new Error("Circular parent");
    const childError = new Error("Circular child", { cause: circularError });
    circularError.cause = childError;
    assert.strictEqual(bridge["isInvalidAccessError"](circularError), false, "Circular error must terminate safely without stack overflow");

    bridge.dispose();
  });

  test("27. Fallback transparency: fallback option must NOT bypass auto-retry on transient error", async () => {
    let bizAttempts = 0;
    let bizCalls = 0;

    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        if (req.method === "__xbridge_probe__") return;
        bizCalls++;
        if (bizAttempts === 0) {
          bizAttempts++;
          const err = new Error("The object does not support the operation or argument.");
          err.name = "InvalidAccessError";
          throw err;
        }
        setTimeout(() => {
          globalThis.__XBridge__.resolve(req.id, { safeArea: 50 });
        }, 5);
      },
    };

    const bridge = new XBridge();
    // Caller provides fallback: 0. Even with fallback, it MUST auto-retry and recover real data!
    const res = await bridge.call("getSafeArea", {}, { fallback: 0 });
    assert.deepStrictEqual(res, { safeArea: 50 }, "Must recover real value via auto-retry rather than prematurely returning fallback");
    assert.strictEqual(bizCalls, 2, "Must retry exactly once");

    bridge.dispose();
  });

  test("28. Fallback fallback: when retry also fails with transient error, fallback is returned safely", async () => {
    let bizCalls = 0;

    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        if (req.method === "__xbridge_probe__") return;
        bizCalls++;
        const err = new Error("The object does not support the operation or argument.");
        err.name = "InvalidAccessError";
        throw err;
      },
    };

    const bridge = new XBridge();
    // Both attempt 0 and retry attempt 1 fail with InvalidAccessError -> fallback safely returned
    const res = await bridge.call("getSafeArea", {}, { fallback: 44 });
    assert.strictEqual(res, 44, "Must safely return fallback when both initial call and retry fail");
    assert.strictEqual(bizCalls, 2, "Must have retried once before giving up and returning fallback");

    bridge.dispose();
  });

  test("29. XBridgeReady acceleration: modern App emitting XBridgeReady wakes up retry before 120ms timeout", async () => {
    let bizAttempts = 0;
    const startTime = Date.now();
    const listeners = new Map();
    const origAdd = globalThis.addEventListener;
    const origRemove = globalThis.removeEventListener;
    const origDispatch = globalThis.dispatchEvent;

    globalThis.addEventListener = (type, fn, opts) => {
      if (!listeners.has(type)) listeners.set(type, new Set());
      const wrapper = (ev) => {
        if (opts?.once) listeners.get(type)?.delete(wrapper);
        fn(ev);
      };
      listeners.get(type).add(wrapper);
    };
    globalThis.removeEventListener = (type, fn) => {
      listeners.get(type)?.delete(fn);
    };
    globalThis.dispatchEvent = (ev) => {
      const set = listeners.get(ev.type);
      if (set) {
        for (const fn of Array.from(set)) {
          fn(ev);
        }
      }
      return true;
    };

    try {
      globalThis.XBridge = {
        postMessage: (raw) => {
          const req = JSON.parse(raw);
          if (req.method === "__xbridge_probe__") return;
          if (bizAttempts === 0) {
            bizAttempts++;
            // Container fires XBridgeReady 20ms later to notify H5 that WKWebView message handler is re-attached
            setTimeout(() => {
              globalThis.dispatchEvent(new Event("XBridgeReady"));
            }, 20);
            const err = new Error("The object does not support the operation or argument.");
            err.name = "InvalidAccessError";
            throw err;
          }
          setTimeout(() => {
            globalThis.__XBridge__.resolve(req.id, { token: "quick_token" });
          }, 5);
        },
      };

      const bridge = new XBridge();
      const res = await bridge.call("getToken");
      const elapsed = Date.now() - startTime;
      assert.deepStrictEqual(res, { token: "quick_token" });
      // Should wake up around ~25-60ms (well below the 120ms fallback timeout)
      assert.ok(elapsed < 110, `Elapsed time (${elapsed}ms) should be less than 110ms due to XBridgeReady acceleration`);

      bridge.dispose();
    } finally {
      globalThis.addEventListener = origAdd;
      globalThis.removeEventListener = origRemove;
      globalThis.dispatchEvent = origDispatch;
    }
  });

  test("30. ready() AbortSignal support: cancels polling and rejects without leaking", async () => {
    // 1. Abort before call
    const controller1 = new AbortController();
    controller1.abort();
    const bridge1 = new XBridge();
    await assert.rejects(
      () => bridge1.ready(1000, controller1.signal),
      (err) => err.message.includes("aborted")
    );
    bridge1.dispose();

    // 2. Abort midway during polling
    const controller2 = new AbortController();
    const bridge2 = new XBridge();
    const readyPromise = bridge2.ready(2000, controller2.signal);
    setTimeout(() => {
      controller2.abort();
    }, 50);

    await assert.rejects(
      () => readyPromise,
      (err) => err.message.includes("aborted")
    );
    bridge2.dispose();
  });

  test("31. Enterprise onTransportWarning hook receives diagnostic snapshot on failure", async () => {
    let warningSnapshot = null;

    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        if (req.method === "__xbridge_probe__") return;
        const err = new Error("Provisional navigation in progress");
        err.name = "InvalidAccessError";
        throw err;
      },
    };

    const bridge = new XBridge({
      onTransportWarning: (snapshot) => {
        warningSnapshot = snapshot;
      },
    });

    await bridge.call("testWarning", { p: 1 }, { fallback: "warn_fallback" });
    assert.ok(warningSnapshot !== null, "onTransportWarning must be invoked on transport error");
    assert.strictEqual(warningSnapshot.method, "testWarning");
    assert.strictEqual(warningSnapshot.errorName, "InvalidAccessError");
    assert.strictEqual(warningSnapshot.circuitState, "CLOSED");

    bridge.dispose();
  });

  test("32. BFCache pageshow self-healing: resets circuit breaker and availability probe", async () => {
    const listeners = new Map();
    const origAdd = globalThis.addEventListener;
    const origRemove = globalThis.removeEventListener;
    const origDispatch = globalThis.dispatchEvent;

    globalThis.addEventListener = (type, fn) => {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(fn);
    };
    globalThis.removeEventListener = (type, fn) => {
      listeners.get(type)?.delete(fn);
    };
    globalThis.dispatchEvent = (ev) => {
      const set = listeners.get(ev.type);
      if (set) {
        for (const fn of Array.from(set)) {
          fn(ev);
        }
      }
      return true;
    };

    try {
      const adapter = new StandardAdapter();
      // Simulate broken state
      adapter["circuitState"] = "OPEN";
      adapter["lastFailureTime"] = Date.now();
      adapter["availabilityProbeState"] = "broken";
      adapter["availabilityProbeTransmitted"] = true;

      assert.strictEqual(adapter.isAvailable(), false);

      // Simulate pageshow event with persisted = true (BFCache restore)
      const pageshowEvent = new Event("pageshow");
      Object.defineProperty(pageshowEvent, "persisted", { value: true });
      globalThis.dispatchEvent(pageshowEvent);

      // State should be reset to CLOSED and unprobed
      assert.strictEqual(adapter.state, "CLOSED");
      assert.strictEqual(adapter.availabilityProbe, "unprobed");

      adapter.destroy();
    } finally {
      globalThis.addEventListener = origAdd;
      globalThis.removeEventListener = origRemove;
      globalThis.dispatchEvent = origDispatch;
    }
  });

  test("33. Probe cooldown differentiation: transient (200ms) vs permanent (5000ms)", () => {
    const originalNow = Date.now;
    let now = 100_000;
    Date.now = () => now;

    try {
      // 1. Transient error: InvalidAccessError uses 200ms cooldown
      let ready = false;
      globalThis.XBridge = {
        postMessage: () => {
          if (!ready) {
            const err = new Error("The object does not support the operation or argument.");
            err.name = "InvalidAccessError";
            throw err;
          }
        },
      };

      const adapter1 = new StandardAdapter();
      assert.strictEqual(adapter1.isAvailable(), false);
      assert.strictEqual(adapter1.availabilityProbe, "broken");

      ready = true;
      now += 150; // < 200ms cooldown
      assert.strictEqual(adapter1.isAvailable(), false, "At 150ms (<200ms), must still be broken");

      now += 60; // total 210ms >= 200ms
      assert.strictEqual(adapter1.isAvailable(), true, "At 210ms (>=200ms), must re-probe and heal");
      assert.strictEqual(adapter1.availabilityProbe, "healthy");
      adapter1.destroy();

      // 2. Permanent/unknown error: uses 5000ms cooldown
      ready = false;
      globalThis.XBridge = {
        postMessage: () => {
          if (!ready) {
            throw new Error("Unknown host security exception");
          }
        },
      };

      const adapter2 = new StandardAdapter();
      assert.strictEqual(adapter2.isAvailable(), false);
      assert.strictEqual(adapter2.availabilityProbe, "broken");

      ready = true;
      now += 1000; // < 5000ms cooldown
      assert.strictEqual(adapter2.isAvailable(), false, "At 1000ms (<5000ms), must still be broken");

      now += 4050; // total 5050ms >= 5000ms
      assert.strictEqual(adapter2.isAvailable(), true, "At 5050ms (>=5000ms), must re-probe and heal");
      assert.strictEqual(adapter2.availabilityProbe, "healthy");
      adapter2.destroy();
    } finally {
      Date.now = originalNow;
    }
  });

  test("34. Leak protection: destroy() cleans up pageshow listener even if saved globals were never initialized", () => {
    let pageshowAdded = false;
    let pageshowRemoved = false;
    const origAdd = globalThis.addEventListener;
    const origRemove = globalThis.removeEventListener;

    globalThis.addEventListener = (type) => {
      if (type === "pageshow") pageshowAdded = true;
    };
    globalThis.removeEventListener = (type) => {
      if (type === "pageshow") pageshowRemoved = true;
    };

    try {
      const adapter = new StandardAdapter();
      assert.strictEqual(pageshowAdded, true, "pageshow listener must be installed on construction");
      // saved is null because neither onMessage nor send was called
      assert.strictEqual(adapter["saved"], null);

      adapter.destroy();
      assert.strictEqual(pageshowRemoved, true, "pageshow listener must be removed on destroy even if saved is null");
      assert.strictEqual(adapter["boundPageshowListener"], null);
    } finally {
      globalThis.addEventListener = origAdd;
      globalThis.removeEventListener = origRemove;
    }
  });

  test("35. Teardown protection: dispose() during 120ms backoff aborts immediately without waiting or retrying", async () => {
    let bizCalls = 0;
    const startTime = Date.now();

    globalThis.XBridge = {
      postMessage: (raw) => {
        const req = JSON.parse(raw);
        if (req.method === "__xbridge_probe__") return;
        bizCalls++;
        const err = new Error("The object does not support the operation or argument.");
        err.name = "InvalidAccessError";
        throw err;
      },
    };

    const bridge = new XBridge();
    const callPromise = bridge.call("testDisposeDuringBackoff");

    // After 20ms (well before 120ms backoff completes), dispose the bridge!
    setTimeout(() => {
      bridge.dispose();
    }, 20);

    // Call must reject with "disposed" immediately, without hanging or retrying
    await assert.rejects(
      () => callPromise,
      (err) => err.message.includes("disposed")
    );

    const elapsed = Date.now() - startTime;
    assert.ok(elapsed < 90, `Call must reject promptly upon dispose (${elapsed}ms < 90ms), not wait for 120ms backoff`);
    assert.strictEqual(bizCalls, 1, "Must NOT have executed retry call after dispose");
  });

  test("36. Teardown protection: calling call() on already-disposed bridge immediately rejects", async () => {
    const bridge = new XBridge();
    bridge.dispose();

    await assert.rejects(
      () => bridge.call("anyMethod"),
      (err) => err.message.includes("disposed")
    );
  });

  test("37. Stress & Concurrency: 50 concurrent mixed calls with zero unhandled rejection and correct routing", async () => {
    let unhandledCount = 0;
    const onUnhandled = () => { unhandledCount++; };
    process.on("unhandledRejection", onUnhandled);

    try {
      let callCount = 0;
      globalThis.XBridge = {
        postMessage: (raw) => {
          const req = JSON.parse(raw);
          if (req.method === "__xbridge_probe__") return;
          callCount++;
          const idx = req.params?.index ?? 0;
          if (idx % 3 === 0) {
            // Success response
            setTimeout(() => {
              globalThis.__XBridge__.resolve(req.id, { answer: `success_${idx}` });
            }, 5);
          } else if (idx % 3 === 1) {
            // Business error response
            setTimeout(() => {
              globalThis.__XBridge__.reject(req.id, { code: -32001, message: `biz_error_${idx}` });
            }, 5);
          } else {
            // Transient InvalidAccessError
            const err = new Error("Provisional navigation in progress");
            err.name = "InvalidAccessError";
            throw err;
          }
        },
      };

      const bridge = new XBridge();
      const promises = Array.from({ length: 50 }, async (_, i) => {
        try {
          const res = await bridge.call(`method_${i}`, { index: i }, { timeout: 300, fallback: `fb_${i}` });
          return { status: "resolved", value: res };
        } catch (err) {
          return { status: "rejected", error: err };
        }
      });

      const results = await Promise.all(promises);

      for (let i = 0; i < 50; i++) {
        const item = results[i];
        if (i % 3 === 0) {
          assert.deepStrictEqual(item.value, { answer: `success_${i}` });
        } else if (i % 3 === 1) {
          assert.strictEqual(item.status, "rejected");
          assert.strictEqual(item.error.message, `biz_error_${i}`);
        } else {
          // Transient InvalidAccessError fell back safely to fallback
          assert.strictEqual(item.value, `fb_${i}`);
        }
      }

      await new Promise((r) => setTimeout(r, 100));
      assert.strictEqual(unhandledCount, 0, "No unhandled rejection may escape under 50-concurrency load");

      bridge.dispose();
    } finally {
      process.off("unhandledRejection", onUnhandled);
    }
  });

  test("38. Boundary: circular structure parameter in call() rejects gracefully with TypeError and cleans up", async () => {
    globalThis.XBridge = {
      postMessage: () => {},
    };

    const bridge = new XBridge();
    const circular = { name: "loop" };
    circular.self = circular;

    await assert.rejects(
      () => bridge.call("circularTest", circular),
      (err) => err instanceof TypeError
    );

    // Ensure dispatcher has no leaked pending requests
    assert.strictEqual(bridge["core"]["dispatcher"].size, 0, "Dispatcher must have 0 pending entries after serialization failure");
    bridge.dispose();
  });

  test("39. Host RPC: unregistered method returns standard -32601 Method not found", async () => {
    let sentBack;
    globalThis.XBridge = {
      postMessage: (raw) => {
        sentBack = JSON.parse(raw);
      },
    };

    const bridge = new XBridge();
    // Host invokes unknownMethod
    globalThis.__XBridgeInbound__(
      JSON.stringify({ jsonrpc: "2.0", id: "rpc_unknown", method: "nonExistentMethod", params: {} })
    );

    await new Promise((r) => setTimeout(r, 10));
    assert.deepStrictEqual(sentBack, {
      jsonrpc: "2.0",
      id: "rpc_unknown",
      error: { code: -32601, message: "Method not found" },
    });

    bridge.dispose();
  });

  test("40. Host RPC: handler async error serialization preserves Error name and message", async () => {
    let sentBack;
    globalThis.XBridge = {
      postMessage: (raw) => {
        sentBack = JSON.parse(raw);
      },
    };

    const bridge = new XBridge();
    bridge.registerHandler("failingHandler", async () => {
      const err = new Error("Database query failed");
      err.name = "DatabaseError";
      throw err;
    });

    globalThis.__XBridgeInbound__(
      JSON.stringify({ jsonrpc: "2.0", id: "rpc_fail", method: "failingHandler", params: {} })
    );

    await new Promise((r) => setTimeout(r, 15));
    assert.strictEqual(sentBack.id, "rpc_fail");
    assert.strictEqual(sentBack.error.code, -32000);
    assert.strictEqual(sentBack.error.message, "Database query failed");
    assert.deepStrictEqual(sentBack.error.data, { name: "DatabaseError", message: "Database query failed" });

    bridge.dispose();
  });

  test("41. Independent AbortSignals: aborting one ready() does not affect concurrent ready()", async () => {
    const bridge = new XBridge();
    const ctrl1 = new AbortController();
    const ctrl2 = new AbortController();

    const p1 = bridge.ready(1000, ctrl1.signal);
    const p2 = bridge.ready(1000, ctrl2.signal);

    // Abort only ctrl1
    ctrl1.abort();

    // p1 must reject with aborted
    await assert.rejects(
      () => p1,
      (err) => err.message.includes("aborted")
    );

    // Inject bridge so p2 can resolve
    setTimeout(() => {
      globalThis.XBridge = { postMessage: () => {} };
      if (typeof globalThis.dispatchEvent === "function") {
        globalThis.dispatchEvent(new Event("XBridgeReady"));
      }
    }, 20);

    // p2 must resolve successfully
    await p2;
    assert.strictEqual(bridge.isConnected(), true);

    bridge.dispose();
  });

  test("42. Inbound Robustness: Malformed or primitive inbound messages do not crash bridge", () => {
    globalThis.XBridge = { postMessage: () => {} };
    const bridge = new XBridge();

    // Passing various malformed, primitive, or non-JSON payloads to __XBridgeInbound__
    assert.doesNotThrow(() => {
      globalThis.__XBridgeInbound__("null");
      globalThis.__XBridgeInbound__("123");
      globalThis.__XBridgeInbound__("true");
      globalThis.__XBridgeInbound__("\"hello\"");
      globalThis.__XBridgeInbound__("{}");
      globalThis.__XBridgeInbound__("not-valid-json");
      globalThis.__XBridgeInbound__(null);
      globalThis.__XBridgeInbound__(42);
      globalThis.__XBridgeInbound__(undefined);
    });

    bridge.dispose();
  });

  test("43. Host RPC handler returning circular structure sends back JSON-RPC -32603 response", async () => {
    let sentPayload = null;
    globalThis.XBridge = {
      postMessage: (msg) => {
        sentPayload = JSON.parse(msg);
      },
    };

    const bridge = new XBridge();
    const circularObj = { name: "circular" };
    circularObj.self = circularObj;

    bridge.registerHandler("getCircular", () => {
      return circularObj;
    });

    globalThis.__XBridgeInbound__(
      JSON.stringify({ jsonrpc: "2.0", id: "rpc_circ", method: "getCircular", params: {} })
    );

    await new Promise((r) => setTimeout(r, 15));
    assert.notStrictEqual(sentPayload, null, "Must send response to host");
    assert.strictEqual(sentPayload.id, "rpc_circ");
    assert.strictEqual(sentPayload.error.code, -32603);
    assert.match(sentPayload.error.message, /could not be serialized/);

    bridge.dispose();
  });

  test("44. Post-disposal safeguards: bridge.call, onEvent, and registerHandler", async () => {
    globalThis.XBridge = { postMessage: () => {} };
    const bridge = new XBridge();
    bridge.dispose();

    // 1. call() rejects immediately
    await assert.rejects(
      bridge.call("test"),
      (err) => err instanceof XBridgeSendError && err.message.includes("disposed")
    );

    // 2. onEvent returns clean unregister without throwing
    const unlisten = bridge.onEvent("someEvent", () => {});
    assert.strictEqual(typeof unlisten, "function");
    assert.doesNotThrow(() => unlisten());

    // 3. registerHandler returns clean unregister without throwing
    const unregister = bridge.registerHandler("someMethod", () => {});
    assert.strictEqual(typeof unregister, "function");
    assert.doesNotThrow(() => unregister());

    // 4. Repeated dispose is idempotent
    assert.doesNotThrow(() => bridge.dispose());
  });

  test("45. Disposal while awaiting ready() inside call() rejects immediately", async () => {
    // Disconnected environment
    const bridge = new XBridge();

    const callPromise = bridge.call("testMethod", {}, { readyTimeout: 5000 });

    // While awaiting ready(), dispose the bridge
    setTimeout(() => {
      bridge.dispose();
    }, 20);

    const start = Date.now();
    await assert.rejects(
      callPromise,
      (err) => err instanceof XBridgeSendError && err.message.includes("disposed")
    );
    const elapsed = Date.now() - start;
    assert.ok(elapsed < 1000, `Must reject immediately upon dispose, elapsed ${elapsed}ms`);
  });

  test("46. isInvalidAccessError boundary coverage: strings, Error objects, and depth limit", () => {
    // String errors
    assert.strictEqual(isInvalidAccessError("InvalidAccessError: Provisional navigation in progress"), true);
    assert.strictEqual(isInvalidAccessError("The object does not support the operation"), true);
    assert.strictEqual(isInvalidAccessError("Error: Some InvalidAccessError occurred"), true);
    assert.strictEqual(isInvalidAccessError("NetworkError"), false);
    assert.strictEqual(isInvalidAccessError(""), false);

    // Error objects
    const domErr = new Error("provisional navigation");
    domErr.name = "InvalidAccessError";
    assert.strictEqual(isInvalidAccessError(domErr), true);

    const code15 = new Error("native error");
    code15.code = 15;
    assert.strictEqual(isInvalidAccessError(code15), true);

    const msgErr = new Error("The object does not support the operation");
    assert.strictEqual(isInvalidAccessError(msgErr), true);

    const wrappedErr = new Error("Failed to call");
    wrappedErr.cause = domErr;
    assert.strictEqual(isInvalidAccessError(wrappedErr), true);

    // Non-errors
    assert.strictEqual(isInvalidAccessError(null), false);
    assert.strictEqual(isInvalidAccessError(undefined), false);
    assert.strictEqual(isInvalidAccessError(123), false);
    assert.strictEqual(isInvalidAccessError({}), false);
  });

  test("47. ready() fast rejection on invalid or non-finite timeout inputs", async () => {
    const bridge = new XBridge();

    await assert.rejects(
      bridge.ready(NaN),
      (err) => err instanceof XBridgeSendError && err.message.includes("not ready")
    );
    await assert.rejects(
      bridge.ready(-10),
      (err) => err instanceof XBridgeSendError && err.message.includes("not ready")
    );
    await assert.rejects(
      bridge.ready(0),
      (err) => err instanceof XBridgeSendError && err.message.includes("not ready")
    );

    bridge.dispose();
  });

  test("48. Host __XBridge__.reject string & Error object normalization", async () => {
    let lastSent = null;
    globalThis.XBridge = {
      postMessage: (msg) => {
        lastSent = JSON.parse(msg);
      },
    };

    const bridge = new XBridge();

    // 1. Plain string reject from host
    const p1 = bridge.call("testStringReject");
    assert.notStrictEqual(lastSent, null);
    globalThis.__XBridge__.reject(lastSent.id, "Host denied permission");
    await assert.rejects(
      p1,
      (err) => err.code === -32000 && err.message === "Host denied permission"
    );

    // 2. Error object reject from host
    lastSent = null;
    const p2 = bridge.call("testErrorReject");
    assert.notStrictEqual(lastSent, null);
    const nativeErr = new TypeError("Native texture allocation failed");
    globalThis.__XBridge__.reject(lastSent.id, nativeErr);
    await assert.rejects(
      p2,
      (err) => err.code === -32000 && err.message === "Native texture allocation failed" && err.data.name === "TypeError"
    );

    bridge.dispose();
  });

  test("49. Host __XBridge__.resolve with circular structure rejects with -32603", async () => {
    let lastSent = null;
    globalThis.XBridge = {
      postMessage: (msg) => {
        lastSent = JSON.parse(msg);
      },
    };

    const bridge = new XBridge();
    const p = bridge.call("testResolveCircular");
    assert.notStrictEqual(lastSent, null);

    const circular = { foo: "bar" };
    circular.self = circular;

    // Host attempts to resolve with circular data
    globalThis.__XBridge__.resolve(lastSent.id, circular);

    await assert.rejects(
      p,
      (err) => err.code === -32603 && err.message.includes("could not be parsed")
    );

    bridge.dispose();
  });

  test("50. CustomEvent with circular detail params does not throw in listener", () => {
    globalThis.XBridge = { postMessage: () => {} };
    const bridge = new XBridge();

    let received = null;
    bridge.onEvent("testPush", (data) => {
      received = data;
    });

    const circular = { key: "value" };
    circular.self = circular;

    assert.doesNotThrow(() => {
      if (typeof globalThis.dispatchEvent === "function") {
        globalThis.dispatchEvent(
          new CustomEvent("XBridgeEvent", {
            detail: { actionType: "testPush", params: circular },
          })
        );
      }
    });

    bridge.dispose();
  });

  test("51. noCallback: true with circular structure parameter rejects cleanly with TypeError", async () => {
    globalThis.XBridge = { postMessage: () => {} };
    const bridge = new XBridge();

    const circular = { tag: "noCallbackCircular" };
    circular.self = circular;

    await assert.rejects(
      bridge.call("fireAndForget", circular, { noCallback: true }),
      TypeError
    );

    bridge.dispose();
  });

  test("52. Zero unhandled rejection window: Promise remains pending across 120ms backoff on transient InvalidAccessError", async () => {
    let unhandledCount = 0;
    const onUnhandled = () => { unhandledCount++; };
    process.on("unhandledRejection", onUnhandled);

    try {
      let attempts = 0;
      globalThis.XBridge = {
        postMessage: (raw) => {
          const req = JSON.parse(raw);
          if (req.method === "__xbridge_probe__") return;
          attempts++;
          if (attempts === 1) {
            const err = new Error("The object does not support the operation or argument.");
            err.name = "InvalidAccessError";
            throw err;
          }
          // Second attempt succeeds
          setTimeout(() => {
            globalThis.__XBridge__.resolve(req.id, { safe: true });
          }, 5);
        },
      };

      const bridge = new XBridge();
      // Floating promise (not awaited immediately) to simulate real-world unawaited bridge call
      const promise = bridge.call("testFloatingCall", {}, { fallback: null });

      // Check promise state during backoff window (50ms into 120ms backoff)
      await new Promise(r => setTimeout(r, 50));
      assert.strictEqual(attempts, 1, "Attempt 0 must have thrown, now waiting backoff");
      assert.strictEqual(unhandledCount, 0, "No unhandled rejection may fire during backoff window");

      // Now await completion
      const res = await promise;
      assert.deepStrictEqual(res, { safe: true }, "Must recover real value on attempt 1");
      assert.strictEqual(attempts, 2, "Must have retried on attempt 1");
      assert.strictEqual(unhandledCount, 0, "Zero unhandled rejections after completion");

      bridge.dispose();
    } finally {
      process.off("unhandledRejection", onUnhandled);
      delete globalThis.XBridge;
    }
  });
});
