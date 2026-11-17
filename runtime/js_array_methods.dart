part of 'js_core.dart';

final jArrayMethods = jBuildArrayMethods();
final _arrayExtras = Expando<JObject>();

JObject? jArrayExtras(List<dynamic> array, {bool create = false}) {
  if (array is JArray) return array.extra;
  final existing = _arrayExtras[array];
  if (existing != null || !create) return existing;
  return _arrayExtras[array] = JObject();
}

Map<String, JFunction> jBuildArrayMethods() {
  final methods = <String, JFunction>{};
  void add(
    String name,
    int arity,
    dynamic Function(dynamic, List<dynamic>) run,
  ) {
    methods[name] = jNamedFunction(
      JFunction(
        (args, receiver) => run(jObject(jRequireCoercible(receiver)), args),
        constructible: false,
      ),
      name,
      arity,
    );
  }

  int length(dynamic object) => jLength(jGet(object, 'length'));
  int end(List<dynamic> args, int position, int size) =>
      identical(jArg(args, position), jUndefined)
      ? size
      : jRelativeIndex(args[position], size);
  JFunction callback(List<dynamic> args) {
    final fn = jArg(args, 0);
    if (fn is! JFunction)
      throw JThrown(JError('TypeError', 'Callback is not callable'));
    return fn;
  }

  void move(dynamic object, int from, int to) {
    if (jHasProperty(object, '$from')) {
      jSet(object, to, jGet(object, from));
    } else {
      jDelete(object, to, strict: true);
    }
  }

  add('at', 1, (object, args) {
    final size = length(object);
    final offset = jInteger(jArg(args, 0));
    final index = offset < 0 ? size + offset : offset;
    return index < 0 || index >= size
        ? jUndefined
        : jGet(object, index.toInt());
  });
  add('concat', 1, (object, args) {
    final result = <dynamic>[];
    for (final item in [object, ...args]) {
      final spreadable = jIsObject(item)
          ? jGet(item, jSymbols['isConcatSpreadable'])
          : jUndefined;
      if (!(identical(spreadable, jUndefined)
          ? jIsArray(item)
          : jTruthy(spreadable))) {
        result.add(item);
        continue;
      }
      final size = length(item);
      for (var i = 0; i < size; i++) {
        result.add(jHasProperty(item, '$i') ? jGet(item, i) : _jHole);
      }
    }
    return result;
  });
  add('copyWithin', 2, (object, args) {
    final size = length(object);
    final to = jRelativeIndex(jArg(args, 0), size);
    final from = jRelativeIndex(jArg(args, 1), size);
    final count = math.min(end(args, 2, size) - from, size - to);
    if (from < to && to < from + count) {
      for (var i = count - 1; i >= 0; i--) {
        move(object, from + i, to + i);
      }
    } else {
      for (var i = 0; i < count; i++) {
        move(object, from + i, to + i);
      }
    }
    return object;
  });
  add('fill', 1, (object, args) {
    final size = length(object);
    final start = jRelativeIndex(jArg(args, 1), size);
    final stop = end(args, 2, size);
    for (var i = start; i < stop; i++) {
      jSet(object, i, jArg(args, 0));
    }
    return object;
  });
  for (final method in ['find', 'findIndex', 'findLast', 'findLastIndex']) {
    add(method, 1, (object, args) {
      final size = length(object);
      final fn = callback(args);
      final reverse = method.startsWith('findLast');
      final indexResult = method.endsWith('Index');
      for (var i = 0; i < size; i++) {
        final index = reverse ? size - i - 1 : i;
        final value = jGet(object, index);
        if (jTruthy(
          jCall(fn, [value, index.toDouble(), object], receiver: jArg(args, 1)),
        )) {
          return indexResult ? index.toDouble() : value;
        }
      }
      return indexResult ? -1.0 : jUndefined;
    });
  }
  for (final method in ['flat', 'flatMap']) {
    add(method, method == 'flat' ? 0 : 1, (object, args) {
      final size = length(object);
      final mapper = method == 'flatMap' ? callback(args) : null;
      final depth = mapper != null || identical(jArg(args, 0), jUndefined)
          ? 1.0
          : math.max(0.0, jInteger(args[0]));
      final result = <dynamic>[];
      void append(
        dynamic source,
        int count,
        double remaining, {
        JFunction? map,
      }) {
        for (var i = 0; i < count; i++) {
          if (!jHasProperty(source, '$i')) continue;
          final item = jGet(source, i);
          final value = map == null
              ? item
              : jCall(map, [
                  item,
                  i.toDouble(),
                  source,
                ], receiver: jArg(args, 1));
          if (remaining > 0 && jIsArray(value)) {
            append(value, length(value), remaining - 1);
          } else {
            result.add(value);
          }
        }
      }

      try {
        append(object, size, depth, map: mapper);
      } on StackOverflowError {
        throw JThrown(
          JError('RangeError', 'Array flattening exceeded the stack limit'),
        );
      }
      return result;
    });
  }
  add('lastIndexOf', 1, (object, args) {
    final size = length(object);
    if (size == 0) return -1.0;
    final offset = args.length < 2 ? (size - 1).toDouble() : jInteger(args[1]);
    final start = offset < 0 ? size + offset : math.min(offset, size - 1);
    if (start < 0) return -1.0;
    for (var i = start.toInt(); i >= 0; i--) {
      if (jHasProperty(object, '$i') &&
          jStrictEqual(jGet(object, i), jArg(args, 0)))
        return i.toDouble();
    }
    return -1.0;
  });
  for (final reverse in [false, true]) {
    add(reverse ? 'reduceRight' : 'reduce', 1, (object, args) {
      final size = length(object);
      final fn = callback(args);
      var initialized = args.length > 1;
      var accumulator = jArg(args, 1);
      for (var i = 0; i < size; i++) {
        final index = reverse ? size - i - 1 : i;
        if (!jHasProperty(object, '$index')) continue;
        final item = jGet(object, index);
        accumulator = initialized
            ? jCall(fn, [accumulator, item, index.toDouble(), object])
            : item;
        initialized = true;
      }
      if (!initialized) throw JThrown(JError('TypeError', 'Empty reduction'));
      return accumulator;
    });
  }
  add('reverse', 0, (object, args) {
    final size = length(object);
    for (var lo = 0; lo < size ~/ 2; lo++) {
      final hi = size - lo - 1;
      final lowPresent = jHasProperty(object, '$lo');
      final low = lowPresent ? jGet(object, lo) : jUndefined;
      final highPresent = jHasProperty(object, '$hi');
      final high = highPresent ? jGet(object, hi) : jUndefined;
      if (highPresent) jSet(object, lo, high);
      if (lowPresent) {
        if (!highPresent) jDelete(object, lo, strict: true);
        jSet(object, hi, low);
      } else if (highPresent) {
        jDelete(object, hi, strict: true);
      }
    }
    return object;
  });
  add('shift', 0, (object, args) {
    final size = length(object);
    if (size == 0) {
      jSet(object, 'length', 0.0);
      return jUndefined;
    }
    final result = jGet(object, 0);
    for (var i = 1; i < size; i++) {
      move(object, i, i - 1);
    }
    jDelete(object, size - 1, strict: true);
    jSet(object, 'length', (size - 1).toDouble());
    return result;
  });
  add('unshift', 1, (object, args) {
    final size = length(object);
    if (size + args.length > 9007199254740991) {
      throw JThrown(JError('TypeError', 'Array length out of range'));
    }
    if (args.isNotEmpty) {
      for (var i = size - 1; i >= 0; i--) {
        move(object, i, i + args.length);
      }
      for (var i = 0; i < args.length; i++) {
        jSet(object, i, args[i]);
      }
    }
    return jSet(object, 'length', (size + args.length).toDouble());
  });
  for (final copy in [false, true]) {
    add(copy ? 'toSpliced' : 'splice', 2, (object, args) {
      final size = length(object);
      final start = jRelativeIndex(jArg(args, 0), size);
      final removed = args.length < 2
          ? (args.isEmpty ? 0 : size - start)
          : jInteger(args[1]).clamp(0, size - start).toInt();
      final inserted = math.max(0, args.length - 2);
      final nextSize = size - removed + inserted;
      if (nextSize > 9007199254740991) {
        throw JThrown(JError('TypeError', 'Array length out of range'));
      }
      if (copy) {
        return <dynamic>[
          for (var i = 0; i < start; i++) jGet(object, i),
          ...args.skip(2),
          for (var i = start + removed; i < size; i++) jGet(object, i),
        ];
      }
      final result = <dynamic>[
        for (var i = start; i < start + removed; i++)
          jHasProperty(object, '$i') ? jGet(object, i) : _jHole,
      ];
      if (inserted < removed) {
        for (var i = start; i < size - removed; i++) {
          move(object, i + removed, i + inserted);
        }
        for (var i = size - 1; i >= nextSize; i--) {
          jDelete(object, i, strict: true);
        }
      } else if (inserted > removed) {
        for (var i = size - removed - 1; i >= start; i--) {
          move(object, i + removed, i + inserted);
        }
      }
      for (var i = 0; i < inserted; i++) {
        jSet(object, start + i, args[i + 2]);
      }
      jSet(object, 'length', nextSize.toDouble());
      return result;
    });
  }
  add('toReversed', 0, (object, args) {
    final size = length(object);
    return <dynamic>[for (var i = size - 1; i >= 0; i--) jGet(object, i)];
  });
  add('toSorted', 1, (object, args) {
    final comparator = jArg(args, 0);
    if (!identical(comparator, jUndefined) && comparator is! JFunction) {
      throw JThrown(JError('TypeError', 'Comparator is not callable'));
    }
    final size = length(object);
    final values = <dynamic>[for (var i = 0; i < size; i++) jGet(object, i)];
    return jInvoke(values, 'sort', [comparator]);
  });
  add('with', 2, (object, args) {
    final size = length(object);
    final relative = jInteger(jArg(args, 0));
    final target = relative < 0 ? size + relative : relative;
    if (target < 0 || target >= size)
      throw JThrown(JError('RangeError', 'Invalid array index'));
    return <dynamic>[
      for (var i = 0; i < size; i++)
        i == target ? jArg(args, 1) : jGet(object, i),
    ];
  });
  add('toLocaleString', 0, (object, args) {
    final size = length(object);
    return [
      for (var i = 0; i < size; i++) jLocaleElement(jGet(object, i), args),
    ].join(',');
  });
  return methods;
}

