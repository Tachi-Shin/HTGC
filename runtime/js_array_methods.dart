part of 'js_core.dart';

Map<String, JFunction> get jArrayMethods => JRealm.current.arrayMethods;
JObject get jArrayPrototypeObject => JRealm.current.arrayPrototypeObject;
JArrayProperties _buildRealmArrayPrototypeObject() {
  final prototype = JArrayProperties(JSparseArray(0), intrinsic: true);
  prototype.properties.addAll(jArrayMethods);
  prototype.symbols[jSymbols['iterator']!] = jArrayMethods['values'];
  prototype.symbols[jSymbols['unscopables']!] = JObject.root({
    for (final name in const [
      'at',
      'copyWithin',
      'entries',
      'fill',
      'find',
      'findIndex',
      'findLast',
      'findLastIndex',
      'flat',
      'flatMap',
      'includes',
      'keys',
      'toReversed',
      'toSorted',
      'toSpliced',
      'values',
    ])
      name: true,
  });
  jBuiltinProperties(prototype);
  prototype.flags[jSymbols['unscopables']!]!.writable = false;
  return prototype;
}

final _arrayProperties = Expando<JArrayProperties>();

JArrayProperties jArrayProperties(List<dynamic> array) => array is JArray
    ? array.extra
    : _arrayProperties[array] ??= JArrayProperties(array);

class JArray extends ListBase<dynamic> {
  List<dynamic> items;
  late final JArrayProperties extra = JArrayProperties(this);
  JArray(this.items) {
    jArrayRealm(this);
  }
  @override
  int get length => items.length;
  @override
  set length(int value) {
    if (items is! JSparseArray && value - items.length > 4096) {
      final sparse = JSparseArray(value);
      for (var index = 0; index < items.length; index++) {
        if (!identical(items[index], _jHole)) sparse[index] = items[index];
      }
      items = sparse;
    } else {
      if (items is! JSparseArray) {
        while (items.length < value) items.add(_jHole);
      }
      items.length = value;
    }
  }

  @override
  dynamic operator [](int index) => items[index];
  @override
  void operator []=(int index, dynamic value) {
    items[index] = value;
  }
}

// Storage for arrays whose initial length consists of holes. JS array lengths
// can be larger than the number of elements that fit in a contiguous Dart List.
class JSparseArray extends ListBase<dynamic> {
  final entries = SplayTreeMap<int, dynamic>();
  int _length;
  JSparseArray(this._length);
  @override
  int get length => _length;
  @override
  set length(int size) {
    while (entries.isNotEmpty && entries.lastKey()! >= size) {
      entries.remove(entries.lastKey());
    }
    _length = size;
  }

  @override
  dynamic operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return entries.containsKey(index) ? entries[index] : _jHole;
  }

  @override
  void operator []=(int index, dynamic value) {
    RangeError.checkValidIndex(index, this);
    if (identical(value, _jHole)) {
      entries.remove(index);
    } else {
      entries[index] = value;
    }
  }
}

class JArrayProperties extends JObject {
  final List<dynamic> array;
  final bool intrinsic;
  JArrayProperties(this.array, {this.intrinsic = false}) {
    prototype = intrinsic
        ? jObjectPrototype
        : jArrayRealm(array).arrayPrototypeObject;
    flags['length'] = JPropertyFlags(
      writable: array is! JTemplateArray,
      enumerable: false,
      configurable: false,
    );
  }

  dynamic get external => intrinsic ? this : array;
  bool get lengthWritable => flags['length']!.writable;

  int? _index(Object key) => key is String ? jArrayIndex(key) : null;
  Iterable<int> get indices {
    final storage = array is JArray ? (array as JArray).items : array;
    return storage is JSparseArray
        ? storage.entries.keys
        : Iterable<int>.generate(storage.length)
              .where((i) => !identical(storage[i], _jHole));
  }

  @override
  bool own(Object key) {
    if (key == 'length') return true;
    final index = _index(key);
    return index == null
        ? super.own(key)
        : index < array.length && !identical(array[index], _jHole);
  }

  @override
  dynamic raw(Object key) {
    if (key == 'length') return array.length.toDouble();
    final index = _index(key);
    return index == null ? super.raw(key) : array[index];
  }

