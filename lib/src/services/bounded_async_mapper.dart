class BoundedAsyncMapper {
  const BoundedAsyncMapper._();

  static Future<Map<K, R>> run<T, K, R>({
    required List<T> items,
    required K Function(T item) keyOf,
    required Future<R> Function(T item) task,
    required int maxConcurrency,
    bool Function()? isCancelled,
  }) async {
    if (items.isEmpty) {
      return <K, R>{};
    }
    if (maxConcurrency < 1) {
      throw ArgumentError.value(
        maxConcurrency,
        'maxConcurrency',
        'must be at least 1',
      );
    }

    final results = <K, R>{};
    var nextIndex = 0;
    final workerCount = items.length < maxConcurrency
        ? items.length
        : maxConcurrency;

    Future<void> worker() async {
      while (nextIndex < items.length && !(isCancelled?.call() ?? false)) {
        final item = items[nextIndex];
        nextIndex += 1;
        final result = await task(item);
        if (isCancelled?.call() ?? false) {
          return;
        }
        results[keyOf(item)] = result;
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    return results;
  }
}
