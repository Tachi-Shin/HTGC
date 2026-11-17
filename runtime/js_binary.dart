part of 'js_core.dart';

int jIndex(dynamic value) {
  final number = jInteger(value);
  if (number < 0 || number > 9007199254740991)
    throw JThrown(JError('RangeError', 'Invalid index'));
  return number.toInt();
}

int jBufferSize(dynamic value) {
  final size = jIndex(value);
  if (size > 0x10000000)
    throw JThrown(
      JError('RangeError', 'Buffer exceeds implementation memory limit'),
    );
  return size;
}

class JArrayBuffer extends JObject {
  Uint8List bytes;
  final int maximum;
  final bool resizable;
  bool detached = false;
  JArrayBuffer(int length, {int? maximum})
    : bytes = Uint8List(length),
      maximum = maximum ?? length,
      resizable = maximum != null {
    prototype = jArrayBufferPrototype;
  }
  void check() {
    if (detached) throw JThrown(JError('TypeError', 'Detached ArrayBuffer'));
  }

  void detach() {
    bytes = Uint8List(0);
    detached = true;
  }
}

final jArrayBufferPrototype = JObject();
final jDataViewPrototype = JObject();
final jTypedArrayPrototype = JObject();
final jTypedPrototypes = <String, JObject>{};
final jTypedConstructors = <String, JFunction>{};
const jElementSizes = {
  'Int8Array': 1,
  'Uint8Array': 1,
  'Uint8ClampedArray': 1,
  'Int16Array': 2,
  'Uint16Array': 2,
  'Int32Array': 4,
  'Uint32Array': 4,
  'Float16Array': 2,
  'Float32Array': 4,
  'Float64Array': 8,
  'BigInt64Array': 8,
  'BigUint64Array': 8,
};

double? jTypedIndex(Object key) {
  if (key is! String) return null;
  if (key == '-0') return -0.0;
  final n = jNumber(key);
  return jString(n) == key ? n : null;
}

List<Object> jOrdinaryTypedKeys(
  JTypedArray value, {
  required bool enumerable,
  required bool strings,
}) => [
  for (final key in value.properties.keys)
    if (!enumerable || (value.flags[key]?.enumerable ?? true)) key,
  if (!strings)
    for (final key in value.symbols.keys)
      if (!enumerable || (value.flags[key]?.enumerable ?? true)) key,
];

class JDataView extends JObject {
  final JArrayBuffer buffer;
  final int offset;
  final int? fixedLength;
  JDataView(this.buffer, this.offset, this.fixedLength) {
    prototype = jDataViewPrototype;
  }
  int get length => fixedLength ?? buffer.bytes.length - offset;
  void check() {
    buffer.check();
    if (offset + length > buffer.bytes.length || offset > buffer.bytes.length)
      throw JThrown(JError('TypeError', 'DataView is out of bounds'));
  }
}

class JTypedArray extends JObject {
  final String kind;
  final JArrayBuffer buffer;
  final int offset;
  final int? fixedLength;
  JTypedArray(this.kind, this.buffer, this.offset, this.fixedLength) {
    prototype = jTypedPrototypes[kind];
  }
  int get size => jElementSizes[kind]!;
  bool get outOfBounds =>
      buffer.detached ||
      offset > buffer.bytes.length ||
      fixedLength != null && offset + fixedLength! * size > buffer.bytes.length;
  int get length =>
      outOfBounds ? 0 : fixedLength ?? (buffer.bytes.length - offset) ~/ size;
  void check() {
    if (outOfBounds)
      throw JThrown(
        JError('TypeError', 'TypedArray buffer is detached or out of bounds'),
      );
  }

  bool valid(double index) =>
      !outOfBounds &&
      index.isFinite &&
      index >= 0 &&
      !(index == 0 && index.isNegative) &&
      index == index.truncateToDouble() &&
      index < length;
  dynamic at(int index) => index < 0 || index >= length
      ? jUndefined
      : jReadElement(buffer, offset + index * size, kind, Endian.host);
  @override
  dynamic read(Object key, dynamic receiver) {
    final index = jTypedIndex(key);
    if (index != null) return valid(index) ? at(index.toInt()) : jUndefined;
    return super.read(key, receiver);
  }

  @override
  bool own(Object key) {
    final index = jTypedIndex(key);
    return index != null ? valid(index) : super.own(key);
  }

  @override
  dynamic raw(Object key) {
    final index = jTypedIndex(key);
    return index != null && valid(index) ? at(index.toInt()) : super.raw(key);
  }

  @override
  bool write(Object key, dynamic value, dynamic receiver) {
    final index = jTypedIndex(key);
    if (index == null) return super.write(key, value, receiver);
    if (!identical(receiver, this)) return super.write(key, value, receiver);
    final converted = kind.startsWith('Big') ? jBigInt(value) : jNumber(value);
    if (valid(index))
      jWriteElement(
        buffer,
        offset + index.toInt() * size,
        kind,
        converted,
        Endian.host,
      );
    return true;
  }

