part of 'js_core.dart';

JObject jIterationResult([dynamic value = jUndefined, bool done = true]) =>
    JObject({'value': value, 'done': done});

JFunction jBuiltinMethod(
  String name,
  int length,
  dynamic Function(List<dynamic>, dynamic) invoke,
) => jNamedFunction(JFunction(invoke, constructible: false), name, length);

dynamic jIteratorObject(dynamic value) {
  if (!jIsObject(value)) {
    throw JThrown(JError('TypeError', 'Iterator receiver must be an object'));
  }
  return value;
}

void jIteratorCallback(dynamic callback) {
  if (callback is! JFunction) {
    throw JThrown(JError('TypeError', 'Iterator callback must be callable'));
  }
}

JIteratorRecord jIteratorFlattenable(
  dynamic value, {
  bool allowString = false,
}) {
  if (!(allowString && value is String)) jIteratorObject(value);
  final method = jGet(value, jSymbols['iterator']);
  return JIteratorRecord(
    jIteratorObject(
      jNullish(method) ? value : jCall(method, [], receiver: value),
    ),
  );
}

JObject get jIteratorHelperPrototype => JRealm.current.iteratorHelperPrototype;
JObject _buildRealmIteratorHelperPrototype() => JObject()
  ..prototype = jIteratorPrototype
  ..symbols[jSymbols['toStringTag']!] = 'Iterator Helper'
  ..properties['next'] = jBuiltinMethod('next', 0, (_, receiver) {
    if (receiver is! JIteratorHelper) {
      throw JThrown(JError('TypeError', 'Expected iterator helper'));
    }
    return receiver.next();
  })
  ..properties['return'] = jBuiltinMethod('return', 0, (_, receiver) {
    if (receiver is! JIteratorHelper) {
      throw JThrown(JError('TypeError', 'Expected iterator helper'));
    }
    return receiver.finish();
  });

class JIteratorHelper extends JObject {
  final JObject Function() step;
  final void Function(bool) close;
  bool completed = false;
  bool running = false;
  bool started = false;

  JIteratorHelper(this.step, this.close) {
    prototype = jIteratorHelperPrototype;
  }

  void checkRunning() {
    if (running) {
      throw JThrown(JError('TypeError', 'Iterator helper is executing'));
    }
  }

  JObject next() {
    checkRunning();
    if (completed) return jIterationResult();
    running = true;
    started = true;
    try {
      final result = step();
      completed = jTruthy(jGet(result, 'done'));
      return result;
    } catch (_) {
      completed = true;
      close(true);
      rethrow;
    } finally {
      running = false;
    }
  }

  JObject finish() {
    checkRunning();
    if (!completed) {
      completed = true;
      running = started;
      try {
        close(false);
      } finally {
        running = false;
      }
    }
    return jIterationResult();
  }
}

JIteratorHelper jLazyIterator(String name, dynamic receiver, dynamic argument) {
  jIteratorObject(receiver);
  final limited = name == 'take' || name == 'drop';
  num remaining = 0;
  if (limited) {
    try {
      final limit = jNumber(argument);
      if (limit.isNaN ||
          limit <= -1 ||
          (limit.isFinite && limit > 9007199254740991)) {
        throw JThrown(JError('RangeError', 'Invalid iterator limit'));
      }
      remaining = limit.isInfinite ? limit : limit.truncateToDouble();
    } catch (_) {
      JIteratorRecord.direct(receiver, jUndefined).close(suppressErrors: true);
      rethrow;
    }
  } else {
    try {
      jIteratorCallback(argument);
    } catch (_) {
      JIteratorRecord.direct(receiver, jUndefined).close(suppressErrors: true);
      rethrow;
    }
  }
  final source = JIteratorRecord(receiver);
  JIteratorRecord? inner;
  var index = 0;
  return JIteratorHelper(
    () {
      if (name == 'take') {
        if (remaining == 0) {
          source.close();
          return jIterationResult();
        }
        remaining--;
      }
      if (name == 'drop') {
        while (remaining > 0) {
          if (!source.advance()) return jIterationResult();
          remaining--;
        }
      }
      while (true) {
        if (inner != null) {
          if (inner!.advance()) return jIterationResult(inner!.current, false);
          inner = null;
        }
        if (!source.advance()) return jIterationResult();
        final value = source.current;
        switch (name) {
          case 'map':
            return jIterationResult(jCall(argument, [value, index++]), false);
          case 'filter':
            if (jTruthy(jCall(argument, [value, index++]))) {
              return jIterationResult(value, false);
            }
          case 'flatMap':
            inner = jIteratorFlattenable(jCall(argument, [value, index++]));
          default:
            return jIterationResult(value, false);
        }
      }
    },
    (suppress) {
      try {
        inner?.close(suppressErrors: suppress);
      } catch (_) {
        source.close(suppressErrors: true);
        rethrow;
      }
      source.close(suppressErrors: suppress);
    },
  );
}

