import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/connection_operation_coordinator.dart';

void main() {
  group('ConnectionOperationCoordinator', () {
    test('rejects overlapping connection operations', () async {
      final coordinator = ConnectionOperationCoordinator();
      final release = Completer<void>();

      final first = coordinator.tryRun(ConnectionOperation.connect, () async {
        await release.future;
      });
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.isBusy, isTrue);
      expect(coordinator.activeOperation, ConnectionOperation.connect);
      expect(
        await coordinator.tryRun(ConnectionOperation.disconnect, () async {}),
        isFalse,
      );

      release.complete();
      expect(await first, isTrue);
      expect(coordinator.isBusy, isFalse);
    });

    test('releases the operation after an exception', () async {
      final coordinator = ConnectionOperationCoordinator();

      await expectLater(
        coordinator.tryRun(ConnectionOperation.connect, () async {
          throw StateError('start failed');
        }),
        throwsStateError,
      );

      expect(coordinator.isBusy, isFalse);
      expect(
        await coordinator.tryRun(ConnectionOperation.repair, () async {}),
        isTrue,
      );
    });

    test('keeps a rapid burst from starting duplicate cores', () async {
      final coordinator = ConnectionOperationCoordinator();
      final release = Completer<void>();
      var starts = 0;

      final first = coordinator.tryRun(ConnectionOperation.connect, () async {
        starts += 1;
        await release.future;
      });
      await Future<void>.delayed(Duration.zero);

      final duplicates = await Future.wait(
        List.generate(
          100,
          (_) => coordinator.tryRun(ConnectionOperation.connect, () async {
            starts += 1;
          }),
        ),
      );

      expect(duplicates.where((accepted) => accepted), isEmpty);
      expect(starts, 1);
      release.complete();
      expect(await first, isTrue);
    });
  });
}