  @override
  bool remove(Object key) {
    final index = jTypedIndex(key);
    return index != null ? !valid(index) : super.remove(key);
  }

  bool defineIndex(Object key, JObject descriptor) {
    final index = jTypedIndex(key)!;
    if (!valid(index) || descriptor.own('get') || descriptor.own('set'))
      return false;
    for (final name in ['configurable', 'enumerable', 'writable'])
      if (descriptor.own(name) && !jTruthy(descriptor.get(name))) return false;
    if (descriptor.own('value')) write(key, descriptor.get('value'), this);
    return true;
  }
}

int jFloat16(double value) {
  final sign = value.isNegative ? 0x8000 : 0;
  if (value.isNaN) return 0x7e00;
  if (value.isInfinite) return sign | 0x7c00;
  if (value == 0) return sign;
  final (numerator, denominator) = jDoubleFraction(value);
  var exponent =
      ((ByteData(8)..setFloat64(0, value.abs())).getUint32(0) >> 20 & 0x7ff) -
      1023;
  final shift = exponent < -14 ? 24 : 10 - exponent;
  final n = shift >= 0 ? numerator << shift : numerator;
  final d = shift >= 0 ? denominator : denominator << -shift;
  var quotient = n ~/ d;
  final remainder = n % d;
  if (remainder * BigInt.two > d ||
      remainder * BigInt.two == d && quotient.isOdd)
    quotient += BigInt.one;
  var significand = quotient.toInt();
  if (exponent < -14) return sign | significand;
  if (significand >= 2048) {
    significand >>= 1;
    exponent++;
  }
  if (exponent > 15) return sign | 0x7c00;
  return sign | ((exponent + 15) << 10) | (significand - 1024);
}

double jFromFloat16(int bits) {
  final exponent = (bits >> 10) & 31, mantissa = bits & 1023;
  final value = exponent == 31
      ? (mantissa == 0 ? double.infinity : double.nan)
      : exponent == 0
      ? mantissa * math.pow(2, -24)
      : (1024 + mantissa) * math.pow(2, exponent - 25);
  return (bits & 0x8000) != 0 ? -value.toDouble() : value.toDouble();
}

dynamic jReadElement(
  JArrayBuffer buffer,
  int offset,
  String kind,
  Endian endian,
) {
  final data = ByteData.sublistView(buffer.bytes);
  switch (kind) {
    case 'Int8Array':
      return data.getInt8(offset).toDouble();
    case 'Uint8Array':
    case 'Uint8ClampedArray':
      return data.getUint8(offset).toDouble();
    case 'Int16Array':
      return data.getInt16(offset, endian).toDouble();
    case 'Uint16Array':
      return data.getUint16(offset, endian).toDouble();
    case 'Int32Array':
      return data.getInt32(offset, endian).toDouble();
    case 'Uint32Array':
      return data.getUint32(offset, endian).toDouble();
    case 'Float32Array':
      return data.getFloat32(offset, endian);
    case 'Float64Array':
      return data.getFloat64(offset, endian);
    case 'Float16Array':
      return jFromFloat16(data.getUint16(offset, endian));
    default:
      final low = data.getUint32(
            offset + (endian == Endian.little ? 0 : 4),
            endian,
          ),
          high = data.getUint32(
            offset + (endian == Endian.little ? 4 : 0),
            endian,
          );
      var n = (BigInt.from(high) << 32) | BigInt.from(low);
      if (kind == 'BigInt64Array' && (high & 0x80000000) != 0)
        n -= BigInt.one << 64;
      return n;
  }
}

void jWriteElement(
  JArrayBuffer buffer,
  int offset,
  String kind,
  dynamic value,
  Endian endian,
) {
  final data = ByteData.sublistView(buffer.bytes);
  if (kind.startsWith('Big')) {
    final n = jBigInt(value) & ((BigInt.one << 64) - BigInt.one);
    data.setUint32(
      offset + (endian == Endian.little ? 0 : 4),
      (n & BigInt.from(0xffffffff)).toInt(),
      endian,
    );
    data.setUint32(
      offset + (endian == Endian.little ? 4 : 0),
      (n >> 32).toInt(),
      endian,
    );
    return;
  }
  final n = jNumber(value);
  switch (kind) {
    case 'Int8Array':
    case 'Uint8Array':
      data.setUint8(offset, jUint32(n) & 255);
      break;
    case 'Uint8ClampedArray':
      final x = n.isNaN ? 0.0 : n.clamp(0, 255).toDouble(),
          floor = n.isNaN ? 0 : n.clamp(0, 255).floor();
      data.setUint8(
        offset,
        x - floor > 0.5 || x - floor == 0.5 && floor.isOdd ? floor + 1 : floor,
      );
      break;
    case 'Int16Array':
    case 'Uint16Array':
      data.setUint16(offset, jUint32(n) & 65535, endian);
      break;
    case 'Int32Array':
    case 'Uint32Array':
      data.setUint32(offset, jUint32(n), endian);
      break;
    case 'Float16Array':
      data.setUint16(offset, jFloat16(n), endian);
      break;
    case 'Float32Array':
      data.setFloat32(offset, n, endian);
      break;
    case 'Float64Array':
      data.setFloat64(offset, n, endian);
      break;
  }
}