JIteratorHelper jGroupIterator(
  dynamic receiver,
  dynamic size, {
  required bool sliding,
  required dynamic partial,
}) {
  jIteratorObject(receiver);
  if (identical(partial, jUndefined)) partial = 'only-full';
  try {
    if (size is! num || !size.isFinite || size != size.truncateToDouble()) {
      throw JThrown(
        JError('TypeError', 'Iterator group size must be an integer'),
      );
    }
    if (size < 1 || size > 0xffffffff) {
      throw JThrown(
        JError('RangeError', 'Iterator group size is out of bounds'),
      );
    }
    if (partial != 'only-full' && partial != 'allow-partial') {
      throw JThrown(JError('TypeError', 'Invalid partial window option'));
    }
  } catch (_) {
    JIteratorRecord.direct(receiver, jUndefined).close(suppressErrors: true);
    rethrow;
  }
  final source = JIteratorRecord(receiver);
  final buffer = Queue<dynamic>();
  return JIteratorHelper(() {
    while (source.advance()) {
      if (sliding && buffer.length == size) buffer.removeFirst();
      buffer.addLast(source.current);
      if (buffer.length == size) {
        final group = buffer.toList();
        if (!sliding) buffer.clear();
        return jIterationResult(group, false);
      }
    }
    if (buffer.isNotEmpty &&
        buffer.length < size &&
        (!sliding || partial == 'allow-partial')) {
      final group = buffer.toList();
      buffer.clear();
      return jIterationResult(group, false);
    }
    return jIterationResult();
  }, (suppress) => source.close(suppressErrors: suppress));
}

dynamic jConsumeIterator(String name, dynamic receiver, List<dynamic> args) {
  jIteratorObject(receiver);
  final callback = jArg(args, 0);
  if (name != 'toArray') {
    try {
      jIteratorCallback(callback);
    } catch (_) {
      JIteratorRecord.direct(receiver, jUndefined).close(suppressErrors: true);
      rethrow;
    }
  }
  final source = JIteratorRecord(receiver);
  final array = <dynamic>[];
  var index = 0.0;
  dynamic result = jArg(args, 1);
  try {
    if (name == 'reduce' && args.length < 2) {
      if (!source.advance()) {
        throw JThrown(JError('TypeError', 'Reduce of empty iterator'));
      }
      result = source.current;
      index++;
    }
    while (source.advance()) {
      final value = source.current;
      if (name == 'toArray') {
        array.add(value);
      } else if (name == 'reduce') {
        result = jCall(callback, [result, value, index++]);
      } else {
        final selected = jTruthy(jCall(callback, [value, index++]));
        if ((name == 'every' && !selected) ||
            ((name == 'some' || name == 'find') && selected)) {
          source.close();
          return name == 'find' ? value : selected;
        }
      }
    }
  } catch (_) {
    source.close(suppressErrors: true);
    rethrow;
  }
  return switch (name) {
    'toArray' => array,
    'reduce' => result,
    'some' => false,
    'every' => true,
    _ => jUndefined,
  };
}