  @override
  void store(Object key, dynamic value) {
    if (key == 'length') {
      _resize((value as num).toInt());
      return;
    }
    final index = _index(key);
    if (index == null) {
      super.store(key, value);
    } else {
      if (index >= array.length) _resize(index + 1);
      array[index] = value;
    }
  }

  void _resize(int size) {
    if (array is! JSparseArray && array is! JArray) {
      while (array.length < size) array.add(_jHole);
    }
    array.length = size;
  }

  @override
  bool remove(Object key) {
    if (key == 'length') return false;
    if (!super.remove(key)) return false;
    final index = _index(key);
    if (index != null && index < array.length) array[index] = _jHole;
    return true;
  }

  List<Object> ownKeys({required bool enumerable, required bool strings}) => [
    for (final i in indices)
      if (!enumerable || (flags['$i']?.enumerable ?? true)) '$i',
    if (!enumerable) 'length',
    for (final key in properties.keys)
      if (!enumerable || (flags[key]?.enumerable ?? true)) key,
    if (!strings)
      for (final key in symbols.keys)
        if (!enumerable || (flags[key]?.enumerable ?? true)) key,
  ];

  bool define(Object key, JObject descriptor) {
    if (key == 'length' && descriptor.own('value'))
      return _setLength(descriptor);
    final index = _index(key);
    if (index != null && index >= array.length && !lengthWritable) return false;
    return jDefineOrdinaryProperty(this, key, descriptor);
  }

  bool _setLength(JObject descriptor) {
    final value = descriptor.raw('value');
    final size = jUint32(value), number = jNumber(value);
    if (size != number) {
      throw JThrown(JError('RangeError', 'Invalid array length'));
    }
    final oldLength = array.length;
    final normalized = JObject.root({
      ...descriptor.properties,
      'value': size.toDouble(),
    });
    if (size >= oldLength)
      return jDefineOrdinaryProperty(this, 'length', normalized);
    if (!lengthWritable) return false;

    final readOnly =
        descriptor.own('writable') && !jTruthy(descriptor.raw('writable'));
    // Validate the attribute changes before removing any elements.
    normalized.properties['value'] = oldLength.toDouble();
    if (readOnly) normalized.properties['writable'] = true;
    if (!jDefineOrdinaryProperty(this, 'length', normalized)) return false;

    try {
      for (final index in indices.where((i) => i >= size).toList().reversed) {
        if (!remove('$index')) {
          _resize(index + 1);
          return false;
        }
      }
      _resize(size);
      return true;
    } finally {
      if (readOnly) flags['length']!.writable = false;
    }
  }
}

List<dynamic> jCreateArray(int length) {
  if (length > 4294967295)
    throw JThrown(JError('RangeError', 'Invalid array length'));
  return jRealmValue(JSparseArray(length));
}

void jCreateDataProperty(dynamic target, Object key, dynamic value) {
  final descriptor = JObject.root({
    'value': value,
    'writable': true,
    'enumerable': true,
    'configurable': true,
  });
  if (!jDefineProperty(
    jRequireObject(target),
    key,
    descriptor,
    normalized: true,
  )) {
    throw JThrown(JError('TypeError', 'Cannot create property'));
  }
}