JTypedArray jTypedCreate(String kind, int length) {
  final bytes = jBufferSize(length * jElementSizes[kind]!);
  return JTypedArray(kind, JArrayBuffer(bytes), 0, length);
}

JTypedArray jTypedFrom(String kind, List<dynamic> values) {
  final result = jTypedCreate(kind, values.length);
  for (var i = 0; i < values.length; i++) result.write('$i', values[i], result);
  return result;
}

JTypedArray jTypedReceiver(dynamic receiver) {
  if (receiver is! JTypedArray)
    throw JThrown(JError('TypeError', 'TypedArray receiver required'));
  receiver.check();
  return receiver;
}

JObject jTypedIterator(JTypedArray target, String mode) {
  var index = 0;
  bool done = false;
  final iterator = JObject();
  iterator.properties['next'] = jBuiltin((a) {
    if (!done) {
      target.check();
      if (index >= target.length) done = true;
    }
    if (done) return JObject({'value': jUndefined, 'done': true});
    final i = index++;
    return JObject({
      'value': mode == 'keys'
          ? i.toDouble()
          : mode == 'entries'
          ? <dynamic>[i.toDouble(), target.at(i)]
          : target.at(i),
      'done': false,
    });
  });
  iterator.symbols[jSymbols['iterator']!] = jBuiltin((a) => iterator);
  return iterator;
}

void jAccessor(JObject prototype, String name, dynamic Function(dynamic) read) {
  prototype.store(name, jUndefined);
  prototype._accessors.add(name);
  prototype.getters[name] = JFunction((a, r) => read(r), constructible: false);
  prototype.flags[name] = JPropertyFlags(enumerable: false);
}

void jInstallSpeciesGetter(JFunction constructor) {
  final key = jSymbols['species']!;
  constructor.store(key, jUndefined);
  constructor._accessors.add(key);
  constructor.getters[key] = jNamedFunction(
    JFunction((args, receiver) => receiver, constructible: false),
    'get [Symbol.species]',
    0,
  );
  constructor.flags[key] = JPropertyFlags(enumerable: false);
}

JFunction jSpeciesConstructor(JObject value, JFunction fallback) {
  final constructor = jGet(value, 'constructor');
  if (identical(constructor, jUndefined)) return fallback;
  if (!jIsObject(constructor)) {
    throw JThrown(JError('TypeError', 'Invalid constructor for Species'));
  }
  final species = jGet(constructor, jSymbols['species']);
  if (jNullish(species)) return fallback;
  if (species is! JFunction || !species.constructible) {
    throw JThrown(JError('TypeError', 'Symbol.species must be a constructor'));
  }
  return species;
}

JTypedArray jTypedSpeciesCreate(
  JTypedArray source,
  List<dynamic> args, {
  int? length,
}) {
  final constructor = jSpeciesConstructor(
    source,
    jTypedConstructors[source.kind]!,
  );
  final result = jNew(constructor, args);
  if (result is! JTypedArray) {
    throw JThrown(JError('TypeError', 'Species must construct a typed array'));
  }
  result.check();
  if (length != null && result.length < length) {
    throw JThrown(
      JError('TypeError', 'Species returned a shorter typed array'),
    );
  }
  if (source.kind.startsWith('Big') != result.kind.startsWith('Big')) {
    throw JThrown(
      JError('TypeError', 'Species changed the typed array content type'),
    );
  }
  return result;
}

JArrayBuffer jBufferSpeciesSlice(
  JArrayBuffer source,
  List<dynamic> args,
  JFunction fallback,
) {
  source.check();
  final length = source.bytes.length;
  final start = jRelativeIndex(jArg(args, 0), length);
  final end = identical(jArg(args, 1), jUndefined)
      ? length
      : jRelativeIndex(args[1], length);
  final count = math.max(end - start, 0);
  final result = jNew(jSpeciesConstructor(source, fallback), [
    count.toDouble(),
  ]);
  if (result is! JArrayBuffer ||
      (result is JSharedArrayBuffer) != (source is JSharedArrayBuffer) ||
      identical(result, source)) {
    throw JThrown(JError('TypeError', 'Invalid buffer returned by Species'));
  }
  result.check();
  if (result.bytes.length < count) {
    throw JThrown(JError('TypeError', 'Species returned a shorter buffer'));
  }
  source.check();
  if (start < source.bytes.length) {
    result.bytes.setRange(
      0,
      math.min(count, source.bytes.length - start),
      source.bytes,
      start,
    );
  }
  return result;
}

