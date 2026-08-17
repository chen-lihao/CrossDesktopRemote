class CoreBuildInfo {
  const CoreBuildInfo({
    required this.abiVersion,
    required this.protocolMajorVersion,
    required this.featureFlags,
  });

  final int abiVersion;
  final int protocolMajorVersion;
  final int featureFlags;

  bool supports(int feature) => featureFlags & feature != 0;
}

abstract interface class CoreBridge {
  CoreBuildInfo readBuildInfo();
}

abstract final class CoreFeatures {
  static const narrowCAbi = 1 << 0;
  static const protobufV1 = 1 << 1;
}
