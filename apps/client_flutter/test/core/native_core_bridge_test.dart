import 'dart:io';

import 'package:cross_desktop_remote/core/bridge/core_bridge.dart';
import 'package:cross_desktop_remote/core/bridge/native_core_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final libraryPath = Platform.environment['CROSSDESKTOP_CORE_LIBRARY'];

  test(
    'reads build information through the Rust C ABI',
    () {
      final bridge = NativeCoreBridge.open(libraryPath: libraryPath);
      final info = bridge.readBuildInfo();

      expect(info.abiVersion, 1);
      expect(info.protocolMajorVersion, 1);
      expect(info.supports(CoreFeatures.narrowCAbi), isTrue);
      expect(info.supports(CoreFeatures.protobufV1), isTrue);
    },
    skip: libraryPath == null
        ? 'Set CROSSDESKTOP_CORE_LIBRARY to a built Rust dynamic library.'
        : false,
  );
}