JTypedArray jTypedCreateByConstructor(dynamic constructor, int length) {
  final result = jNew(constructor, [length.toDouble()]);
  if (result is! JTypedArray) {
    throw JThrown(JError('TypeError', 'Constructor must return a TypedArray'));
  }
  result.check();
  if (result.length < length) {
    throw JThrown(
      JError('TypeError', 'Constructor returned a shorter TypedArray'),
    );
  }
  return result;
}

JFunction jBuildTypedArrayConstructor() {
  Never abstractConstructor() => throw JThrown(
    JError('TypeError', 'TypedArray is an abstract constructor'),
  );
  final constructor = jNamedFunction(
    JFunction(
      (args, receiver) => abstractConstructor(),
      construct: (args) => abstractConstructor(),
    ),
    'TypedArray',
    0,
  );
  constructor.properties['prototype'] = jTypedArrayPrototype;
  jInstallSpeciesGetter(constructor);
  constructor.properties['of'] = jNamedFunction(
    JFunction((args, receiver) {
      final result = jTypedCreateByConstructor(receiver, args.length);
      for (var i = 0; i < args.length; i++) {
        result.write('$i', args[i], result);
      }
      return result;
    }, constructible: false),
    'of',
    0,
  );
  constructor.properties['from'] = jNamedFunction(
    JFunction((args, receiver) {
      if (receiver is! JFunction || !receiver.constructible) {
        throw JThrown(
          JError('TypeError', 'TypedArray.from requires a constructor'),
        );
      }
      final input = jArg(args, 0);
      final mapper = jArg(args, 1);
      if (!identical(mapper, jUndefined) && mapper is! JFunction) {
        throw JThrown(JError('TypeError', 'Mapper is not callable'));
      }
      final iteratorMethod = jGet(input, jSymbols['iterator']);
      final List<dynamic>? items;
      final int length;
      if (!jNullish(iteratorMethod)) {
        final iterator = jCall(iteratorMethod, [], receiver: input);
        if (!jIsObject(iterator)) {
          throw JThrown(JError('TypeError', 'Iterator must be an object'));
        }
        final record = JIteratorRecord(iterator);
        items = [];
        while (record.advance()) {
          items.add(record.current);
        }
        length = items.length;
      } else {
        items = null;
        length = jLength(jGet(input, 'length'));
      }
      final result = jTypedCreateByConstructor(receiver, length);
      for (var i = 0; i < length; i++) {
        final item = items == null ? jGet(input, i) : items[i];
        final value = mapper is JFunction
            ? jCall(mapper, [item, i.toDouble()], receiver: jArg(args, 2))
            : item;
        result.write('$i', value, result);
      }
      return result;
    }, constructible: false),
    'from',
    1,
  );
  jBuiltinProperties(constructor);
  constructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  return constructor;
}

