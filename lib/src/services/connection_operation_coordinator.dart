enum ConnectionOperation {
  connect,
  disconnect,
  switchProfile,
  repair,
  importProfiles,
}

class ConnectionOperationCoordinator {
  ConnectionOperation? _activeOperation;

  ConnectionOperation? get activeOperation => _activeOperation;

  bool get isBusy => _activeOperation != null;

  Future<bool> tryRun(
    ConnectionOperation operation,
    Future<void> Function() action,
  ) async {
    if (_activeOperation != null) {
      return false;
    }

    _activeOperation = operation;
    try {
      await action();
      return true;
    } finally {
      _activeOperation = null;
    }
  }
}
