part of 'js_core.dart';

void jCloseIteratorRecords(
  Iterable<JIteratorRecord> records, {
  bool suppress = false,
}) {
  Object? failure;
  for (final record in records.toList().reversed) {
    try {
      record.close(suppressErrors: suppress || failure != null);
    } catch (error) {
      failure ??= error;
    }
  }
  if (failure != null) throw failure;
}

JIteratorHelper jIteratorZip(
  dynamic input,
  dynamic options, {
  required bool keyed,
}) {
  jIteratorObject(input);
  if (!identical(options, jUndefined)) jIteratorObject(options);
  final modeValue = identical(options, jUndefined)
      ? jUndefined
      : jGet(options, 'mode');
  final mode = identical(modeValue, jUndefined) ? 'shortest' : modeValue;
  if (mode != 'shortest' && mode != 'longest' && mode != 'strict') {
    throw JThrown(JError('TypeError', 'Invalid zip mode'));
  }
  final paddingOption = mode == 'longest' && !identical(options, jUndefined)
      ? jGet(options, 'padding')
      : jUndefined;
  if (!identical(paddingOption, jUndefined)) jIteratorObject(paddingOption);
  final records = <JIteratorRecord>[];
  final keys = <Object>[];
  final padding = <dynamic>[];
  if (keyed) {
    try {
      for (final key in jOwnKeys(input)) {
        if (!jEnumerable(input, key)) continue;
        final value = jGet(input, key);
        if (identical(value, jUndefined)) continue;
        keys.add(key);
        records.add(jIteratorFlattenable(value));
      }
    } catch (_) {
      jCloseIteratorRecords(records, suppress: true);
      rethrow;
    }
  } else {
    final outer = jGetIterator(input);
    try {
      while (outer.advance()) {
        try {
          records.add(jIteratorFlattenable(outer.current));
        } catch (_) {
          jCloseIteratorRecords(records, suppress: true);
          outer.close(suppressErrors: true);
          rethrow;
        }
      }
    } catch (_) {
      jCloseIteratorRecords(records, suppress: true);
      rethrow;
    }
  }
  try {
    if (mode == 'longest' && !identical(paddingOption, jUndefined)) {
      if (keyed) {
        for (final key in keys) padding.add(jGet(paddingOption, key));
      } else {
        final iterator = jGetIterator(paddingOption);
        for (var i = 0; i < records.length; i++) {
          padding.add(iterator.advance() ? iterator.current : jUndefined);
        }
        iterator.close();
      }
    }
    while (padding.length < records.length) padding.add(jUndefined);
  } catch (_) {
    jCloseIteratorRecords(records, suppress: true);
    rethrow;
  }

  return JIteratorHelper(() {
    if (records.isEmpty || records.every((record) => record.done)) {
      return jIterationResult();
    }
    final values = <dynamic>[];
    for (var i = 0; i < records.length; i++) {
      final record = records[i];
      if (record.done) {
        values.add(padding[i]);
        continue;
      }
      if (record.advance()) {
        values.add(record.current);
        continue;
      }
      if (mode == 'shortest') {
        jCloseIteratorRecords(records);
        return jIterationResult();
      }
      if (mode == 'strict') {
        if (i != 0)
          throw JThrown(JError('TypeError', 'Iterators have unequal lengths'));
        for (var k = 1; k < records.length; k++) {
          final other = records[k];
          bool done;
          try {
            final result = jCall(other.next, [], receiver: other.object);
            if (!jIsObject(result)) {
              throw JThrown(
                JError('TypeError', 'Iterator result must be an object'),
              );
            }
            done = jTruthy(jGet(result, 'done'));
          } catch (_) {
            other.done = true;
            rethrow;
          }
          if (!done) {
            throw JThrown(
              JError('TypeError', 'Iterators have unequal lengths'),
            );
          }
          other.done = true;
        }
        return jIterationResult();
      }
      if (records.every((record) => record.done)) return jIterationResult();
      values.add(padding[i]);
    }
    if (!keyed) return jIterationResult(values, false);
    final result = JObject.root();
    for (var i = 0; i < keys.length; i++) result.store(keys[i], values[i]);
    return jIterationResult(result, false);
  }, (suppress) => jCloseIteratorRecords(records, suppress: suppress));
}