void installJSBinary(JScope scope) {
  JArrayBuffer buffer(dynamic value) {
    if (value is! JArrayBuffer || value is JSharedArrayBuffer)
      throw JThrown(JError('TypeError', 'ArrayBuffer required'));
    return value;
  }

  final ab = JFunction(
    (a, r) => throw JThrown(JError('TypeError', 'ArrayBuffer requires new')),
    constructWithTarget: jBuiltinAllocator(jArrayBufferPrototype, (a) {
      final length = jBufferSize(jArg(a, 0)), options = jArg(a, 1);
      final maximum = jIsObject(options)
          ? jGet(options, 'maxByteLength')
          : jUndefined;
      final max = identical(maximum, jUndefined) ? null : jBufferSize(maximum);
      if (max != null && max < length)
        throw JThrown(JError('RangeError', 'Length exceeds maxByteLength'));
      return JArrayBuffer(length, maximum: max);
    }),
  );
  ab.properties.addAll({
    'prototype': jArrayBufferPrototype,
    'isView': jBuiltin(
      (a) => jArg(a, 0) is JTypedArray || jArg(a, 0) is JDataView,
    ),
  });
  jArrayBufferPrototype.properties['constructor'] = ab;
  jInstallSpeciesGetter(ab);
  jAccessor(
    jArrayBufferPrototype,
    'byteLength',
    (r) => buffer(r).bytes.length.toDouble(),
  );
  jAccessor(
    jArrayBufferPrototype,
    'maxByteLength',
    (r) => buffer(r).detached ? 0.0 : buffer(r).maximum.toDouble(),
  );
  jAccessor(jArrayBufferPrototype, 'resizable', (r) => buffer(r).resizable);
  jAccessor(jArrayBufferPrototype, 'detached', (r) => buffer(r).detached);
  jArrayBufferPrototype.properties['resize'] = JFunction((a, r) {
    final b = buffer(r);
    if (!b.resizable)
      throw JThrown(JError('TypeError', 'Buffer is not resizable'));
    final length = jIndex(jArg(a, 0));
    b.check();
    if (length > b.maximum)
      throw JThrown(JError('RangeError', 'Length exceeds maxByteLength'));
    final next = Uint8List(length)
      ..setRange(0, math.min(length, b.bytes.length), b.bytes);
    b.bytes = next;
    return jUndefined;
  }, constructible: false);
  jArrayBufferPrototype.properties['slice'] = JFunction(
    (a, r) => jBufferSpeciesSlice(buffer(r), a, ab),
    constructible: false,
  );
  for (final fixed in [true, false])
    jArrayBufferPrototype.properties[fixed
        ? 'transferToFixedLength'
        : 'transfer'] = JFunction((a, r) {
      final b = buffer(r),
          length = identical(jArg(a, 0), jUndefined)
              ? b.bytes.length
              : jBufferSize(a[0]);
      b.check();
      if (!fixed && b.resizable && length > b.maximum)
        throw JThrown(JError('RangeError', 'Length exceeds maxByteLength'));
      final result = JArrayBuffer(
        length,
        maximum: !fixed && b.resizable ? b.maximum : null,
      );
      result.bytes.setRange(0, math.min(length, b.bytes.length), b.bytes);
      b.detach();
      return result;
    }, constructible: false);
  final dv = JFunction(
    (a, r) => throw JThrown(JError('TypeError', 'DataView requires new')),
    constructWithTarget: jBuiltinAllocator(jDataViewPrototype, (a) {
      final b = jArg(a, 0);
      if (b is! JArrayBuffer)
        throw JThrown(
          JError('TypeError', 'ArrayBuffer or SharedArrayBuffer required'),
        );
      final offset = jIndex(jArg(a, 1));
      b.check();
      if (offset > b.bytes.length)
        throw JThrown(JError('RangeError', 'Offset outside buffer'));
      final length = identical(jArg(a, 2), jUndefined)
          ? (b.resizable ? null : b.bytes.length - offset)
          : jIndex(a[2]);
      b.check();
      if (offset + (length ?? 0) > b.bytes.length)
        throw JThrown(JError('RangeError', 'View outside buffer'));
      return JDataView(b, offset, length);
    }),
  );
  dv.properties['prototype'] = jDataViewPrototype;
  jDataViewPrototype.properties['constructor'] = dv;
  JDataView view(dynamic r) {
    if (r is! JDataView)
      throw JThrown(JError('TypeError', 'DataView required'));
    return r;
  }

  jAccessor(jDataViewPrototype, 'buffer', (r) => view(r).buffer);
  jAccessor(jDataViewPrototype, 'byteLength', (r) {
    final v = view(r);
    v.check();
    return v.length.toDouble();
  });
  jAccessor(jDataViewPrototype, 'byteOffset', (r) {
    final v = view(r);
    v.check();
    return v.offset.toDouble();
  });
  for (final kind in jElementSizes.keys.where(
    (k) => k != 'Uint8ClampedArray',
  )) {
    final suffix = kind.replaceAll('Array', ''), size = jElementSizes[kind]!;
    for (final write in [false, true])
      jDataViewPrototype
          .properties['${write ? 'set' : 'get'}$suffix'] = JFunction((a, r) {
        final v = view(r), index = jIndex(jArg(a, 0));
        final converted = write
            ? (kind.startsWith('Big')
                  ? jBigInt(jArg(a, 1))
                  : jNumber(jArg(a, 1)))
            : jUndefined;
        final endian = jTruthy(jArg(a, write ? 2 : 1))
            ? Endian.little
            : Endian.big;
        v.check();
        if (index + size > v.length)
          throw JThrown(JError('RangeError', 'DataView access outside view'));
        if (write) {
          jWriteElement(v.buffer, v.offset + index, kind, converted, endian);
          return jUndefined;
        }
        return jReadElement(v.buffer, v.offset + index, kind, endian);
      }, constructible: false);
  }
  final typedArrayConstructor = jBuildTypedArrayConstructor();
  jTypedArrayPrototype.properties['constructor'] = typedArrayConstructor;
  for (final kind in jElementSizes.keys) {
    final size = jElementSizes[kind]!;
    final proto = jTypedPrototypes.putIfAbsent(
      kind,
      () => JObject()..prototype = jTypedArrayPrototype,
    );
    final constructor = JFunction(
      (a, r) => throw JThrown(JError('TypeError', '$kind requires new')),
      constructWithTarget: jBuiltinAllocator(proto, (a) {
        final input = jArg(a, 0);
        if (input is JArrayBuffer) {
          final offset = jIndex(jArg(a, 1));
          if (offset % size != 0)
            throw JThrown(JError('RangeError', 'Unaligned typed array offset'));
          final count = identical(jArg(a, 2), jUndefined) ? null : jIndex(a[2]);
          input.check();
          if (offset > input.bytes.length ||
              count != null && offset + count * size > input.bytes.length ||
              count == null &&
                  !input.resizable &&
                  (input.bytes.length - offset) % size != 0)
            throw JThrown(
              JError('RangeError', 'Invalid typed array view length'),
            );
          return JTypedArray(
            kind,
            input,
            offset,
            count ??
                (input.resizable
                    ? null
                    : (input.bytes.length - offset) ~/ size),
          );
        }
        if (input is JTypedArray) {
          input.check();
          if (input.kind.startsWith('Big') != kind.startsWith('Big'))
            throw JThrown(
              JError('TypeError', 'Cannot mix BigInt and Number arrays'),
            );
          return jTypedFrom(kind, [
            for (var i = 0; i < input.length; i++) input.at(i),
          ]);
        }
        if (jIsObject(input)) {
          final iterator = jGet(input, jSymbols['iterator']);
          final values = !jNullish(iterator)
              ? jIterable(input).toList()
              : jArrayLikeList(input);
          return jTypedFrom(kind, values);
        }
        return jTypedCreate(kind, jBufferSize(input));
      }),
    );
    constructor.properties.addAll({
      'prototype': proto,
      'BYTES_PER_ELEMENT': size,
    });
    constructor.prototype = typedArrayConstructor;
    proto.properties.addAll({
      'constructor': constructor,
      'BYTES_PER_ELEMENT': size,
    });
    if (kind == 'Uint8Array') jInstallByteEncoding(constructor, proto);
    jBuiltinProperties(proto);
    jBuiltinProperties(constructor);
    jNameFunction(constructor, kind, 3);
    for (final obj in [proto, constructor])
      obj.flags['BYTES_PER_ELEMENT'] = JPropertyFlags(
        writable: false,
        enumerable: false,
        configurable: false,
      );
    jTypedConstructors[kind] = constructor;
    scope.define(kind, constructor);
  }
  JTypedArray typed(dynamic r) {
    if (r is! JTypedArray)
      throw JThrown(JError('TypeError', 'TypedArray required'));
    return r;
  }

  jAccessor(jTypedArrayPrototype, 'buffer', (r) => typed(r).buffer);
  jAccessor(jTypedArrayPrototype, 'length', (r) => typed(r).length.toDouble());
  jAccessor(
    jTypedArrayPrototype,
    'byteLength',
    (r) => (typed(r).length * typed(r).size).toDouble(),
  );
  jAccessor(
    jTypedArrayPrototype,
    'byteOffset',
    (r) => typed(r).outOfBounds ? 0.0 : typed(r).offset.toDouble(),
  );
  jTypedArrayPrototype.symbols[jSymbols['toStringTag']!] = jUndefined;
  jTypedArrayPrototype._accessors.add(jSymbols['toStringTag']!);
  jTypedArrayPrototype.getters[jSymbols['toStringTag']!] = JFunction(
    (a, r) => r is JTypedArray ? r.kind : jUndefined,
    constructible: false,
  );
  for (final mode in ['keys', 'values', 'entries'])
    jTypedArrayPrototype.properties[mode] = JFunction(
      (a, r) => jTypedIterator(jTypedReceiver(r), mode),
      constructible: false,
    );
  jTypedArrayPrototype.symbols[jSymbols['iterator']!] =
      jTypedArrayPrototype.properties['values'];
  jInstallTypedMethods();
  for (final proto in [
    jArrayBufferPrototype,
    jDataViewPrototype,
    jTypedArrayPrototype,
  ])
    jBuiltinProperties(proto);
  jArrayBufferPrototype.symbols[jSymbols['toStringTag']!] = 'ArrayBuffer';
  jDataViewPrototype.symbols[jSymbols['toStringTag']!] = 'DataView';
  scope.define('ArrayBuffer', ab);
  scope.define('DataView', dv);
}

