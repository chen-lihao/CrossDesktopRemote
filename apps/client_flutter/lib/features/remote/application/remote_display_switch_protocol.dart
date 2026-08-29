const remoteDisplaySwitchWireVersion = 2;

Map<String, dynamic> remoteDisplaySwitchMessage({
  required String type,
  required int generation,
  String? displayId,
  Map<String, dynamic> payload = const {},
}) {
  return {
    ...payload,
    'type': type,
    'version': remoteDisplaySwitchWireVersion,
    'displayId': ?displayId,
    'generation': generation,
  };
}

bool isSupportedRemoteDisplaySwitchMessage(Map<String, dynamic> message) {
  return message['version'] == remoteDisplaySwitchWireVersion;
}
