enum RemoteInputResetScope { keyboard, pointer, all }

extension RemoteInputResetScopeWireValue on RemoteInputResetScope {
  String get wireValue => name;
}

RemoteInputResetScope? parseRemoteInputResetScope(Object? value) {
  return switch (value) {
    'keyboard' => RemoteInputResetScope.keyboard,
    'pointer' => RemoteInputResetScope.pointer,
    'all' => RemoteInputResetScope.all,
    _ => null,
  };
}
