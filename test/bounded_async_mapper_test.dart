import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/bounded_async_mapper.dart';

void main() {
  group('BoundedAsyncMapper', () {
    test('never exceeds configured concurrency', () async {
      var active = 0;
      var peak = 0;

      final results = await BoundedAsyncMapper.run<int, int, int>(
        items: List.generate(20, (index) => index),
        keyOf: (item) => item,
        maxConcurrency: 4,
        task: (item) async {
          active += 1;
          if (active > peak) {
            peak = active;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
          active -= 1;
          return item * 2;
        },
      );

      expect(peak, 4);
      expect(results.length, 20);
      expect(results[19], 38);
    });

    test(
      'stops scheduling and discards late results after cancellation',
      () async {
        var cancelled = false;
        var started = 0;
        final firstWave = Completer<void>();

        final future = BoundedAsyncMapper.run<int, int, int>(
          items: List.generate(12, (index) => index),
          keyOf: (item) => item,
          maxConcurrency: 3,
          isCancelled: () => cancelled,
          task: (item) async {
            started += 1;
            await firstWave.future;
            return item;
          },
        );

        await Future<void>.delayed(Duration.zero);
        expect(started, 3);
        cancelled = true;
        firstWave.complete();

        expect(await future, isEmpty);
        expect(started, 3);
      },
    );

    test('rejects invalid concurrency', () async {
      expect(
        () => BoundedAsyncMapper.run<int, int, int>(
          items: const [1],
          keyOf: (item) => item,
          task: (item) async => item,
          maxConcurrency: 0,
        ),
        throwsArgumentError,
      );
    });

    test('handles a large profile batch without unbounded workers', () async {
      var active = 0;
      var peak = 0;

      final results = await BoundedAsyncMapper.run<int, int, int>(
        items: List.generate(250, (index) => index),
        keyOf: (item) => item,
        maxConcurrency: 4,
        task: (item) async {
          active += 1;
          peak = active > peak ? active : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          active -= 1;
          return item;
        },
      );

      expect(peak, 4);
      expect(results.length, 250);
    });
  });
}