dynamic jArraySpeciesCreate(dynamic source, int length) {
  if (!jIsArray(source)) return jCreateArray(length);
  var constructor = jGet(source, 'constructor');
  if (constructor is JFunction && constructor.constructible) {
    final realm = jFunctionRealm(constructor);
    if (!identical(realm, JRealm.current) &&
        identical(constructor, realm.arrayConstructor)) {
      constructor = jUndefined;
    }
  }
  if (jIsObject(constructor)) {
    constructor = jGet(constructor, jSymbols['species']);
    if (constructor == null) constructor = jUndefined;
  }
  if (identical(constructor, jUndefined)) return jCreateArray(length);
  if (constructor is! JFunction || !constructor.constructible) {
    throw JThrown(JError('TypeError', 'Array species must be a constructor'));
  }
  return jNew(constructor, [length.toDouble()]);
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

  for (final mode in ['keys', 'values', 'entries']) {
    add(mode, 0, (object, _) => jBuiltinIterator(object, mode));
  }
  add('join', 1, (object, args) {
    final size = length(object);
    final separator = identical(jArg(args, 0), jUndefined)
        ? ','
        : jString(args[0]);
    return List<String>.generate(size, (index) {
      final item = jGet(object, index);
      return jNullish(item) ? '' : jString(item);
    }).join(separator);
  });
  add('toString', 0, (object, _) {
    final join = jGet(object, 'join');
    return jCall(
      join is JFunction ? join : jObjectPrototype.properties['toString'],
      [],
      receiver: object,
    );
  });
  add('push', 1, (object, args) {
    var size = length(object);
    if (size + args.length > 9007199254740991) {
      throw JThrown(JError('TypeError', 'Array length out of range'));
    }
    for (final value in args) {
      jSet(object, size++, value);
    }
    return jSet(object, 'length', size.toDouble());
  });
  add('pop', 0, (object, _) {
    final size = length(object);
    if (size == 0) {
      jSet(object, 'length', 0.0);
      return jUndefined;
    }
    final index = size - 1;
    final result = jGet(object, index);
    jDelete(object, index, strict: true);
    jSet(object, 'length', index.toDouble());
    return result;
  });
  for (final mode in ['map', 'filter', 'forEach', 'some', 'every']) {
    final creates = mode == 'map' || mode == 'filter';
    add(mode, 1, (object, args) {
      final size = length(object);
      final fn = callback(args);
      final result = creates
          ? jArraySpeciesCreate(object, mode == 'map' ? size : 0)
          : null;
      var output = 0;
      for (var index = 0; index < size; index++) {
        if (!jHasProperty(object, '$index')) continue;
        final value = jGet(object, index);
        final computed = jCall(fn, [
          value,
          index.toDouble(),
          object,
        ], receiver: jArg(args, 1));
        switch (mode) {
          case 'map':
            jCreateDataProperty(result, '$index', computed);
          case 'filter':
            if (jTruthy(computed))
              jCreateDataProperty(result, '${output++}', value);
          case 'some':
            if (jTruthy(computed)) return true;
          case 'every':
            if (!jTruthy(computed)) return false;
        }
      }
      return switch (mode) {
        'some' => false,
        'every' => true,
        'forEach' => jUndefined,
        _ => result,
      };
    });
  }
  for (final mode in ['includes', 'indexOf']) {
    add(mode, 1, (object, args) {
      final size = length(object);
      if (size == 0) return mode == 'includes' ? false : -1.0;
      final start = jRelativeIndex(jArg(args, 1), size);
      for (var i = start; i < size; i++) {
        if (mode == 'indexOf' && !jHasProperty(object, '$i')) continue;
        final item = jGet(object, i);
        if (mode == 'includes'
            ? jSameValue(item, jArg(args, 0), zero: true)
            : jStrictEqual(item, jArg(args, 0))) {
          return mode == 'includes' ? true : i.toDouble();
        }
      }
      return mode == 'includes' ? false : -1.0;
    });
  }
  List<(dynamic, int)> sorted(
    dynamic source,
    int size,
    dynamic comparator, {
    required bool skipHoles,
  }) {
    final indexed = [
      for (var i = 0; i < size; i++)
        if (!skipHoles || jHasProperty(source, '$i')) (jGet(source, i), i),
    ];
    indexed.sort((x, y) {
      final left = x.$1, right = y.$1;
      if (identical(left, jUndefined) || identical(right, jUndefined)) {
        if (identical(left, right)) return x.$2.compareTo(y.$2);
        return identical(left, jUndefined) ? 1 : -1;
      }
      final compared = identical(comparator, jUndefined)
          ? jString(left).compareTo(jString(right))
          : jNumber(jCall(comparator, [left, right]));
      final sign = compared.isNaN ? 0 : compared.sign.toInt();
      return sign == 0 ? x.$2.compareTo(y.$2) : sign;
    });
    return indexed;
  }

  dynamic compareFunction(List<dynamic> args) {
    final comparator = jArg(args, 0);
    if (!identical(comparator, jUndefined) && comparator is! JFunction) {
      throw JThrown(JError('TypeError', 'Comparator is not callable'));
    }
    return comparator;
  }

  add('sort', 1, (object, args) {
    final comparator = compareFunction(args);
    final size = length(object);
    final indexed = sorted(object, size, comparator, skipHoles: true);
    for (var i = 0; i < indexed.length; i++) {
      jSet(object, i, indexed[i].$1);
    }
    for (var i = indexed.length; i < size; i++) {
      jDelete(object, i, strict: true);
    }
    return object;
  });
  add('at', 1, (object, args) {
    final size = length(object);
    final offset = jInteger(jArg(args, 0));
    final index = offset < 0 ? size + offset : offset;
    return index < 0 || index >= size
        ? jUndefined
        : jGet(object, index.toInt());
  });
  add('concat', 1, (object, args) {
    final result = jArraySpeciesCreate(object, 0);
    var index = 0;
    for (final item in [object, ...args]) {
      final spreadable = jIsObject(item)
          ? jGet(item, jSymbols['isConcatSpreadable'])
          : jUndefined;
      final spreads = identical(spreadable, jUndefined)
          ? jIsArray(item)
          : jTruthy(spreadable);
      final count = spreads ? length(item) : 1;
      if (index + count > 9007199254740991) {
        throw JThrown(JError('TypeError', 'Array length out of range'));
      }
      if (!spreads) {
        jCreateDataProperty(result, '${index++}', item);
        continue;
      }
      for (var i = 0; i < count; i++, index++) {
        if (jHasProperty(item, '$i'))
          jCreateDataProperty(result, '$index', jGet(item, i));
      }
    }
    jSet(result, 'length', index.toDouble());
    return result;
  });
  add('slice', 2, (object, args) {
    final size = length(object);
    final start = jRelativeIndex(jArg(args, 0), size);
    final stop = end(args, 1, size);
    final count = math.max(0, stop - start);
    final result = jArraySpeciesCreate(object, count);
    for (var i = 0; i < count; i++) {
      final index = start + i;
      if (jHasProperty(object, '$index'))
        jCreateDataProperty(result, '$i', jGet(object, index));
    }
    jSet(result, 'length', count.toDouble());
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
      final result = jArraySpeciesCreate(object, 0);
      var output = 0;
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
            if (output >= 9007199254740991) {
              throw JThrown(JError('TypeError', 'Array length out of range'));
            }
            jCreateDataProperty(result, '${output++}', value);
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
      final result = jArraySpeciesCreate(object, removed);
      for (var i = 0; i < removed; i++) {
        if (jHasProperty(object, '${start + i}')) {
          jCreateDataProperty(result, '$i', jGet(object, start + i));
        }
      }
      jSet(result, 'length', removed.toDouble());
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
    final comparator = compareFunction(args);
    final size = length(object);
    final indexed = sorted(object, size, comparator, skipHoles: false);
    return <dynamic>[for (final item in indexed) item.$1];
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

JFunction get jArrayConstructor => JRealm.current.arrayConstructor;

JFunction jBuildArrayConstructor() {
  List<dynamic> allocate(List<dynamic> args, JObject prototype) {
    final num? size = args.length == 1 && args.single is num
        ? args.single
        : null;
    if (size != null &&
        (!size.isFinite ||
            size < 0 ||
            size > 4294967295 ||
            size != size.truncate())) {
      throw JThrown(JError('RangeError', 'Invalid array length'));
    }
    final result = size == null
        ? jRealmValue(List<dynamic>.of(args))
        : jCreateArray(size.toInt());
    jArrayProperties(result).prototype = prototype;
    return result;
  }

  final constructor = JFunction(
    (args, _) => allocate(args, jArrayPrototypeObject),
    constructWithTarget: (args, target) => allocate(
      args,
      jPrototypeFromConstructor(target, jArrayPrototypeObject),
    ),
  );
  jNameFunction(constructor, 'Array', 1);
  constructor.properties.addAll({
    'prototype': jArrayPrototypeObject,
    'isArray': jBuiltinMethod(
      'isArray',
      1,
      (args, _) => jIsArray(jArg(args, 0)),
    ),
    'fromAsync': jBuiltinMethod('fromAsync', 1, jArrayFromAsync),
    'from': jBuiltinMethod('from', 1, jArrayFrom),
    'of': jBuiltinMethod('of', 0, (args, receiver) {
      final length = args.length;
      final result = receiver is JFunction && receiver.constructible
          ? jNew(receiver, [length.toDouble()])
          : jCreateArray(length);
      for (var index = 0; index < length; index++) {
        jCreateDataProperty(result, '$index', args[index]);
      }
      jSet(result, 'length', length.toDouble());
      return result;
    }),
  });
  jBuiltinProperties(constructor);
  constructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  jInstallSpeciesGetter(constructor);
  return constructor;
}

dynamic jArrayFrom(List<dynamic> args, dynamic receiver) {
  final input = jArg(args, 0), fn = jArg(args, 1);
  if (!identical(fn, jUndefined) && fn is! JFunction) {
    throw JThrown(JError('TypeError', 'Array.from mapper is not callable'));
  }
  final usingIterator = jGet(input, jSymbols['iterator']);
  final constructible = receiver is JFunction && receiver.constructible;
  dynamic map(dynamic value, int index) => fn is JFunction
      ? jCall(fn, [value, index.toDouble()], receiver: jArg(args, 2))
      : value;
  if (jNullish(usingIterator)) {
    final arrayLike = jObject(input);
    final size = jLength(jGet(arrayLike, 'length'));
    final result = constructible
        ? jNew(receiver, [size.toDouble()])
        : jCreateArray(size);
    for (var index = 0; index < size; index++) {
      jCreateDataProperty(result, '$index', map(jGet(arrayLike, index), index));
    }
    jSet(result, 'length', size.toDouble());
    return result;
  }
  if (usingIterator is! JFunction) {
    throw JThrown(JError('TypeError', 'Iterator method is not callable'));
  }
  final result = constructible ? jNew(receiver, []) : jCreateArray(0);
  final iterator = JIteratorRecord(
    jIteratorObject(jCall(usingIterator, [], receiver: input)),
  );
  var index = 0;
  try {
    while (iterator.advance()) {
      if (index >= 9007199254740991) {
        throw JThrown(JError('TypeError', 'Array length out of range'));
      }
      jCreateDataProperty(result, '$index', map(iterator.current, index));
      index++;
    }
  } catch (_) {
    iterator.close(suppressErrors: true);
    rethrow;
  }
  jSet(result, 'length', index.toDouble());
  return result;
}

String jLocaleElement(dynamic value, List<dynamic> args) =>
    jNullish(value) ? '' : jString(jInvoke(value, 'toLocaleString', args));

JPromise jArrayFromAsync(List<dynamic> args, dynamic receiver) => jAsync((
  promise,
) async {
  try {
    final input = jArg(args, 0), mapper = jArg(args, 1);
    if (!identical(mapper, jUndefined) && mapper is! JFunction) {
      throw JThrown(
        JError('TypeError', 'Array.fromAsync mapper is not callable'),
      );
    }
    final asyncMethod = jGet(input, jSymbols['asyncIterator']);
    final method = jNullish(asyncMethod)
        ? jGet(input, jSymbols['iterator'])
        : asyncMethod;
    final constructible = receiver is JFunction && receiver.constructible;

    dynamic map(dynamic value, int index) =>
        jCall(mapper, [value, index.toDouble()], receiver: jArg(args, 2));

    if (jNullish(method)) {
      final arrayLike = jObject(input);
      final size = jLength(jGet(arrayLike, 'length'));
      final target = constructible
          ? jNew(receiver, [size.toDouble()])
          : jCreateArray(size);
      for (var index = 0; index < size; index++) {
        final value = await jAwait(jGet(arrayLike, index));
        jCreateDataProperty(
          target,
          '$index',
          mapper is JFunction ? await jAwait(map(value, index)) : value,
        );
      }
      jSet(target, 'length', size.toDouble());
      promise.resolve(target);
      return;
    }

    final iteratorObject = jIteratorObject(jCall(method, [], receiver: input));
    final iterator = JAsyncIteratorRecord(
      iteratorObject,
      jNullish(asyncMethod),
    );
    final target = constructible ? jNew(receiver, []) : jCreateArray(0);
    var index = 0;
    while (true) {
      if (index >= 9007199254740991) {
        await jAwait(iterator.close(suppressErrors: true));
        throw JThrown(JError('TypeError', 'Array length out of range'));
      }
      if ((await jAwait(iterator.advance(readCompletionValue: false))) != true)
        break;
      try {
        final value = iterator.current;
        jCreateDataProperty(
          target,
          '$index',
          mapper is JFunction ? await jAwait(map(value, index)) : value,
        );
      } catch (_) {
        await jAwait(iterator.close(suppressErrors: true));
        rethrow;
      }
      index++;
    }
    jSet(target, 'length', index.toDouble());
    promise.resolve(target);
  } catch (error) {
    promise.reject(jExceptionValue(error));
  }
});
