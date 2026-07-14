import 'package:flutter_test/flutter_test.dart';
import 'package:yurich_connect_windows/src/services/runtime_log_buffer.dart';

void main() {
  test('batches log updates and keeps a bounded history', () async {
    final buffer = RuntimeLogBuffer(
      maxEntries: 3,
      maxPendingEntries: 4,
      flushInterval: const Duration(milliseconds: 10),
    );
    addTearDown(buffer.dispose);

    var notifications = 0;
    buffer.revision.addListener(() => notifications += 1);
    for (var index = 0; index < 6; index += 1) {
      buffer.add('log-$index');
    }

    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(buffer.entries, const ['log-3', 'log-4', 'log-5']);
    expect(notifications, 1);
  });

  test('replace and clear publish one update each', () {
    final buffer = RuntimeLogBuffer(maxEntries: 2);
    addTearDown(buffer.dispose);

    var notifications = 0;
    buffer.revision.addListener(() => notifications += 1);
    buffer.replaceAll(const ['one', 'two', 'three']);
    buffer.clear();

    expect(buffer.entries, isEmpty);
    expect(notifications, 2);
  });
}
