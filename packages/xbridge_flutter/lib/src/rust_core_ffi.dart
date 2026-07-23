import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _CFFIEcho = Int32 Function(
  Pointer<Uint8> inPtr,
  IntPtr inLen,
  Pointer<Pointer<Uint8>> outPtr,
  Pointer<IntPtr> outLen,
);

typedef _DartFFIEcho = int Function(
  Pointer<Uint8> inPtr,
  int inLen,
  Pointer<Pointer<Uint8>> outPtr,
  Pointer<IntPtr> outLen,
);

typedef _CFFIFree = Void Function(Pointer<Uint8> ptr, IntPtr len);
typedef _DartFFIFree = void Function(Pointer<Uint8> ptr, int len);

typedef _CFFIPing = Int32 Function();
typedef _DartFFIPing = int Function();

/// `dart:ffi` binding to `xbridge_core` shared compute engine.
class RustCoreFfi {
  RustCoreFfi._();

  static DynamicLibrary? _lib;
  static bool _isInitialized = false;

  static _DartFFIEcho? _echoFunc;
  static _DartFFIFree? _freeFunc;
  static _DartFFIPing? _pingFunc;

  /// Whether the Rust native FFI library is loaded and available.
  static bool get isAvailable {
    _init();
    return _isInitialized;
  }

  static void _init() {
    if (_isInitialized) return;
    try {
      if (Platform.isAndroid) {
        _lib = DynamicLibrary.open('libxbridge_core.so');
      } else if (Platform.isIOS || Platform.isMacOS) {
        _lib = DynamicLibrary.process();
      } else {
        return;
      }

      final lib = _lib!;
      _echoFunc = lib.lookupFunction<_CFFIEcho, _DartFFIEcho>('xbridge_ffi_echo');
      _freeFunc = lib.lookupFunction<_CFFIFree, _DartFFIFree>('xbridge_ffi_free');
      _pingFunc = lib.lookupFunction<_CFFIPing, _DartFFIPing>('xbridge_ffi_ping');
      _isInitialized = true;
    } catch (_) {
      _isInitialized = false;
    }
  }

  /// Pings the Rust engine. Returns 200 on success, -1 if unavailable.
  static int ping() {
    _init();
    final func = _pingFunc;
    if (func == null) return -1;
    return func();
  }

  /// Echoes bytes via Rust FFI. Returns null if unavailable or error.
  static Uint8List? echo(Uint8List input) {
    _init();
    final echoFn = _echoFunc;
    final freeFn = _freeFunc;
    if (echoFn == null || freeFn == null) return null;

    final inPtr = malloc<Uint8>(input.length);
    final inBytes = inPtr.asTypedList(input.length);
    inBytes.setAll(0, input);

    final outPtrPtr = malloc<Pointer<Uint8>>();
    final outLenPtr = malloc<IntPtr>();

    try {
      final res = echoFn(inPtr, input.length, outPtrPtr, outLenPtr);
      if (res != 0) {
        // Even on error, the Rust side may have allocated an output buffer
        // before returning a non-zero status. Free it to avoid a leak.
        final errPtr = outPtrPtr.value;
        final errLen = outLenPtr.value;
        if (errPtr != nullptr && errLen > 0) {
          freeFn(errPtr, errLen);
        }
        return null;
      }

      final outPtr = outPtrPtr.value;
      final outLen = outLenPtr.value;

      // Validate pointer and length before creating a typed list view.
      if (outPtr == nullptr || outLen <= 0 || outLen > 1024 * 1024 * 1024) {
        // Invalid output — skip free if pointer is null to avoid crash.
        if (outPtr != nullptr && outLen > 0) {
          freeFn(outPtr, outLen);
        }
        return null;
      }

      final result = Uint8List.fromList(outPtr.asTypedList(outLen));
      freeFn(outPtr, outLen);
      return result;
    } finally {
      malloc.free(inPtr);
      malloc.free(outPtrPtr);
      malloc.free(outLenPtr);
    }
  }
}
