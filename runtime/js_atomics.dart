part of 'js_core.dart';

final jSharedArrayBufferPrototype = JObject();

class JSharedArrayBuffer extends JArrayBuffer {
  final waiters = <int, Queue<JAtomicWaiter>>{};

  JSharedArrayBuffer(super.length, {super.maximum}) {
    prototype = jSharedArrayBufferPrototype;
  }
}

class JAtomicWaiter {
  final promise = JPromise();
  Timer? timer;
}

// Atomics operate synchronously on the Flutter isolate. Only calls to JavaScript
// conversions can run user code, so revalidate the view after those calls.
class JAtomicAccess {
  final JTypedArray array;
  final int index;

  JAtomicAccess(this.array, this.index);

  factory JAtomicAccess.from(
    List<dynamic> args, {
    bool waitable = false,
    bool requireShared = false,
  }) {
    final array = jArg(args, 0);
    if (array is! JTypedArray ||
        (waitable
            ? array.kind != 'Int32Array' && array.kind != 'BigInt64Array'
            : array.kind.startsWith('Float') ||
                  array.kind == 'Uint8ClampedArray')) {
      throw JThrown(JError('TypeError', 'Invalid typed array for Atomics'));
    }
    array.check();
    if (requireShared && array.buffer is! JSharedArrayBuffer) {
      throw JThrown(JError('TypeError', 'A shared buffer is required'));
    }
    final length = array.length;
    final index = jIndex(jArg(args, 1));
    if (index >= length) {
      throw JThrown(JError('RangeError', 'Atomic index is out of bounds'));
    }
    return JAtomicAccess(array, index);
  }

  int get offset => array.offset + index * array.size;

  void revalidate() {
    array.check();
    if (index >= array.length) {
      throw JThrown(JError('RangeError', 'Atomic index is out of bounds'));
    }
  }

  dynamic coerce(dynamic value) =>
      array.kind.startsWith('Big') ? jBigInt(value) : jInteger(value);

  // Wrap to the view's actual signedness and bit width before RMW arithmetic.
  dynamic wrap(dynamic value) {
    final bits = array.size * 8;
    final signed =
        !array.kind.startsWith('Uint') && array.kind != 'BigUint64Array';
    if (value is BigInt) {
      return signed ? value.toSigned(bits) : value.toUnsigned(bits);
    }
    final integer = jUint32(value);
    return (signed ? integer.toSigned(bits) : integer.toUnsigned(bits))
        .toDouble();
  }

  dynamic read() => jReadElement(array.buffer, offset, array.kind, Endian.host);

  void write(dynamic value) =>
      jWriteElement(array.buffer, offset, array.kind, value, Endian.host);
}

dynamic jAtomicsWait(List<dynamic> args, {required bool asynchronous}) {
  final access = JAtomicAccess.from(args, waitable: true, requireShared: true);
  final buffer = access.array.buffer as JSharedArrayBuffer;
  final expected = access.wrap(access.coerce(jArg(args, 2)));
  final timeout = jNumber(jArg(args, 3));
  if (!asynchronous) {
    throw JThrown(JError('TypeError', 'The Flutter UI agent cannot block'));
  }
  access.revalidate();
  if (!jStrictEqual(access.read(), expected)) {
    return JObject({'async': false, 'value': 'not-equal'});
  }
  if (timeout <= 0) return JObject({'async': false, 'value': 'timed-out'});

  final offset = access.offset;
  final queue = buffer.waiters.putIfAbsent(
    offset,
    () => Queue<JAtomicWaiter>(),
  );
  final waiter = JAtomicWaiter();
  queue.addLast(waiter);
  if (timeout.isFinite) {
    final micros = (timeout * 1000).clamp(1, 9007199254740991).ceil();
    waiter.timer = Timer(Duration(microseconds: micros), () {
      queue.remove(waiter);
      if (queue.isEmpty) buffer.waiters.remove(offset);
      waiter.promise.resolve('timed-out');
    });
  }
  return JObject({'async': true, 'value': waiter.promise});
}