dynamic jIteratorIncludes(dynamic receiver, List<dynamic> args) {
  jIteratorObject(receiver);
  var count = jArg(args, 1);
  if (identical(count, jUndefined)) count = 0;
  try {
    if (count is! num ||
        count.isNaN ||
        (count.isFinite && count != count.truncateToDouble())) {
      throw JThrown(JError('TypeError', 'Invalid number of skipped elements'));
    }
    if (count < 0 || (count.isFinite && count > 9007199254740991)) {
      throw JThrown(JError('RangeError', 'Invalid number of skipped elements'));
    }
  } catch (_) {
    JIteratorRecord.direct(receiver, jUndefined).close(suppressErrors: true);
    rethrow;
  }
  final source = JIteratorRecord(receiver);
  var skipped = 0.0;
  while (source.advance()) {
    if (skipped < count) {
      skipped++;
    } else if (jSameValue(source.current, jArg(args, 0), zero: true)) {
      source.close();
      return true;
    }
  }
  return false;
}

String jIteratorJoin(dynamic receiver, dynamic separator) {
  jIteratorObject(receiver);
  late final String delimiter;
  try {
    delimiter = identical(separator, jUndefined) ? ',' : jString(separator);
  } catch (_) {
    JIteratorRecord.direct(receiver, jUndefined).close(suppressErrors: true);
    rethrow;
  }
  final source = JIteratorRecord(receiver);
  final result = StringBuffer();
  var first = true;
  try {
    while (source.advance()) {
      if (!first) result.write(delimiter);
      first = false;
      if (!jNullish(source.current)) result.write(jString(source.current));
    }
  } catch (_) {
    source.close(suppressErrors: true);
    rethrow;
  }
  return result.toString();
}

JObject jIteratorFrom(dynamic value) {
  final record = jIteratorFlattenable(value, allowString: true);
  for (
    dynamic prototype = jPrototype(record.object);
    prototype != null;
    prototype = jPrototype(prototype)
  ) {
    if (identical(prototype, jIteratorPrototype)) return record.object;
  }
  return JObject({
    'next': jBuiltinMethod(
      'next',
      0,
      (_, __) => jCall(record.next, [], receiver: record.object),
    ),
    'return': jBuiltinMethod('return', 0, (_, __) {
      final method = jGet(record.object, 'return');
      return jNullish(method)
          ? jIterationResult()
          : jCall(method, [], receiver: record.object);
    }),
  })..prototype = jIteratorPrototype;
}

JIteratorHelper jIteratorConcat(List<dynamic> args) {
  final inputs = <(dynamic, dynamic)>[];
  for (final input in args) {
    jIteratorObject(input);
    final method = jGet(input, jSymbols['iterator']);
    jIteratorCallback(method);
    inputs.add((input, method));
  }
  var index = 0;
  JIteratorRecord? active;
  return JIteratorHelper(() {
    while (index < inputs.length || active != null) {
      if (active == null) {
        final (input, method) = inputs[index++];
        active = JIteratorRecord(
          jIteratorObject(jCall(method, [], receiver: input)),
        );
      }
      if (active!.advance()) return jIterationResult(active!.current, false);
      active = null;
    }
    return jIterationResult();
  }, (suppress) => active?.close(suppressErrors: suppress));
}

JFunction get jIteratorConstructor => JRealm.current.iteratorConstructor;
JFunction _buildRealmIteratorConstructor() => jNamedFunction(
  JFunction(
    (_, __) => throw JThrown(JError('TypeError', 'Iterator requires new')),
    constructWithTarget: (_, target) {
      if (identical(target, jIteratorConstructor)) {
        throw JThrown(JError('TypeError', 'Iterator is abstract'));
      }
      return JObject()
        ..prototype = jPrototypeFromConstructor(target, jIteratorPrototype);
    },
  ),
  'Iterator',
  0,
);

JObject get jIteratorPrototype => JRealm.current.iteratorPrototype;