void jInstallTypedMethods() {
  void method(String name, dynamic Function(List<dynamic>, JTypedArray) body) {
    jTypedArrayPrototype.properties[name] = JFunction(
      (a, r) => body(a, jTypedReceiver(r)),
      constructible: false,
    );
  }

  method('at', (a, t) {
    final i = jInteger(jArg(a, 0));
    return !i.isFinite ? jUndefined : t.at((i < 0 ? t.length + i : i).toInt());
  });
  method(
    'join',
    (a, t) =>
        [for (var i = 0; i < t.length; i++) jString(t.at(i))]
            .join(identical(jArg(a, 0), jUndefined) ? ',' : jString(a[0])),
  );
  method('toString', (a, t) => jInvoke(t, 'join', []));
  method('toLocaleString', (a, t) {
    final length = t.length;
    return [for (var i = 0; i < length; i++) jLocaleElement(t.at(i), a)]
        .join(',');
  });
  method('set', (a, t) {
    final offset = jInteger(jArg(a, 1));
    if (offset < 0 || !offset.isFinite)
      throw JThrown(JError('RangeError', 'Invalid set offset'));
    final source = jArg(a, 0);
    if (source is JTypedArray) {
      source.check();
      if (source.kind.startsWith('Big') != t.kind.startsWith('Big'))
        throw JThrown(
          JError('TypeError', 'Cannot mix BigInt and Number arrays'),
        );
    }
    final values = source is JTypedArray
        ? [for (var i = 0; i < source.length; i++) source.at(i)]
        : jArrayLikeList(jObject(jRequireCoercible(source)));
    if (offset + values.length > t.length)
      throw JThrown(JError('RangeError', 'Source exceeds target length'));
    if (source is JTypedArray && source.kind == t.kind) {
      final bytes = source.buffer.bytes.sublist(
        source.offset,
        source.offset + source.length * source.size,
      );
      t.buffer.bytes.setRange(
        t.offset + offset.toInt() * t.size,
        t.offset + (offset.toInt() + values.length) * t.size,
        bytes,
      );
    } else
      for (var i = 0; i < values.length; i++)
        t.write('${offset.toInt() + i}', values[i], t);
    return jUndefined;
  });
  method('subarray', (a, t) {
    final length = t.length;
    final start = jRelativeIndex(jArg(a, 0), length);
    final openEnd = identical(jArg(a, 1), jUndefined);
    final end = openEnd ? length : jRelativeIndex(a[1], length);
    return jTypedSpeciesCreate(t, [
      t.buffer,
      (t.offset + start * t.size).toDouble(),
      if (!openEnd || t.fixedLength != null)
        math.max(end - start, 0).toDouble(),
    ]);
  });
  method('slice', (a, t) {
    final length = t.length;
    final start = jRelativeIndex(jArg(a, 0), length);
    final end = identical(jArg(a, 1), jUndefined)
        ? length
        : jRelativeIndex(a[1], length);
    final requested = math.max(end - start, 0);
    final result = jTypedSpeciesCreate(t, [
      requested.toDouble(),
    ], length: requested);
    if (requested == 0) return result;
    t.check();
    final count = math.max(0, math.min(requested, t.length - start));
    if (count == 0) return result;
    if (result.kind == t.kind && !identical(t.buffer, result.buffer)) {
      result.buffer.bytes.setRange(
        result.offset,
        result.offset + count * t.size,
        t.buffer.bytes,
        t.offset + start * t.size,
      );
    } else {
      for (var i = 0; i < count; i++) {
        result.write('$i', t.at(start + i), result);
      }
    }
    return result;
  });
  method('fill', (a, t) {
    final value = t.kind.startsWith('Big')
        ? jBigInt(jArg(a, 0))
        : jNumber(jArg(a, 0));
    final start = jRelativeIndex(jArg(a, 1), t.length),
        end = identical(jArg(a, 2), jUndefined)
            ? t.length
            : jRelativeIndex(a[2], t.length);
    t.check();
    for (var i = start; i < end; i++) t.write('$i', value, t);
    return t;
  });
  method('copyWithin', (a, t) {
    final length = t.length,
        to = jRelativeIndex(jArg(a, 0), length),
        start = jRelativeIndex(jArg(a, 1), length),
        end = identical(jArg(a, 2), jUndefined)
            ? length
            : jRelativeIndex(a[2], length);
    t.check();
    final count = math.min(math.max(end - start, 0), length - to);
    final bytes = t.buffer.bytes.sublist(
      t.offset + start * t.size,
      t.offset + (start + count) * t.size,
    );
    t.buffer.bytes.setRange(
      t.offset + to * t.size,
      t.offset + (to + count) * t.size,
      bytes,
    );
    return t;
  });
  for (final mode in [
    'forEach',
    'map',
    'filter',
    'some',
    'every',
    'find',
    'findIndex',
    'findLast',
    'findLastIndex',
  ])
    method(mode, (a, t) {
      final callback = jArg(a, 0);
      if (callback is! JFunction)
        throw JThrown(JError('TypeError', 'Callback required'));
      final length = t.length, values = <dynamic>[];
      final mappedArray = mode == 'map'
          ? jTypedSpeciesCreate(t, [length.toDouble()], length: length)
          : null;
      for (var step = 0; step < length; step++) {
        final i = mode.startsWith('findLast') ? length - 1 - step : step,
            value = t.at(i),
            mapped = jCall(callback, [
              value,
              i.toDouble(),
              t,
            ], receiver: jArg(a, 1));
        if (mappedArray != null) mappedArray.write('$i', mapped, mappedArray);
        if (mode == 'filter' && jTruthy(mapped)) values.add(value);
        if (mode == 'some' && jTruthy(mapped)) return true;
        if (mode == 'every' && !jTruthy(mapped)) return false;
        if (mode.startsWith('find') && jTruthy(mapped))
          return mode.endsWith('Index') ? i.toDouble() : value;
      }
      if (mappedArray != null) return mappedArray;
      if (mode == 'filter') {
        final result = jTypedSpeciesCreate(t, [
          values.length.toDouble(),
        ], length: values.length);
        for (var i = 0; i < values.length; i++) {
          result.write('$i', values[i], result);
        }
        return result;
      }
      return mode == 'some'
          ? false
          : mode == 'every'
          ? true
          : mode.endsWith('Index')
          ? -1.0
          : jUndefined;
    });
  for (final right in [false, true])
    method(right ? 'reduceRight' : 'reduce', (a, t) {
      final callback = jArg(a, 0);
      if (callback is! JFunction)
        throw JThrown(JError('TypeError', 'Callback required'));
      final length = t.length;
      if (length == 0 && a.length < 2)
        throw JThrown(JError('TypeError', 'Empty reduce'));
      var value = a.length > 1 ? a[1] : t.at(right ? length - 1 : 0);
      for (var step = a.length > 1 ? 0 : 1; step < length; step++) {
        final i = right ? length - 1 - step : step;
        value = jCall(callback, [value, t.at(i), i.toDouble(), t]);
      }
      return value;
    });
  for (final mode in ['includes', 'indexOf', 'lastIndexOf'])
    method(mode, (a, t) {
      final length = t.length;
      if (length == 0) return mode == 'includes' ? false : -1.0;
      final from = mode == 'lastIndexOf' && a.length < 2
          ? length - 1.0
          : jInteger(jArg(a, 1));
      if (mode == 'lastIndexOf') {
        var i = from == double.negativeInfinity
            ? -1
            : from == double.infinity
            ? length - 1
            : math.min(from < 0 ? length + from : from, length - 1).toInt();
        for (; i >= 0; i--)
          if (jStrictEqual(t.at(i), jArg(a, 0))) return i.toDouble();
      } else {
        var i = from == double.infinity
            ? length
            : from == double.negativeInfinity
            ? 0
            : math.max(from < 0 ? length + from : from, 0).toInt();
        for (; i < length; i++)
          if (mode == 'includes'
              ? jSameValue(t.at(i), jArg(a, 0), zero: true)
              : jStrictEqual(t.at(i), jArg(a, 0)))
            return mode == 'includes' ? true : i.toDouble();
      }
      return mode == 'includes' ? false : -1.0;
    });
  for (final copy in [false, true])
    method(copy ? 'toReversed' : 'reverse', (a, t) {
      final result = copy ? jTypedCreate(t.kind, t.length) : t,
          values = [for (var i = t.length - 1; i >= 0; i--) t.at(i)];
      for (var i = 0; i < values.length; i++)
        result.write('$i', values[i], result);
      return result;
    });
  for (final copy in [false, true])
    method(copy ? 'toSorted' : 'sort', (a, t) {
      final callback = jArg(a, 0);
      if (!identical(callback, jUndefined) && callback is! JFunction)
        throw JThrown(JError('TypeError', 'Comparator must be callable'));
      final entries = [
        for (var i = 0; i < t.length; i++) <dynamic>[t.at(i), i],
      ];
      entries.sort((a, b) {
        double comparison;
        if (callback is JFunction) {
          comparison = jNumber(jCall(callback, [a[0], b[0]]));
          if (comparison.isNaN) comparison = 0;
        } else if (a[0] is BigInt)
          comparison = (a[0] as BigInt).compareTo(b[0]).toDouble();
        else {
          final x = a[0] as num, y = b[0] as num;
          comparison = x.isNaN
              ? (y.isNaN ? 0 : 1)
              : y.isNaN
              ? -1
              : x == 0 && y == 0
              ? (x.isNegative == y.isNegative
                    ? 0
                    : x.isNegative
                    ? -1
                    : 1)
              : x < y
              ? -1
              : x > y
              ? 1
              : 0;
        }
        return comparison == 0
            ? (a[1] as int).compareTo(b[1])
            : comparison < 0
            ? -1
            : 1;
      });
      final result = copy ? jTypedCreate(t.kind, entries.length) : t;
      for (var i = 0; i < entries.length; i++)
        result.write('$i', entries[i][0], result);
      return result;
    });
  method('with', (a, t) {
    final index = jInteger(jArg(a, 0)),
        value = t.kind.startsWith('Big')
            ? jBigInt(jArg(a, 1))
            : jNumber(jArg(a, 1)),
        actual = index < 0 ? t.length + index : index;
    if (!actual.isFinite || actual < 0 || actual >= t.length)
      throw JThrown(JError('RangeError', 'Invalid replacement index'));
    return jTypedFrom(t.kind, [
      for (var i = 0; i < t.length; i++) i == actual ? value : t.at(i),
    ]);
  });
}