String jLocaleElement(dynamic value, List<dynamic> args) =>
    jNullish(value) ? '' : jString(jInvoke(value, 'toLocaleString', args));

JPromise jArrayFromAsync(List<dynamic> args, dynamic receiver) => jAsync((
  promise,
) async {
  JAsyncIteratorRecord? iterator;
  try {
    final input = jArg(args, 0);
    final callback = jArg(args, 1);
    if (!identical(callback, jUndefined) && callback is! JFunction) {
      throw JThrown(
        JError('TypeError', 'Array.fromAsync mapper is not callable'),
      );
    }
    final asyncMethod = jGet(input, jSymbols['asyncIterator']);
    final syncMethod = jNullish(asyncMethod)
        ? jGet(input, jSymbols['iterator'])
        : jUndefined;
    final method = jNullish(asyncMethod) ? syncMethod : asyncMethod;
    final isIterable = !jNullish(method);
    final size = isIterable ? 0 : jLength(jGet(input, 'length'));
    if (isIterable) {
      final object = jCall(method, [], receiver: input);
      if (!jIsObject(object))
        throw JThrown(JError('TypeError', 'Iterator must be an object'));
      iterator = JAsyncIteratorRecord(object, jNullish(asyncMethod));
    }
    final target = receiver is JFunction && receiver.constructible
        ? jNew(receiver, isIterable ? [] : [size.toDouble()])
        : <dynamic>[];
    var index = 0;
    while (iterator == null
        ? index < size
        : (await jAwait(iterator.advance())) == true) {
      dynamic value = iterator == null
          ? await jAwait(jGet(input, index))
          : iterator.current;
      if (callback is JFunction) {
        value = await jAwait(
          jCall(callback, [value, index.toDouble()], receiver: jArg(args, 2)),
        );
      }
      if (target is JObject) {
        final ok = jDefineProperty(
          target,
          '$index',
          JObject({
            'value': value,
            'writable': true,
            'enumerable': true,
            'configurable': true,
          }),
          normalized: true,
        );
        if (!ok)
          throw JThrown(JError('TypeError', 'Cannot create array element'));
      } else {
        jSet(target, index, value);
      }
      index++;
    }
    jSet(target, 'length', index.toDouble());
    promise.resolve(target);
  } catch (error) {
    if (iterator != null) await jAwait(iterator.close(suppressErrors: true));
    promise.reject(jExceptionValue(error));
  }
});
