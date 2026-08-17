import 'dart:ffi';
import 'dart:io';

import 'package:cross_desktop_remote/core/bridge/core_bridge.dart';

typedef _ReadUint32Native = Uint32 Function();
typedef _ReadUint32Dart = int Function();
typedef _ReadUint64Native = Uint64 Function();
typedef _ReadUint64Dart = int Function();

final class NativeCoreBridge implements CoreBridge {
  NativeCoreBridge._(DynamicLibrary library)
    : _readAbiVersion = library
          .lookupFunction<_ReadUint32Native, _ReadUint32Dart>(
            'cdr_core_abi_version',
          ),
      _readProtocolMajorVersion = library
          .lookupFunction<_ReadUint32Native, _ReadUint32Dart>(
            'cdr_core_protocol_major_version',
          ),
      _readFeatureFlags = library
          .lookupFunction<_ReadUint64Native, _ReadUint64Dart>(
            'cdr_core_feature_flags',
          );

  factory NativeCoreBridge.open({String? libraryPath}) {
    return NativeCoreBridge._(_openLibrary(libraryPath));
  }

  final _ReadUint32Dart _readAbiVersion;
  final _ReadUint32Dart _readProtocolMajorVersion;
  final _ReadUint64Dart _readFeatureFlags;

  @override
  CoreBuildInfo readBuildInfo() {
    return CoreBuildInfo(
      abiVersion: _readAbiVersion(),
      protocolMajorVersion: _readProtocolMajorVersion(),
      featureFlags: _readFeatureFlags(),
    );
  }

  static DynamicLibrary _openLibrary(String? libraryPath) {
    if (libraryPath != null && libraryPath.isNotEmpty) {
      return DynamicLibrary.open(libraryPath);
    }
    if (Platform.isIOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isMacOS) {
      return DynamicLibrary.open('libcrossdesktop_core.dylib');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('crossdesktop_core.dll');
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return DynamicLibrary.open('libcrossdesktop_core.so');
    }

    throw UnsupportedError('The Rust core is not supported on this platform.');
  }
}