JObject _jBuildIteratorPrototype() {
  final prototype = JObject({
    for (final name in ['map', 'filter', 'take', 'drop', 'flatMap'])
      name: jBuiltinMethod(
        name,
        1,
        (args, receiver) => jLazyIterator(name, receiver, jArg(args, 0)),
      ),
    'includes': jBuiltinMethod(
      'includes',
      1,
      (args, receiver) => jIteratorIncludes(receiver, args),
    ),
    'join': jBuiltinMethod(
      'join',
      1,
      (args, receiver) => jIteratorJoin(receiver, jArg(args, 0)),
    ),
    'chunks': jBuiltinMethod(
      'chunks',
      1,
      (args, receiver) => jGroupIterator(
        receiver,
        jArg(args, 0),
        sliding: false,
        partial: jUndefined,
      ),
    ),
    'windows': jBuiltinMethod(
      'windows',
      1,
      (args, receiver) => jGroupIterator(
        receiver,
        jArg(args, 0),
        sliding: true,
        partial: jArg(args, 1),
      ),
    ),
    for (final name in [
      'reduce',
      'toArray',
      'forEach',
      'some',
      'every',
      'find',
    ])
      name: jBuiltinMethod(
        name,
        name == 'toArray' ? 0 : 1,
        (args, receiver) => jConsumeIterator(name, receiver, args),
      ),
  });
  prototype.symbols.addAll({
    jSymbols['iterator']!: jBuiltinMethod(
      '[Symbol.iterator]',
      0,
      (_, receiver) => receiver,
    ),
    jSymbols['dispose']!: jBuiltinMethod('[Symbol.dispose]', 0, (_, receiver) {
      final method = jGet(jRequireCoercible(receiver), 'return');
      if (!jNullish(method)) jCall(method, [], receiver: receiver);
      return jUndefined;
    }),
  });
  for (final (key, name, get) in <(Object, String, dynamic Function())>[
    ('constructor', 'constructor', () => jIteratorConstructor),
    (jSymbols['toStringTag']!, '[Symbol.toStringTag]', () => 'Iterator'),
  ]) {
    jDefineProperty(
      prototype,
      key,
      JObject({
        'get': jBuiltinMethod('get $name', 0, (_, __) => get()),
        'set': jBuiltinMethod('set $name', 1, (args, receiver) {
          if (!jIsObject(receiver) || identical(receiver, prototype)) {
            throw JThrown(
              JError('TypeError', 'Invalid Iterator prototype setter receiver'),
            );
          }
          if (jHasOwn(receiver, key)) {
            jSet(receiver, key, jArg(args, 0));
          } else if (!jDefineProperty(
            receiver,
            key,
            JObject({
              'value': jArg(args, 0),
              'enumerable': true,
              'configurable': true,
              'writable': true,
            }),
          )) {
            throw JThrown(JError('TypeError', 'Cannot set Iterator property'));
          }
          return jUndefined;
        }),
        'configurable': true,
      }),
    );
  }
  jBuiltinProperties(prototype);
  return prototype;
}

void installJSIterators(JScope scope) {
  jIteratorConstructor.properties.addAll({
    'prototype': jIteratorPrototype,
    'from': jBuiltinMethod(
      'from',
      1,
      (args, _) => jIteratorFrom(jArg(args, 0)),
    ),
    'concat': jBuiltinMethod('concat', 0, (args, _) => jIteratorConcat(args)),
    'zip': jBuiltinMethod(
      'zip',
      1,
      (args, _) => jIteratorZip(jArg(args, 0), jArg(args, 1), keyed: false),
    ),
    'zipKeyed': jBuiltinMethod(
      'zipKeyed',
      1,
      (args, _) => jIteratorZip(jArg(args, 0), jArg(args, 1), keyed: true),
    ),
  });
  jBuiltinProperties(jIteratorConstructor);
  jIteratorConstructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  jBuiltinProperties(jIteratorHelperPrototype);
  scope.define('Iterator', jIteratorConstructor);
}