void installJSAtomics(JScope scope) {
  JSharedArrayBuffer shared(dynamic receiver) {
    if (receiver is! JSharedArrayBuffer) {
      throw JThrown(JError('TypeError', 'SharedArrayBuffer required'));
    }
    return receiver;
  }

  final constructor = JFunction(
    (args, receiver) =>
        throw JThrown(JError('TypeError', 'SharedArrayBuffer requires new')),
    constructWithTarget: jBuiltinAllocator(jSharedArrayBufferPrototype, (args) {
      final length = jBufferSize(jArg(args, 0));
      final options = jArg(args, 1);
      final maximum = jIsObject(options)
          ? jGet(options, 'maxByteLength')
          : jUndefined;
      final maxLength = identical(maximum, jUndefined)
          ? null
          : jBufferSize(maximum);
      if (maxLength != null && maxLength < length) {
        throw JThrown(JError('RangeError', 'Length exceeds maxByteLength'));
      }
      return JSharedArrayBuffer(length, maximum: maxLength);
    }),
  );
  constructor.properties['prototype'] = jSharedArrayBufferPrototype;
  jBuiltinProperties(constructor);
  constructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  jNameFunction(constructor, 'SharedArrayBuffer', 1);
  jInstallSpeciesGetter(constructor);

  final proto = jSharedArrayBufferPrototype;
  proto.properties['constructor'] = constructor;
  jAccessor(
    proto,
    'byteLength',
    (receiver) => shared(receiver).bytes.length.toDouble(),
  );
  jAccessor(
    proto,
    'maxByteLength',
    (receiver) => shared(receiver).maximum.toDouble(),
  );
  jAccessor(proto, 'growable', (receiver) => shared(receiver).resizable);
  proto.properties['grow'] = jNamedFunction(
    JFunction((args, receiver) {
      final buffer = shared(receiver);
      if (!buffer.resizable) {
        throw JThrown(JError('TypeError', 'SharedArrayBuffer is not growable'));
      }
      final length = jIndex(jArg(args, 0));
      if (length < buffer.bytes.length || length > buffer.maximum) {
        throw JThrown(JError('RangeError', 'Invalid shared buffer size'));
      }
      if (length != buffer.bytes.length) {
        final old = buffer.bytes;
        buffer.bytes = Uint8List(length)..setRange(0, old.length, old);
      }
      return jUndefined;
    }, constructible: false),
    'grow',
    1,
  );
  proto.properties['slice'] = jNamedFunction(
    JFunction(
      (args, receiver) =>
          jBufferSpeciesSlice(shared(receiver), args, constructor),
      constructible: false,
    ),
    'slice',
    2,
  );
  proto.symbols[jSymbols['toStringTag']!] = 'SharedArrayBuffer';
  jBuiltinProperties(proto);
  proto.flags[jSymbols['toStringTag']!]!.writable = false;
  scope.define('SharedArrayBuffer', constructor);

  final atomics = JObject();
  void method(String name, int length, dynamic Function(List<dynamic>) invoke) {
    atomics.properties[name] = jNamedFunction(jBuiltin(invoke), name, length);
  }

  method('load', 2, (args) {
    final access = JAtomicAccess.from(args)..revalidate();
    return access.read();
  });
  method('store', 3, (args) {
    final access = JAtomicAccess.from(args);
    final value = access.coerce(jArg(args, 2));
    access.revalidate();
    access.write(value);
    return value;
  });
  method('compareExchange', 4, (args) {
    final access = JAtomicAccess.from(args);
    final expected = access.wrap(access.coerce(jArg(args, 2)));
    final replacement = access.coerce(jArg(args, 3));
    access.revalidate();
    final old = access.read();
    if (jStrictEqual(old, expected)) access.write(replacement);
    return old;
  });
  for (final op in {
    'add': '+',
    'sub': '-',
    'and': '&',
    'or': '|',
    'xor': '^',
    'exchange': '',
  }.entries) {
    method(op.key, 3, (args) {
      final access = JAtomicAccess.from(args);
      final value = access.wrap(access.coerce(jArg(args, 2)));
      access.revalidate();
      final old = access.read();
      access.write(op.value.isEmpty ? value : jBinary(op.value, old, value));
      return old;
    });
  }
  method(
    'isLockFree',
    1,
    (args) => [1, 2, 4, 8].contains(jInteger(jArg(args, 0))),
  );
  method('wait', 4, (args) => jAtomicsWait(args, asynchronous: false));
  method('waitAsync', 4, (args) => jAtomicsWait(args, asynchronous: true));
  method('pause', 0, (args) {
    final value = jArg(args, 0);
    if (!identical(value, jUndefined) &&
        (value is! num ||
            !value.isFinite ||
            value.truncateToDouble() != value)) {
      throw JThrown(JError('TypeError', 'Atomics.pause requires an integer'));
    }
    return jUndefined;
  });
  method('notify', 3, (args) {
    final access = JAtomicAccess.from(args, waitable: true);
    final count = identical(jArg(args, 2), jUndefined)
        ? double.infinity
        : math.max(jInteger(args[2]), 0);
    final buffer = access.array.buffer;
    if (buffer is! JSharedArrayBuffer) return 0.0;
    final queue = buffer.waiters[access.offset];
    if (queue == null) return 0.0;
    var notified = 0;
    while (queue.isNotEmpty && notified < count) {
      final waiter = queue.removeFirst();
      waiter.timer?.cancel();
      waiter.promise.resolve('ok');
      notified++;
    }
    if (queue.isEmpty) buffer.waiters.remove(access.offset);
    return notified.toDouble();
  });
  atomics.symbols[jSymbols['toStringTag']!] = 'Atomics';
  jBuiltinProperties(atomics);
  atomics.flags[jSymbols['toStringTag']!]!.writable = false;
  scope.define('Atomics', atomics);
}
