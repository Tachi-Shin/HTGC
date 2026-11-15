// HTGC JavaScript semantics implemented in Dart. No JavaScript engine or eval.
import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'dart:collection';

class JUndefined {
  const JUndefined();
}

const jUndefined = JUndefined();

class JThrown implements Exception {
  final dynamic value;
  JThrown(this.value);
  @override
  String toString() => 'Uncaught JavaScript exception: ${jString(value)}';
}

// Abrupt return completion, distinct from values thrown by JavaScript.
class JAsyncReturn implements Exception {
  final dynamic value;
  JAsyncReturn(this.value);
}

dynamic jExceptionValue(Object error) => error is JThrown ? error.value : error;

class JError extends JObject {
  JError(String name, String message, {List<dynamic>? errors})
    : super({
        'name': name,
        'message': message,
        if (errors != null) 'errors': errors,
      }) {
    prototype = jErrorPrototypes.putIfAbsent(name, () => JObject());
    jBuiltinProperties(this);
  }
}

final Map<String, JObject> jErrorPrototypes = {};

class JPromise extends JObject {
  int _state = 0; // pending, fulfilled, rejected
  dynamic _value = jUndefined;
  bool _resolved = false;
  bool _handled = false;
  final Zone _zone = Zone.current;
  final _reactions = <void Function()>[];
  JPromise() {
    prototype = jPromisePrototype;
  }

  void _settle(int state, dynamic value) {
    if (_state != 0) return;
    _state = state;
    _value = value;
    if (state == 2 && !_handled) {
      Timer.run(() {
        if (!_handled)
          _zone.handleUncaughtError(JThrown(value), StackTrace.current);
      });
    }
    for (final reaction in _reactions) {
      scheduleMicrotask(reaction);
    }
    _reactions.clear();
  }

  void reject(dynamic reason) {
    if (_resolved) return;
    _resolved = true;
    _settle(2, reason);
  }

  void resolve(dynamic value) {
    if (_resolved) return;
    _resolved = true;
    _adopt(value);
  }

  void _adopt(dynamic value) {
    if (identical(value, this)) {
      _settle(2, JError('TypeError', 'A promise cannot resolve itself'));
      return;
    }
    dynamic then;
    try {
      then = jNullish(value) ? jUndefined : jGet(value, 'then');
    } catch (error) {
      _settle(2, jExceptionValue(error));
      return;
    }
    if (then is! JFunction) {
      _settle(1, value);
      return;
    }
    // Reading then is synchronous; calling it is a separate Promise job.
    scheduleMicrotask(() {
      var called = false;
      try {
        jCall(then, [
          jNative((args) {
            if (!called) {
              called = true;
              _adopt(jArg(args, 0));
            }
            return jUndefined;
          }),
          jNative((args) {
            if (!called) {
              called = true;
              _settle(2, jArg(args, 0));
            }
            return jUndefined;
          }),
        ], receiver: value);
      } catch (error) {
        if (!called) {
          called = true;
          _settle(2, jExceptionValue(error));
        }
      }
    });
  }

  void observe(
    void Function(dynamic) fulfilled,
    void Function(dynamic) rejected,
  ) {
    _handled = true;
    void reaction() => _state == 1 ? fulfilled(_value) : rejected(_value);
    if (_state == 0) {
      _reactions.add(reaction);
    } else {
      scheduleMicrotask(reaction);
    }
  }

  JPromise then(dynamic fulfilled, [dynamic rejected = jUndefined]) {
    final next = JPromise();
    void reaction(dynamic handler, dynamic value, bool failure) {
      try {
        if (handler is JFunction) {
          next.resolve(jCall(handler, [value]));
        } else if (failure) {
          next.reject(value);
        } else {
          next.resolve(value);
        }
      } catch (error) {
        next.reject(jExceptionValue(error));
      }
    }

    observe(
      (value) => reaction(fulfilled, value, false),
      (error) => reaction(rejected, error, true),
    );
    return next;
  }
}

final JObject jPromisePrototype = JObject({
  'constructor': jPromiseConstructor,
  'then': JFunction((a, receiver) {
    if (receiver is! JPromise)
      throw JThrown(JError('TypeError', 'Not a Promise receiver'));
    return receiver.then(jArg(a, 0), jArg(a, 1));
  }, constructible: false),
  'catch': JFunction(
    (a, receiver) => jInvoke(receiver, 'then', [jUndefined, jArg(a, 0)]),
    constructible: false,
  ),
  'finally': JFunction((a, receiver) {
    final callback = jArg(a, 0);
    if (callback is! JFunction)
      return jInvoke(receiver, 'then', [callback, callback]);
    return jInvoke(receiver, 'then', [
      jNative(
        (values) =>
            jPromiseResolve(jCall(callback, []))
                .then(jNative((_) => values[0])),
      ),
      jNative(
        (errors) =>
            jPromiseResolve(jCall(callback, []))
                .then(jNative((_) => throw JThrown(errors[0]))),
      ),
    ]);
  }, constructible: false),
});

JPromise jPromiseResolve(dynamic value) {
  if (value is JPromise &&
      identical(value.get('constructor'), jPromiseConstructor))
    return value;
  return JPromise()..resolve(value);
}

Future<dynamic> jAwait(dynamic value) {
  // Complete inside the Promise reaction, avoiding an extra Future job.
  final completion = Completer<dynamic>.sync();
  jPromiseResolve(value).observe(
    completion.complete,
    (error) => completion.completeError(JThrown(error)),
  );
  return completion.future;
}

JPromise jAsync(Future<void> Function(JPromise) body) {
  final promise = JPromise();
  // Generated bodies handle return/throw completions before completing this Future.
  body(promise);
  return promise;
}

JPromise jPromiseAggregate(String mode, dynamic iterable) {
  final result = JPromise();
  final values = <dynamic>[];
  var remaining = 1;
  void finish() {
    if (--remaining != 0 || mode == 'race') return;
    if (mode == 'any') {
      result.reject(
        JError('AggregateError', 'All promises were rejected', errors: values),
      );
    } else {
      result.resolve(values);
    }
  }

  try {
    jForEachIterable(iterable, (value) {
      final index = values.length;
      values.add(jUndefined);
      remaining++;
      var called = false;
      final next = jInvoke(jPromiseConstructor, 'resolve', [value]);
      jInvoke(next, 'then', [
        jNative((args) {
          final resolved = jArg(args, 0);
          if (mode == 'race' || mode == 'any') {
            result.resolve(resolved);
          } else if (!called) {
            called = true;
            values[index] = mode == 'allSettled'
                ? JObject({'status': 'fulfilled', 'value': resolved})
                : resolved;
            finish();
          }
          return jUndefined;
        }),
        jNative((args) {
          final error = jArg(args, 0);
          if (mode == 'race' || mode == 'all') {
            result.reject(error);
          } else if (!called) {
            called = true;
            values[index] = mode == 'allSettled'
                ? JObject({'status': 'rejected', 'reason': error})
                : error;
            finish();
          }
          return jUndefined;
        }),
      ]);
    });
    finish();
  } catch (error) {
    result.reject(jExceptionValue(error));
  }
  return result;
}

final JFunction jPromiseConstructor = buildJSPromiseConstructor();

JFunction buildJSPromiseConstructor() {
  final constructor = JFunction(
    (a, receiver) => throw JThrown(JError('TypeError', 'Promise requires new')),
    construct: (a) {
      final executor = jArg(a, 0);
      if (executor is! JFunction)
        throw JThrown(JError('TypeError', 'Promise executor is not callable'));
      final promise = JPromise();
      try {
        jCall(executor, [
          jNative((values) {
            promise.resolve(jArg(values, 0));
            return jUndefined;
          }),
          jNative((errors) {
            promise.reject(jArg(errors, 0));
            return jUndefined;
          }),
        ]);
      } catch (error) {
        promise.reject(jExceptionValue(error));
      }
      return promise;
    },
  );
  constructor.properties.addAll({
    'resolve': jNative((a) => jPromiseResolve(jArg(a, 0))),
    'reject': jNative((a) => JPromise()..reject(jArg(a, 0))),
    for (final mode in ['all', 'allSettled', 'any', 'race'])
      mode: jNative((a) => jPromiseAggregate(mode, jArg(a, 0))),
    'withResolvers': jNative((_) {
      final promise = JPromise();
      return JObject({
        'promise': promise,
        'resolve': jNative((a) {
          promise.resolve(jArg(a, 0));
          return jUndefined;
        }),
        'reject': jNative((a) {
          promise.reject(jArg(a, 0));
          return jUndefined;
        }),
      });
    }),
    'try': jNative((a) {
      final promise = JPromise();
      try {
        promise.resolve(jCall(jArg(a, 0), a.skip(1).toList()));
      } catch (error) {
        promise.reject(jExceptionValue(error));
      }
      return promise;
    }),
  });
  return constructor;
}

void installJSPromises(JScope scope) {
  // Lazily linked to avoid recursive initialization of constructor/prototype.
  jPromiseConstructor.properties['prototype'] = jPromisePrototype;
  scope.define('Promise', jPromiseConstructor);
}

class JAssignment {
  final JRef reference;
  final String operator;
  late final dynamic left = operator == '=' ? jUndefined : reference.read();
  JAssignment(this.reference, this.operator) {
    left;
  }
  bool get skip =>
      operator == '||=' && jTruthy(left) ||
      operator == '&&=' && !jTruthy(left) ||
      operator == '??=' && !jNullish(left);
  dynamic assign(dynamic value) => reference.write(
    ['=', '||=', '&&=', '??='].contains(operator)
        ? value
        : jBinary(operator.substring(0, operator.length - 1), left, value),
  );
}

class JShortCircuit {
  const JShortCircuit();
}

const jShortCircuit = JShortCircuit();
const _jUninitialized = Object();
bool jNullish(dynamic value) => value == null || identical(value, jUndefined);
dynamic jEndChain(dynamic value) =>
    identical(value, jShortCircuit) ? jUndefined : value;
dynamic jArg(List<dynamic> args, int i) =>
    i < args.length ? args[i] : jUndefined;
dynamic jDefault(dynamic value, dynamic Function() fallback) =>
    identical(value, jUndefined) ? fallback() : value;

class JScope {
  final JScope? parent;
  final Map<String, dynamic> _values = {};
  final Set<String> _constants = {};
  final Map<String, dynamic Function()> _imports = {};
  JModuleGraph? _modules;
  JScope([this.parent]);
  JModuleGraph modules(Map<String, JModuleDefinition> definitions) =>
      parent?.modules(definitions) ??
      (_modules ??= JModuleGraph(this, definitions));

  void reserve(String name) {
    _values[name] = _jUninitialized;
  }

  void importBinding(String name, dynamic Function() read) {
    _imports[name] = read;
  }

  void declareVar(String name) {
    _values.putIfAbsent(name, () => jUndefined);
  }

  dynamic define(String name, dynamic value, {bool constant = false}) {
    if (_values.containsKey(name) && !identical(_values[name], _jUninitialized))
      throw StateError('Identifier already declared: $name');
    _values[name] = value;
    if (constant) _constants.add(name);
    return value;
  }

  dynamic get(String name) {
    if (_values.containsKey(name)) {
      final value = _values[name];
      if (identical(value, _jUninitialized)) {
        throw StateError('JavaScript ReferenceError: $name is not initialized');
      }
      return value;
    }
    final read = _imports[name];
    if (read != null) return read();
    if (parent != null) return parent!.get(name);
    if (name == 'undefined') return jUndefined;
    if (name == 'NaN') return double.nan;
    if (name == 'Infinity') return double.infinity;
    throw StateError('JavaScript ReferenceError: $name');
  }

  dynamic put(String name, dynamic value) {
    if (_values.containsKey(name)) {
      if (identical(_values[name], _jUninitialized)) {
        throw StateError('JavaScript ReferenceError: $name is not initialized');
      }
      if (_constants.contains(name))
        throw StateError('Assignment to constant: $name');
      return _values[name] = value;
    }
    if (_imports.containsKey(name))
      throw StateError('Assignment to import: $name');
    if (parent != null) return parent!.put(name, value);
    throw StateError('Assignment to undeclared name: $name');
  }
}

class JSymbol {
  final String? description;
  final bool registered;
  JSymbol(this.description, {this.registered = false});
  String get descriptive => 'Symbol(${description ?? ''})';
}

final jSymbols = <String, JSymbol>{
  for (final name in [
    'iterator',
    'asyncIterator',
    'toStringTag',
    'toPrimitive',
    'species',
    'hasInstance',
    'isConcatSpreadable',
    'match',
    'matchAll',
    'replace',
    'search',
    'split',
    'unscopables',
    'dispose',
    'asyncDispose',
  ])
    name: JSymbol('Symbol.$name'),
};
final _jSymbolRegistry = <String, JSymbol>{};
Object jPropertyKey(dynamic value) {
  final primitive = jPrimitive(value, hint: 'string');
  return primitive is JSymbol ? primitive : jString(primitive);
}

dynamic jPrimitive(dynamic value, {String hint = 'default'}) {
  if (value is! JObject && value is! List) return value;
  final exotic = jGet(value, jSymbols['toPrimitive']);
  if (!jNullish(exotic)) {
    final result = jCall(exotic, [hint], receiver: value);
    if (result is JObject || result is List)
      throw JThrown(JError('TypeError', 'Cannot convert object to primitive'));
    return result;
  }
  for (final key
      in hint == 'string' ? ['toString', 'valueOf'] : ['valueOf', 'toString']) {
    final method = jGet(value, key);
    if (method is JFunction) {
      final result = jCall(method, [], receiver: value);
      if (result is! JObject && result is! List) return result;
    }
  }
  throw JThrown(JError('TypeError', 'Cannot convert object to primitive'));
}

class JPropertyFlags {
  bool writable, enumerable, configurable;
  JPropertyFlags({
    this.writable = true,
    this.enumerable = true,
    this.configurable = true,
  });
}

class JObject {
  final Map<String, dynamic> properties;
  final Map<JSymbol, dynamic> symbols = {};
  final Map<Object, JFunction> getters = {}, setters = {};
  final Map<Object, JPropertyFlags> flags = {};
  bool extensible = true;
  JObject? _prototype;
  bool _nullPrototype;
  JObject([Map<String, dynamic>? properties])
    : properties = properties ?? {},
      _nullPrototype = false;
  JObject.root([Map<String, dynamic>? properties])
    : properties = properties ?? {},
      _nullPrototype = true;
  JObject? get prototype =>
      _prototype ?? (_nullPrototype ? null : jObjectPrototype);
  set prototype(JObject? value) {
    _prototype = value;
    _nullPrototype = value == null;
  }

  bool own(Object key) =>
      key is JSymbol ? symbols.containsKey(key) : properties.containsKey(key);
  bool accessor(Object key) =>
      getters.containsKey(key) ||
      setters.containsKey(key) ||
      _accessors.contains(key);
  final Set<Object> _accessors = {};
  dynamic raw(Object key) => key is JSymbol ? symbols[key] : properties[key];
  void store(Object key, dynamic value) {
    if (key is JSymbol) {
      symbols[key] = value;
    } else {
      properties[key as String] = value;
    }
  }

  dynamic read(Object key, dynamic receiver) {
    if (own(key)) {
      if (accessor(key)) {
        final getter = getters[key];
        return getter == null
            ? jUndefined
            : jCall(getter, [], receiver: receiver);
      }
      return raw(key);
    }
    return prototype == null ? jUndefined : prototype!.read(key, receiver);
  }

  dynamic get(String name) => read(name, this);
  dynamic set(String name, dynamic value) {
    if (!write(name, value, this))
      throw JThrown(JError('TypeError', 'Cannot assign property $name'));
    return value;
  }

  bool write(Object key, dynamic value, dynamic receiver) {
    if (!own(key) && prototype != null)
      return prototype!.write(key, value, receiver);
    if (own(key) && accessor(key)) {
      final setter = setters[key];
      if (setter == null) return false;
      jCall(setter, [value], receiver: receiver);
      return true;
    }
    if (own(key) && !(flags[key]?.writable ?? true) || receiver is! JObject)
      return false;
    if (receiver.own(key)) {
      if (receiver.accessor(key) || !(receiver.flags[key]?.writable ?? true))
        return false;
    } else if (!receiver.extensible) {
      return false;
    }
    receiver.store(key, value);
    return true;
  }

  bool remove(Object key) {
    if (!own(key)) return true;
    if (!(flags[key]?.configurable ?? true)) return false;
    if (key is JSymbol) {
      symbols.remove(key);
    } else {
      properties.remove(key);
    }
    getters.remove(key);
    setters.remove(key);
    flags.remove(key);
    _accessors.remove(key);
    return true;
  }
}

bool jSameValue(dynamic a, dynamic b, {bool zero = false}) {
  if (a is num && b is num) {
    if (a.isNaN && b.isNaN) return true;
    if (!zero && a == 0 && b == 0) return 1 / a == 1 / b;
    return a == b;
  }
  return a.runtimeType == b.runtimeType && a == b;
}

List<Object> jOwnKeys(
  dynamic value, {
  bool enumerable = false,
  bool strings = false,
}) {
  if (jNullish(value))
    throw JThrown(
      JError('TypeError', 'Cannot convert null or undefined to object'),
    );
  if (value is JModuleNamespace)
    return value.exports.keys.cast<Object>().toList();
  if (value is List || value is String)
    return [
      for (var i = 0; i < value.length; i++)
        if (value is! List || !identical(value[i], _jHole)) '$i',
      if (!enumerable) 'length',
    ];
  if (value is! JObject) return [];
  final indices = <int>[];
  final names = <Object>[];
  for (final key in value.properties.keys) {
    if (enumerable && !(value.flags[key]?.enumerable ?? true)) continue;
    final index = int.tryParse(key);
    if (index != null && index >= 0 && index < 4294967295 && '$index' == key) {
      indices.add(index);
    } else {
      names.add(key);
    }
  }
  indices.sort();
  return [
    for (final i in indices) '$i',
    ...names,
    if (!strings)
      for (final key in value.symbols.keys)
        if (!enumerable || (value.flags[key]?.enumerable ?? true)) key,
  ];
}

bool jHasOwn(dynamic object, Object key) {
  if (jNullish(object))
    throw JThrown(
      JError('TypeError', 'Cannot convert null or undefined to object'),
    );
  if (object is JModuleNamespace) return object.exports.containsKey(key);
  if (object is JObject) return object.own(key);
  if (object is List || object is String) {
    if (key == 'length') return true;
    final index = int.tryParse(key is String ? key : '');
    return index != null &&
        index >= 0 &&
        index < object.length &&
        '$index' == key &&
        (object is! List || !identical(object[index], _jHole));
  }
  return false;
}

bool jHasProperty(dynamic object, Object key) {
  if (jHasOwn(object, key)) return true;
  if (object is JObject)
    return object.prototype != null && jHasProperty(object.prototype, key);
  return !identical(jGet(object, key), jUndefined);
}

JObject jRequireObject(dynamic value) {
  if (value is! JObject)
    throw JThrown(JError('TypeError', 'An object is required'));
  return value;
}

JObject jNormalizeDescriptor(dynamic descriptor) {
  if (descriptor is! JObject && descriptor is! List)
    throw JThrown(JError('TypeError', 'Property descriptor must be an object'));
  final result = JObject.root();
  // ToPropertyDescriptor observes each field once, in specification order.
  for (final name in [
    'enumerable',
    'configurable',
    'value',
    'writable',
    'get',
    'set',
  ]) {
    if (!jHasProperty(descriptor, name)) continue;
    var value = jGet(descriptor, name);
    if (['enumerable', 'configurable', 'writable'].contains(name))
      value = jTruthy(value);
    if ((name == 'get' || name == 'set') &&
        !identical(value, jUndefined) &&
        value is! JFunction)
      throw JThrown(JError('TypeError', 'Accessor is not callable'));
    result.properties[name] = value;
  }
  if ((result.own('get') || result.own('set')) &&
      (result.own('value') || result.own('writable')))
    throw JThrown(JError('TypeError', 'Mixed property descriptor'));
  return result;
}

bool jDefineProperty(
  JObject object,
  Object key,
  dynamic input, {
  bool normalized = false,
}) {
  final descriptor = normalized
      ? input as JObject
      : jNormalizeDescriptor(input);
  bool has(String name) => descriptor.own(name);
  dynamic field(String name) => descriptor.raw(name);
  final hasGet = has('get'), hasSet = has('set');
  final isAccessor = hasGet || hasSet, isData = has('value') || has('writable');
  final exists = object.own(key), oldAccessor = object.accessor(key);
  if (!exists && !object.extensible) return false;
  final old = object.flags[key] ?? JPropertyFlags();
  if (exists && !old.configurable) {
    if (has('configurable') && jTruthy(field('configurable')) ||
        has('enumerable') && jTruthy(field('enumerable')) != old.enumerable)
      return false;
    if ((isAccessor || isData) && isAccessor != oldAccessor) return false;
    if (oldAccessor) {
      if (hasGet &&
              !jSameValue(field('get'), object.getters[key] ?? jUndefined) ||
          hasSet &&
              !jSameValue(field('set'), object.setters[key] ?? jUndefined))
        return false;
    } else if (!old.writable &&
        (has('writable') && jTruthy(field('writable')) ||
            has('value') && !jSameValue(field('value'), object.raw(key)))) {
      return false;
    }
  }
  final attributes = exists
      ? old
      : JPropertyFlags(writable: false, enumerable: false, configurable: false);
  object.flags[key] = attributes;
  if (has('enumerable')) attributes.enumerable = jTruthy(field('enumerable'));
  if (has('configurable'))
    attributes.configurable = jTruthy(field('configurable'));
  if (!exists || (isAccessor || isData) && isAccessor != oldAccessor) {
    object.store(key, jUndefined);
    object.getters.remove(key);
    object.setters.remove(key);
    object._accessors.remove(key);
    attributes.writable = false;
  }
  if (isAccessor || exists && oldAccessor && !isData) {
    object._accessors.add(key);
    if (hasGet) {
      object.getters.remove(key);
      if (field('get') is JFunction) object.getters[key] = field('get');
    }
    if (hasSet) {
      object.setters.remove(key);
      if (field('set') is JFunction) object.setters[key] = field('set');
    }
  } else {
    if (has('value')) object.store(key, field('value'));
    if (has('writable')) attributes.writable = jTruthy(field('writable'));
  }
  return true;
}

dynamic jDescriptor(dynamic value, Object key) {
  if (!jHasOwn(value, key)) return jUndefined;
  if (value is! JObject)
    return JObject({
      'value': jGet(value, key),
      'writable': value is List,
      'enumerable': key != 'length',
      'configurable': key != 'length',
    });
  final f = value.flags[key] ?? JPropertyFlags();
  return JObject({
    'enumerable': f.enumerable,
    'configurable': f.configurable,
    if (value.accessor(key)) ...{
      'get': value.getters[key] ?? jUndefined,
      'set': value.setters[key] ?? jUndefined,
    } else ...{
      'value': value.raw(key),
      'writable': f.writable,
    },
  });
}

bool jSetPrototype(JObject object, dynamic prototype) {
  if (prototype != null && prototype is! JObject)
    throw JThrown(JError('TypeError', 'Invalid prototype'));
  if (identical(object.prototype, prototype)) return true;
  if (!object.extensible) return false;
  for (JObject? cursor = prototype; cursor != null; cursor = cursor.prototype) {
    if (identical(cursor, object)) return false;
  }
  object.prototype = prototype;
  return true;
}

final JObject jObjectPrototype = JObject.root({
  'hasOwnProperty': JFunction(
    (a, receiver) => jHasOwn(receiver, jPropertyKey(jArg(a, 0))),
    constructible: false,
  ),
  'propertyIsEnumerable': JFunction((a, receiver) {
    final key = jPropertyKey(jArg(a, 0));
    return jHasOwn(receiver, key) &&
        jGet(jDescriptor(receiver, key), 'enumerable') == true;
  }, constructible: false),
  'isPrototypeOf': JFunction((a, receiver) {
    var current = jArg(a, 0);
    while (current is JObject && current.prototype != null) {
      current = current.prototype;
      if (identical(current, receiver)) return true;
    }
    return false;
  }, constructible: false),
  'valueOf': JFunction(
    (a, receiver) => receiver is JBox ? receiver.value : receiver,
    constructible: false,
  ),
  'toString': JFunction((a, receiver) {
    if (receiver == null) return '[object Null]';
    if (identical(receiver, jUndefined)) return '[object Undefined]';
    final tag = jGet(receiver, jSymbols['toStringTag']);
    return '[object ${tag is String
        ? tag
        : receiver is List
        ? 'Array'
        : receiver is JFunction
        ? 'Function'
        : 'Object'}]';
  }, constructible: false),
});

typedef JObjectEntry = (String, Object, dynamic);
JObject jObjectLiteral(List<JObjectEntry> entries) {
  final object = JObject();
  for (final (kind, key, value) in entries) {
    if (kind == 'get' || kind == 'set') {
      if (!object.accessor(key)) {
        object.getters.remove(key);
        object.setters.remove(key);
      }
      object.store(key, jUndefined);
      object._accessors.add(key);
      (kind == 'get' ? object.getters : object.setters)[key] =
          value as JFunction;
    } else if (kind == 'prototype') {
      if (value == null || value is JObject) object.prototype = value;
    } else {
      object.getters.remove(key);
      object.setters.remove(key);
      object._accessors.remove(key);
      object.store(key, value);
    }
  }
  return object;
}

Iterable<JObjectEntry> jObjectSpread(dynamic value) sync* {
  if (jNullish(value)) return;
  for (final key in jOwnKeys(value)) {
    if (jEnumerable(value, key)) yield ('init', key, jGet(value, key));
  }
}

dynamic jRequireCoercible(dynamic value) {
  if (jNullish(value))
    throw JThrown(JError('TypeError', 'Cannot destructure null or undefined'));
  return value;
}

bool jEnumerable(dynamic value, Object key) =>
    jHasOwn(value, key) && jGet(jDescriptor(value, key), 'enumerable') == true;

JObject jCopyProperties(dynamic value, {List<Object> excluding = const []}) {
  final result = JObject();
  for (final key in jOwnKeys(value)) {
    if (!excluding.contains(key) && jEnumerable(value, key))
      result.store(key, jGet(value, key));
  }
  return result;
}

class JCallSite {
  final dynamic function, receiver;
  final bool skipped;
  JCallSite(this.function, {this.receiver = jUndefined, bool optional = false})
    : skipped =
          identical(function, jShortCircuit) || optional && jNullish(function);
  factory JCallSite.member(
    dynamic object,
    dynamic key, {
    bool optionalObject = false,
    bool optionalCall = false,
  }) => JCallSite(
    jGet(object, key, optional: optionalObject),
    receiver: object,
    optional: optionalCall,
  );
  dynamic call(List<dynamic> args) => jCall(function, args, receiver: receiver);
}

typedef JModuleBinding = (String, String?);

class JModuleDefinition {
  final List<String> dependencies;
  final Map<String, JModuleBinding> imports, exports;
  final void Function(JScope) initialize;
  final dynamic Function(JScope) execute;
  final bool hasAwait;
  const JModuleDefinition(
    this.dependencies,
    this.imports,
    this.exports,
    this.initialize,
    this.execute, {
    this.hasAwait = false,
  });
}

class JModuleNamespace extends JObject {
  final JModuleGraph graph;
  final Map<String, JModuleBinding> exports;
  JModuleNamespace(this.graph, this.exports) {
    prototype = null;
    extensible = false;
  }
  @override
  dynamic get(String name) {
    final binding = exports[name];
    return binding == null ? jUndefined : graph.read(binding);
  }

  @override
  dynamic set(String name, dynamic value) => throw JThrown(
    JError('TypeError', 'Assignment to module namespace: $name'),
  );
}

enum JModuleStatus { linked, evaluating, evaluatingAsync, evaluated }

class JModuleState {
  final JScope scope;
  final JModuleDefinition definition;
  JModuleStatus status = JModuleStatus.linked;
  int index = 0, ancestor = 0, pending = 0;
  int? asyncOrder;
  JModuleState? cycleRoot;
  JPromise? completion;
  bool failed = false;
  dynamic error = jUndefined;
  final parents = <JModuleState>[];
  JModuleState(this.scope, this.definition);
}

class JModuleGraph {
  final JScope globals;
  final Map<String, JModuleDefinition> definitions;
  final _states = <String, JModuleState>{};
  final _namespaces = <String, JModuleNamespace>{};
  int _asyncOrder = 0;
  JModuleGraph(this.globals, this.definitions);

  dynamic read(JModuleBinding binding) {
    final (module, name) = binding;
    if (name != null) return _states[module]!.scope.get(name);
    return _namespaces.putIfAbsent(
      module,
      () => JModuleNamespace(this, definitions[module]!.exports),
    );
  }

  JModuleState _link(String key) {
    final existing = _states[key];
    if (existing != null) return existing;
    final definition = definitions[key];
    if (definition == null)
      throw JThrown(JError('TypeError', 'Module is not compiled: $key'));
    final module = _states[key] = JModuleState(JScope(globals), definition);
    for (final entry in definition.imports.entries) {
      module.scope.importBinding(entry.key, () => read(entry.value));
    }
    definition.initialize(module.scope);
    for (final dependency in definition.dependencies) {
      _link(dependency);
    }
    return module;
  }

  JPromise importModule(String owner, dynamic specifier) {
    final result = JPromise();
    String key;
    try {
      final text = jString(specifier);
      final uri = Uri.parse(text);
      if (!(text.startsWith('./') ||
              text.startsWith('../') ||
              text.startsWith('/')) ||
          uri.hasScheme ||
          uri.hasAuthority ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw JThrown(
          JError('TypeError', 'Unsupported module specifier: $text'),
        );
      }
      final base = Uri(scheme: 'htgc', host: 'local', path: '/$owner');
      key = base.resolveUri(uri).path.substring(1);
    } catch (error) {
      result.reject(jExceptionValue(error));
      return result;
    }
    // Host loading is asynchronous even when source is already compiled.
    scheduleMicrotask(() {
      evaluate(key)
          .observe((_) => result.resolve(read((key, null))), result.reject);
    });
    return result;
  }

  JPromise evaluate(String key) {
    final stack = <JModuleState>[];
    JModuleState module;
    try {
      module = _link(key);
    } catch (error) {
      return JPromise()..reject(jExceptionValue(error));
    }
    if (module.status == JModuleStatus.evaluatingAsync ||
        module.status == JModuleStatus.evaluated) {
      module = module.cycleRoot ?? module;
    }
    if (module.completion != null) return module.completion!;
    final promise = module.completion = JPromise();
    try {
      _evaluate(module, stack, 0);
      if (module.status == JModuleStatus.evaluated) promise.resolve(jUndefined);
    } catch (error) {
      final reason = jExceptionValue(error);
      for (final pending in stack) {
        pending.status = JModuleStatus.evaluated;
        pending.failed = true;
        pending.error = reason;
        pending.completion?.reject(reason);
      }
      promise.reject(reason);
    }
    return promise;
  }

  int _evaluate(JModuleState module, List<JModuleState> stack, int index) {
    if (module.status == JModuleStatus.evaluated ||
        module.status == JModuleStatus.evaluatingAsync) {
      if (module.failed) throw JThrown(module.error);
      return index;
    }
    if (module.status == JModuleStatus.evaluating) return index;
    module.status = JModuleStatus.evaluating;
    module.index = module.ancestor = index++;
    stack.add(module);
    for (final key in module.definition.dependencies) {
      var dependency = _states[key]!;
      index = _evaluate(dependency, stack, index);
      if (dependency.status == JModuleStatus.evaluating) {
        module.ancestor = math.min(module.ancestor, dependency.ancestor);
      } else {
        dependency = dependency.cycleRoot ?? dependency;
        if (dependency.failed) throw JThrown(dependency.error);
      }
      if (dependency.asyncOrder != null) {
        module.pending++;
        dependency.parents.add(module);
      }
    }
    if (module.definition.hasAwait || module.pending > 0) {
      module.asyncOrder = _asyncOrder++;
      if (module.pending == 0) _executeAsync(module);
    } else {
      module.definition.execute(module.scope);
    }
    if (module.ancestor == module.index) {
      JModuleState member;
      do {
        member = stack.removeLast();
        member.status = member.asyncOrder == null
            ? JModuleStatus.evaluated
            : JModuleStatus.evaluatingAsync;
        member.cycleRoot = module;
      } while (!identical(member, module));
    }
    return index;
  }

  void _executeAsync(JModuleState module) {
    final promise = module.definition.execute(module.scope) as JPromise;
    promise.observe(
      (_) => _fulfilled(module),
      (error) => _rejected(module, error),
    );
  }

  void _finish(JModuleState module) {
    module.status = JModuleStatus.evaluated;
    module.asyncOrder = null;
    module.completion?.resolve(jUndefined);
  }

  void _available(JModuleState module, List<JModuleState> ready) {
    for (final parent in module.parents) {
      if (ready.contains(parent) || (parent.cycleRoot ?? parent).failed)
        continue;
      if (--parent.pending == 0) {
        ready.add(parent);
        if (!parent.definition.hasAwait) _available(parent, ready);
      }
    }
  }

  void _fulfilled(JModuleState module) {
    if (module.status == JModuleStatus.evaluated) return;
    _finish(module);
    final ready = <JModuleState>[];
    _available(module, ready);
    ready.sort((a, b) => a.asyncOrder!.compareTo(b.asyncOrder!));
    for (final ancestor in ready) {
      if (ancestor.status == JModuleStatus.evaluated) continue;
      if (ancestor.definition.hasAwait) {
        _executeAsync(ancestor);
      } else {
        try {
          ancestor.definition.execute(ancestor.scope);
          _finish(ancestor);
        } catch (error) {
          _rejected(ancestor, jExceptionValue(error));
        }
      }
    }
  }

  void _rejected(JModuleState module, dynamic error) {
    if (module.status == JModuleStatus.evaluated) return;
    module.status = JModuleStatus.evaluated;
    module.asyncOrder = null;
    module.failed = true;
    module.error = error;
    module.completion?.reject(error);
    for (final parent in module.parents) {
      _rejected(parent, error);
    }
  }
}

class JFunction extends JObject {
  final dynamic Function(List<dynamic>, dynamic) invoke;
  final dynamic Function(List<dynamic>)? construct;
  final bool constructible;
  JFunction(this.invoke, {this.construct, this.constructible = true});
  @override
  dynamic get(String name) {
    if (properties.containsKey(name)) return super.get(name);
    if (name == 'call')
      return jNative(
        (a) => jCall(this, a.skip(1).toList(), receiver: jArg(a, 0)),
      );
    if (name == 'apply')
      return jNative(
        (a) => jCall(
          this,
          jNullish(jArg(a, 1)) ? [] : jArrayLikeList(a[1]),
          receiver: jArg(a, 0),
        ),
      );
    return super.get(name);
  }
}

JFunction jNative(dynamic Function(List<dynamic>) callback) =>
    JFunction((args, receiver) => callback(args));

class JClass extends JObject {
  final dynamic base;
  final Map<String, dynamic> methods;
  JClass(this.base, this.methods);
  void attach(JObject instance) {
    if (base is JClass) (base as JClass).attach(instance);
    instance.properties.addAll(methods);
  }
}

class JRegex {
  final String pattern, flags;
  late final RegExp value = RegExp(
    pattern,
    caseSensitive: !flags.contains('i'),
    multiLine: flags.contains('m'),
    dotAll: flags.contains('s'),
    unicode: flags.contains('u'),
  );
  JRegex(this.pattern, this.flags);
}

class JRef {
  final dynamic Function() read;
  final dynamic Function(dynamic) write;
  JRef(this.read, this.write);
  factory JRef.scope(JScope scope, String key) =>
      JRef(() => scope.get(key), (v) => scope.put(key, v));
  factory JRef.member(dynamic object, dynamic key) =>
      JRef(() => jGet(object, key), (v) => jSet(object, key, v));
}

bool jTruthy(dynamic v) {
  if (jNullish(v) || identical(v, jShortCircuit)) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

String jString(dynamic v) {
  if (identical(v, jUndefined)) return 'undefined';
  if (v == null) return 'null';
  if (v is JBox) return jString(v.value);
  if (v is String) return v;
  if (v is JSymbol)
    throw JThrown(JError('TypeError', 'Cannot convert a Symbol to a string'));
  if (v is List)
    return [
      for (var i = 0; i < v.length; i++)
        jNullish(jGet(v, i)) ? '' : jString(jGet(v, i)),
    ].join(',');
  if (v is JError) return '${v.get('name')}: ${v.get('message')}';
  if (v is JObject) return jString(jPrimitive(v, hint: 'string'));
  if (v is double && v.isFinite && v == v.truncateToDouble())
    return v.toInt().toString();
  if (v is double && v.isNaN) return 'NaN';
  return v.toString();
}

num jNumber(dynamic v) {
  if (v == null) return 0;
  if (identical(v, jUndefined)) return double.nan;
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  if (v is JSymbol)
    throw JThrown(JError('TypeError', 'Cannot convert Symbol to number'));
  if (v is JObject || v is List) return jNumber(jPrimitive(v, hint: 'number'));
  final text = jString(v).trim();
  return text.isEmpty ? 0 : num.tryParse(text) ?? double.nan;
}

int jRelativeIndex(dynamic value, int length) {
  final numeric = jNumber(value);
  if (numeric.isNaN) return 0;
  if (numeric == double.infinity) return length;
  if (numeric == double.negativeInfinity) return 0;
  final index = numeric.truncate();
  return (index < 0 ? length + index : index).clamp(0, length);
}

List<dynamic> jArrayLikeList(dynamic value) {
  if (value is! JObject && value is! List)
    throw JThrown(JError('TypeError', 'Array-like object required'));
  final number = jNumber(jGet(value, 'length'));
  final count = number.isNaN || number < 0
      ? 0
      : math.min(number, 9007199254740991).floor();
  return [for (var i = 0; i < count; i++) jGet(value, i)];
}

Iterable<dynamic> jIterable(dynamic value) sync* {
  final iterator = jGetIterator(value);
  while (iterator.advance()) {
    yield iterator.current;
  }
}

Map<Object, dynamic> jProperties(dynamic value) => jNullish(value)
    ? {}
    : {
        for (final key in jOwnKeys(value, enumerable: true))
          key: jGet(value, key),
      };

dynamic jCall(
  dynamic fn,
  List<dynamic> args, {
  dynamic receiver = jUndefined,
  bool optional = false,
}) {
  if (identical(fn, jShortCircuit)) return jShortCircuit;
  if (optional && jNullish(fn)) return jShortCircuit;
  if (fn is JFunction) return fn.invoke(args, receiver);
  throw JThrown(JError('TypeError', 'Value is not callable'));
}

dynamic jInvoke(
  dynamic object,
  dynamic key,
  List<dynamic> args, {
  bool optionalObject = false,
  bool optionalCall = false,
}) => jCall(
  jGet(object, key, optional: optionalObject),
  args,
  receiver: object,
  optional: optionalCall,
);
dynamic jNew(dynamic constructor, List<dynamic> args) {
  if (constructor is JClass) {
    final result = constructor.base is JFunction
        ? jNew(constructor.base, args)
        : JObject();
    constructor.attach(result);
    return result;
  }
  if (constructor is JFunction) {
    if (!constructor.constructible)
      throw JThrown(JError('TypeError', 'Not a constructor'));
    return constructor.construct == null
        ? jCall(constructor, args)
        : constructor.construct!(args);
  }
  throw JThrown(JError('TypeError', 'Value is not a constructor'));
}

dynamic jGet(dynamic value, dynamic key, {bool optional = false}) {
  if (identical(value, jShortCircuit)) return jShortCircuit;
  if (optional && jNullish(value)) return jShortCircuit;
  if (jNullish(value))
    throw JThrown(
      JError('TypeError', 'Cannot read property of null or undefined'),
    );
  final property = jPropertyKey(key);
  if (property is JSymbol) {
    if (value is JObject) return value.read(property, value);
    if (identical(property, jSymbols['iterator']) &&
        (value is List || value is String))
      return jNative((_) => jBuiltinIterator(value));
    return jUndefined;
  }
  final name = property as String;
  if (value is JObject) return value.get(name);
  if (value is List) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null && '$i' == name)
      return i >= 0 && i < value.length && !identical(value[i], _jHole)
          ? value[i]
          : jUndefined;
    switch (name) {
      case 'valueOf':
        return jNative((_) => value);
      case 'toString':
        return jNative((_) => jString(value));
      case 'keys':
      case 'values':
      case 'entries':
        return jNative((_) => jBuiltinIterator(value, name));
      case 'push':
        return jNative((a) {
          value.addAll(a);
          return value.length;
        });
      case 'pop':
        return jNative((a) {
          if (value.isEmpty) return jUndefined;
          final last = value.removeLast();
          return identical(last, _jHole) ? jUndefined : last;
        });
      case 'join':
        return jNative(
          (a) => [
            for (var i = 0; i < value.length; i++)
              jNullish(jGet(value, i)) ? '' : jString(jGet(value, i)),
          ].join(identical(jArg(a, 0), jUndefined) ? ',' : jString(a[0])),
        );
      case 'map':
      case 'filter':
      case 'forEach':
      case 'some':
      case 'every':
        return jNative((a) {
          final callback = jArg(a, 0), length = value.length;
          if (callback is! JFunction)
            throw JThrown(JError('TypeError', 'Callback is not callable'));
          final result = name == 'map'
              ? List<dynamic>.filled(length, _jHole, growable: true)
              : <dynamic>[];
          for (var i = 0; i < length; i++) {
            if (!jHasOwn(value, '$i')) continue;
            final item = jGet(value, i);
            final mapped = jCall(callback, [
              item,
              i,
              value,
            ], receiver: jArg(a, 1));
            if (name == 'map') result[i] = mapped;
            if (name == 'filter' && jTruthy(mapped)) result.add(item);
            if (name == 'some' && jTruthy(mapped)) return true;
            if (name == 'every' && !jTruthy(mapped)) return false;
          }
          if (name == 'some') return false;
          if (name == 'every') return true;
          return name == 'forEach' ? jUndefined : result;
        });
      case 'sort':
        return jNative((a) {
          final comparator = jArg(a, 0), length = value.length;
          if (!identical(comparator, jUndefined) && comparator is! JFunction)
            throw JThrown(JError('TypeError', 'Comparator is not callable'));
          final indexed = [
            for (var i = 0; i < length; i++)
              if (jHasOwn(value, '$i')) [jGet(value, i), i],
          ];
          indexed.sort((x, y) {
            if (identical(x[0], jUndefined) || identical(y[0], jUndefined)) {
              if (identical(x[0], y[0]))
                return (x[1] as int).compareTo(y[1] as int);
              return identical(x[0], jUndefined) ? 1 : -1;
            }
            final compared = identical(comparator, jUndefined)
                ? jString(x[0]).compareTo(jString(y[0]))
                : jNumber(jCall(comparator, [x[0], y[0]]));
            final c = compared.isNaN ? 0 : compared.sign.toInt();
            return c == 0 ? (x[1] as int).compareTo(y[1] as int) : c;
          });
          for (var i = 0; i < indexed.length; i++) {
            jSet(value, i, indexed[i][0]);
          }
          for (var i = indexed.length; i < length; i++) {
            jDelete(value, '$i');
          }
          return value;
        });
      case 'includes':
      case 'indexOf':
        return jNative((a) {
          final length = value.length;
          final start = jRelativeIndex(jArg(a, 1), length);
          for (var i = start; i < length; i++) {
            if (name == 'indexOf' && !jHasOwn(value, '$i')) continue;
            final item = jGet(value, i);
            if (name == 'includes'
                ? jSameValue(item, jArg(a, 0), zero: true)
                : jBinary('===', item, jArg(a, 0)))
              return name == 'includes' ? true : i;
          }
          return name == 'includes' ? false : -1;
        });
      case 'slice':
        return jNative((a) {
          final length = value.length;
          final start = jRelativeIndex(jArg(a, 0), length);
          final end = identical(jArg(a, 1), jUndefined)
              ? length
              : jRelativeIndex(a[1], length);
          return value.sublist(start, math.max(start, end));
        });
    }
  }
  if (value is String) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null && '$i' == name)
      return i >= 0 && i < value.length && !identical(value[i], _jHole)
          ? value[i]
          : jUndefined;
    switch (name) {
      case 'trim':
        return jNative((a) => value.trim());
      case 'toLowerCase':
        return jNative((a) => value.toLowerCase());
      case 'toUpperCase':
        return jNative((a) => value.toUpperCase());
      case 'includes':
        return jNative((a) => value.contains(jString(a[0])));
      case 'startsWith':
        return jNative((a) => value.startsWith(jString(a[0])));
      case 'endsWith':
        return jNative((a) => value.endsWith(jString(a[0])));
      case 'split':
        return jNative(
          (a) => a.isEmpty
              ? [value]
              : value.split(
                  a[0] is JRegex ? (a[0] as JRegex).value : jString(a[0]),
                ),
        );
      case 'match':
        return jNative((a) {
          final re = a[0] is JRegex
              ? a[0] as JRegex
              : JRegex(jString(a[0]), '');
          if (re.flags.contains('g')) {
            final matches = re.value
                .allMatches(value)
                .map((m) => m[0])
                .toList();
            return matches.isEmpty ? null : matches;
          }
          final m = re.value.firstMatch(value);
          return m == null
              ? null
              : [for (var i = 0; i <= m.groupCount; i++) m[i] ?? jUndefined];
        });
      case 'replace':
        return jNative((a) {
          final re = a[0] is JRegex ? a[0] as JRegex : null;
          final Pattern pattern = re?.value ?? jString(a[0]);
          String replacement(Match m) {
            if (a[1] is JFunction)
              return jString(
                jCall(a[1], [
                  m[0],
                  for (var i = 1; i <= m.groupCount; i++) m[i],
                  m.start,
                  value,
                ]),
              );
            return jString(a[1])
                .replaceAllMapped(RegExp(r'\$(\$|&|[0-9]{1,2})'), (p) {
                  if (p[1] == '\$') return '\$';
                  if (p[1] == '&') return m[0]!;
                  final index = int.parse(p[1]!);
                  return index > 0 && index <= m.groupCount
                      ? m[index] ?? ''
                      : p[0]!;
                });
          }

          return re?.flags.contains('g') == true
              ? value.replaceAllMapped(pattern, replacement)
              : value.replaceFirstMapped(pattern, replacement);
        });
    }
  }
  if (value is JSymbol) {
    if (name == 'description') return value.description ?? jUndefined;
    if (name == 'toString') return jNative((_) => value.descriptive);
    if (name == 'valueOf') return jNative((_) => value);
  }
  if (value is JRegex && name == 'test')
    return jNative((a) => value.value.hasMatch(jString(a[0])));
  if (value is num && name == 'toString') return jNative((a) => jString(value));
  return jUndefined;
}

dynamic jSet(dynamic value, dynamic key, dynamic assigned) {
  final property = jPropertyKey(key);
  if (value is JObject && property is JSymbol) {
    if (!value.write(property, assigned, value))
      throw JThrown(JError('TypeError', 'Cannot assign symbol property'));
    return assigned;
  }
  final name = property as String;
  if (value is JObject) return value.set(name, assigned);
  if (value is List) {
    if (name == 'length') {
      final numeric = jNumber(assigned);
      if (!numeric.isFinite ||
          numeric < 0 ||
          numeric > 4294967295 ||
          numeric != numeric.truncate())
        throw JThrown(JError('RangeError', 'Invalid array length'));
      final size = numeric.toInt();
      while (value.length < size) {
        value.add(_jHole);
      }
      value.length = size;
      return assigned;
    }
    final i = int.tryParse(name);
    if (i != null && i >= 0 && i < 4294967295 && '$i' == name) {
      while (value.length <= i) {
        value.add(_jHole);
      }
      value[i] = assigned;
      return assigned;
    }
  }
  throw StateError('Cannot assign property $name');
}

dynamic jAssign(JRef ref, String op, dynamic Function() rhs) {
  if (op == '=') return ref.write(rhs());
  final left = ref.read();
  if (op == '||=' && jTruthy(left) ||
      op == '&&=' && !jTruthy(left) ||
      op == '??=' && !jNullish(left))
    return left;
  return ref.write(
    ['||=', '&&=', '??='].contains(op)
        ? rhs()
        : jBinary(op.substring(0, op.length - 1), left, rhs()),
  );
}

dynamic jUpdate(JRef ref, num delta, bool prefix) {
  final old = jNumber(ref.read());
  final next = old + delta;
  ref.write(next);
  return prefix ? next : old;
}

dynamic jLogical(String op, dynamic left, dynamic Function() right) {
  if (op == '&&') return jTruthy(left) ? right() : left;
  if (op == '||') return jTruthy(left) ? left : right();
  if (op == '??') return jNullish(left) ? right() : left;
  throw StateError('Logical operator $op');
}

dynamic jUnary(String op, dynamic value) {
  switch (op) {
    case '!':
      return !jTruthy(value);
    case '-':
      final number = jNumber(value);
      return number == 0 ? -(number.toDouble()) : -number;
    case '+':
      return jNumber(value);
    case '~':
      return ~jNumber(value).toInt();
    case 'void':
      return jUndefined;
    case 'typeof':
      if (value is JSymbol) return 'symbol';
      return identical(value, jUndefined)
          ? 'undefined'
          : value is bool
          ? 'boolean'
          : value is num
          ? 'number'
          : value is String
          ? 'string'
          : value is JFunction
          ? 'function'
          : 'object';
  }
  throw StateError('Unary operator $op');
}

dynamic jBinary(String op, dynamic a, dynamic b) {
  switch (op) {
    case '===':
      return a is num && b is num
          ? a == b
          : a.runtimeType == b.runtimeType && a == b;
    case '!==':
      return !jBinary('===', a, b);
    case '==':
      return jNullish(a) && jNullish(b) ||
          jBinary('===', a, b) ||
          ((a is num || a is bool || b is num || b is bool) &&
              jNumber(a) == jNumber(b));
    case '!=':
      return !jBinary('==', a, b);
    case '+':
      a = jPrimitive(a);
      b = jPrimitive(b);
      return a is String || b is String
          ? jString(a) + jString(b)
          : jNumber(a) + jNumber(b);
    case '-':
      return jNumber(a) - jNumber(b);
    case '*':
      return jNumber(a) * jNumber(b);
    case '/':
      return jNumber(a) / jNumber(b);
    case '%':
      return jNumber(a).remainder(jNumber(b));
    case '**':
      return math.pow(jNumber(a), jNumber(b));
    case '<':
      return a is String && b is String
          ? a.compareTo(b) < 0
          : jNumber(a) < jNumber(b);
    case '>':
      return a is String && b is String
          ? a.compareTo(b) > 0
          : jNumber(a) > jNumber(b);
    case '<=':
      return a is String && b is String
          ? a.compareTo(b) <= 0
          : jNumber(a) <= jNumber(b);
    case '>=':
      return a is String && b is String
          ? a.compareTo(b) >= 0
          : jNumber(a) >= jNumber(b);
    case '&':
      return jNumber(a).toInt() & jNumber(b).toInt();
    case '|':
      return jNumber(a).toInt() | jNumber(b).toInt();
    case '^':
      return jNumber(a).toInt() ^ jNumber(b).toInt();
    case '<<':
      return jNumber(a).toInt() << jNumber(b).toInt();
    case '>>':
      return jNumber(a).toInt() >> jNumber(b).toInt();
    case 'in':
      if (b is! JObject && b is! List)
        throw JThrown(
          JError('TypeError', 'Right operand of in must be an object'),
        );
      return jHasProperty(b, jPropertyKey(a));
  }
  throw StateError('Binary operator $op');
}

void installJSBuiltins(JScope scope) {
  installJSObjects(scope);
  installJSCollections(scope);
  scope.define(
    'JSON',
    JObject({
      'parse': jNative((a) => jJSONParse(jArg(a, 0), jArg(a, 1))),
      'stringify': jNative(
        (a) => jJSONStringify(jArg(a, 0), jArg(a, 1), jArg(a, 2)),
      ),
    }),
  );
  installJSPromises(scope);
  for (final name in [
    'Error',
    'TypeError',
    'RangeError',
    'ReferenceError',
    'SyntaxError',
    'URIError',
    'EvalError',
  ]) {
    final constructor = jNative(
      (a) =>
          JError(name, identical(jArg(a, 0), jUndefined) ? '' : jString(a[0])),
    );
    final prototype = jErrorPrototypes.putIfAbsent(name, () => JObject());
    if (name != 'Error') prototype.prototype = jErrorPrototypes['Error'];
    prototype.properties.addAll({
      'constructor': constructor,
      'name': name,
      'message': '',
    });
    constructor.properties.addAll({'prototype': prototype, 'name': name});
    jBuiltinProperties(prototype);
    scope.define(name, constructor);
  }
  scope.define(
    'AggregateError',
    jNative(
      (a) => JError(
        'AggregateError',
        a.length < 2 ? '' : jString(a[1]),
        errors: jIterable(jArg(a, 0)).toList(),
      ),
    ),
  );
  scope.define('Boolean', jNative((a) => jTruthy(jArg(a, 0))));
  scope.define(
    'String',
    jNative(
      (a) => a.isEmpty
          ? ''
          : a[0] is JSymbol
          ? (a[0] as JSymbol).descriptive
          : jString(a[0]),
    ),
  );
  scope.define('Number', jNative((a) => a.isEmpty ? 0 : jNumber(a[0])));
  scope.define(
    'Date',
    jNative((a) {
      final now = DateTime.now();
      return JObject({'getFullYear': jNative((a) => now.year)});
    }),
  );
  final array = jNative((a) {
    if (a.length == 1 && a[0] is num) {
      final count = a[0] as num;
      if (!count.isFinite ||
          count < 0 ||
          count > 4294967295 ||
          count != count.truncate())
        throw JThrown(JError('RangeError', 'Invalid array length'));
      return List<dynamic>.filled(count.toInt(), _jHole, growable: true);
    }
    return List<dynamic>.of(a);
  });
  array.properties.addAll({
    'isArray': jNative((a) => jArg(a, 0) is List),
    'of': jNative((a) => List<dynamic>.of(a)),
    'from': jNative((a) {
      final input = jArg(a, 0), mapper = jArg(a, 1);
      if (!identical(mapper, jUndefined) && mapper is! JFunction)
        throw JThrown(JError('TypeError', 'Array.from mapper is not callable'));
      final values = <dynamic>[];
      if (!jNullish(jGet(input, jSymbols['iterator']))) {
        jForEachIterable(input, (value) {
          values.add(
            mapper is JFunction
                ? jCall(mapper, [value, values.length], receiver: jArg(a, 2))
                : value,
          );
        });
      } else {
        final number = jNumber(jGet(input, 'length'));
        final count = number.isNaN || number < 0
            ? 0
            : math.min(number, 9007199254740991).floor();
        for (var i = 0; i < count; i++) {
          final value = jGet(input, i);
          values.add(
            mapper is JFunction
                ? jCall(mapper, [value, i], receiver: jArg(a, 2))
                : value,
          );
        }
      }
      return values;
    }),
  });
  scope.define('Array', array);
  final random = math.Random();
  scope.define(
    'Math',
    JObject({
      'PI': math.pi,
      'random': jNative((a) => random.nextDouble()),
      'floor': jNative((a) => jNumber(a[0]).floor()),
      'ceil': jNative((a) => jNumber(a[0]).ceil()),
      'abs': jNative((a) => jNumber(a[0]).abs()),
      'sqrt': jNative((a) => math.sqrt(jNumber(a[0]))),
      'min': jNative(
        (a) => a.map(jNumber).fold<num>(double.infinity, math.min),
      ),
      'max': jNative(
        (a) => a.map(jNumber).fold<num>(double.negativeInfinity, math.max),
      ),
      'hypot': jNative(
        (a) => math.sqrt(a.map(jNumber).fold<num>(0, (sum, v) => sum + v * v)),
      ),
    }),
  );
  scope.define(
    'console',
    JObject({
      'log': jNative((a) {
        print(a.map(jString).join(' '));
        return jUndefined;
      }),
    }),
  );
}

class JIterator extends JObject {
  final dynamic Function() step;
  bool completed = false;
  JIterator(this.step) {
    symbols[jSymbols['iterator']!] = jNative((_) => this);
    properties['next'] = jNative((_) {
      if (completed) return JObject({'value': jUndefined, 'done': true});
      final result = step();
      if (jTruthy(jGet(result, 'done'))) completed = true;
      return result;
    });
  }
}

JIterator jBuiltinIterator(dynamic value, [String mode = 'values']) {
  var index = 0;
  final input = value is String
      ? value.runes.map((r) => String.fromCharCode(r)).toList()
      : value as List;
  return JIterator(() {
    if (index >= input.length)
      return JObject({'done': true, 'value': jUndefined});
    final i = index++;
    return JObject({
      'done': false,
      'value': mode == 'keys'
          ? i
          : mode == 'entries'
          ? [i, jGet(input, i)]
          : jGet(input, i),
    });
  });
}

class JIteratorRecord {
  final dynamic object, next;
  bool done = false;
  dynamic current = jUndefined;
  JIteratorRecord(this.object) : next = jGet(object, 'next');
  bool advance() {
    if (done) return false;
    try {
      final result = jCall(next, [], receiver: object);
      if (result is! JObject && result is! List)
        throw JThrown(JError('TypeError', 'Iterator result must be an object'));
      done = jTruthy(jGet(result, 'done'));
      if (!done) current = jGet(result, 'value');
      return !done;
    } catch (_) {
      done = true;
      rethrow;
    }
  }

  void close({bool suppressErrors = false}) {
    if (done) return;
    done = true;
    try {
      final method = jGet(object, 'return');
      if (jNullish(method)) return;
      final result = jCall(method, [], receiver: object);
      if (result is! JObject && result is! List)
        throw JThrown(
          JError('TypeError', 'Iterator return must return an object'),
        );
    } catch (_) {
      if (!suppressErrors) rethrow;
    }
  }
}

JIteratorRecord jGetIterator(dynamic value) {
  final method = jGet(value, jSymbols['iterator']);
  final iterator = jCall(method, [], receiver: value);
  if (iterator is! JObject && iterator is! List)
    throw JThrown(JError('TypeError', 'Iterator must be an object'));
  return JIteratorRecord(iterator);
}

void jForEachIterable(dynamic value, void Function(dynamic) callback) {
  final iterator = jGetIterator(value);
  try {
    while (iterator.advance()) {
      callback(iterator.current);
    }
  } catch (_) {
    iterator.close(suppressErrors: true);
    rethrow;
  } finally {
    iterator.close();
  }
}

class JBox extends JObject {
  final dynamic value;
  JBox(this.value) {
    if (value is String) {
      for (var i = 0; i < value.length; i++) {
        properties['$i'] = value[i];
        flags['$i'] = JPropertyFlags(writable: false, configurable: false);
      }
      properties['length'] = value.length;
      flags['length'] = JPropertyFlags(
        writable: false,
        enumerable: false,
        configurable: false,
      );
    }
  }
}

dynamic jObject(dynamic value) => jNullish(value)
    ? JObject()
    : value is JObject || value is List
    ? value
    : JBox(value);

void installJSObjects(JScope scope) {
  final symbol = JFunction(
    (a, _) => JSymbol(identical(jArg(a, 0), jUndefined) ? null : jString(a[0])),
    constructible: false,
  );
  symbol.properties.addAll({
    ...jSymbols,
    'for': jNative((a) {
      final key = jString(jArg(a, 0));
      return _jSymbolRegistry.putIfAbsent(
        key,
        () => JSymbol(key, registered: true),
      );
    }),
    'keyFor': jNative((a) {
      final value = jArg(a, 0);
      if (value is! JSymbol)
        throw JThrown(JError('TypeError', 'Symbol.keyFor requires a symbol'));
      return value.registered ? value.description : jUndefined;
    }),
  });
  jBuiltinProperties(symbol);
  scope.define('Symbol', symbol);
  final object = jNative((a) => jObject(jArg(a, 0)));
  object.properties.addAll({
    'prototype': jObjectPrototype,
    'is': jNative((a) => jSameValue(jArg(a, 0), jArg(a, 1))),
    'keys': jNative(
      (a) => jOwnKeys(jArg(a, 0), enumerable: true, strings: true),
    ),
    'values': jNative(
      (a) => [
        for (final key in jOwnKeys(jArg(a, 0), strings: true))
          if (jEnumerable(a[0], key)) jGet(a[0], key),
      ],
    ),
    'entries': jNative(
      (a) => [
        for (final key in jOwnKeys(jArg(a, 0), strings: true))
          if (jEnumerable(a[0], key)) [key, jGet(a[0], key)],
      ],
    ),
    'hasOwn': jNative((a) => jHasOwn(jArg(a, 0), jPropertyKey(jArg(a, 1)))),
    'getOwnPropertyNames': jNative((a) => jOwnKeys(jArg(a, 0), strings: true)),
    'getOwnPropertySymbols': jNative(
      (a) => jOwnKeys(jArg(a, 0)).whereType<JSymbol>().toList(),
    ),
    'getOwnPropertyDescriptor': jNative(
      (a) => jDescriptor(jArg(a, 0), jPropertyKey(jArg(a, 1))),
    ),
    'getOwnPropertyDescriptors': jNative((a) {
      final result = JObject();
      for (final key in jOwnKeys(jArg(a, 0))) {
        final descriptor = jDescriptor(a[0], key);
        if (!identical(descriptor, jUndefined)) result.store(key, descriptor);
      }
      return result;
    }),
    'defineProperty': jNative((a) {
      final target = jRequireObject(jArg(a, 0));
      if (!jDefineProperty(target, jPropertyKey(jArg(a, 1)), jArg(a, 2)))
        throw JThrown(JError('TypeError', 'Cannot redefine property'));
      return target;
    }),
    'defineProperties': jNative((a) {
      final target = jRequireObject(jArg(a, 0));
      final descriptors = [
        for (final key in jOwnKeys(jArg(a, 1)))
          if (jEnumerable(a[1], key))
            (key, jNormalizeDescriptor(jGet(a[1], key))),
      ];
      for (final (key, descriptor) in descriptors) {
        if (!jDefineProperty(target, key, descriptor, normalized: true))
          throw JThrown(JError('TypeError', 'Cannot redefine property'));
      }
      return target;
    }),
    'create': jNative((a) {
      final target = JObject();
      jSetPrototype(target, jArg(a, 0));
      if (!identical(jArg(a, 1), jUndefined))
        jInvoke(object, 'defineProperties', [target, a[1]]);
      return target;
    }),
    'getPrototypeOf': jNative((a) {
      if (jNullish(jArg(a, 0)))
        throw JThrown(
          JError('TypeError', 'Cannot get prototype of null or undefined'),
        );
      return jRequireObject(jObject(a[0])).prototype;
    }),
    'setPrototypeOf': jNative((a) {
      final target = jRequireObject(jArg(a, 0));
      if (!jSetPrototype(target, jArg(a, 1)))
        throw JThrown(JError('TypeError', 'Cannot set prototype'));
      return target;
    }),
    'assign': jNative((a) {
      if (jNullish(jArg(a, 0)))
        throw JThrown(
          JError('TypeError', 'Cannot assign to null or undefined'),
        );
      final target = jObject(a[0]);
      for (final source in a.skip(1)) {
        if (jNullish(source)) continue;
        for (final key in jOwnKeys(source)) {
          if (jEnumerable(source, key)) jSet(target, key, jGet(source, key));
        }
      }
      return target;
    }),
    'groupBy': jNative((a) {
      final target = JObject.root(), callback = jArg(a, 1);
      if (callback is! JFunction)
        throw JThrown(JError('TypeError', 'Group callback is not callable'));
      var index = 0;
      jForEachIterable(jArg(a, 0), (value) {
        final key = jPropertyKey(jCall(callback, [value, index++]));
        if (!target.own(key)) target.store(key, <dynamic>[]);
        (target.raw(key) as List).add(value);
      });
      return target;
    }),
    'fromEntries': jNative((a) {
      final target = JObject();
      jForEachIterable(jArg(a, 0), (entry) {
        if (entry is! JObject && entry is! List)
          throw JThrown(JError('TypeError', 'Entry must be an object'));
        target.store(jPropertyKey(jGet(entry, 0)), jGet(entry, 1));
      });
      return target;
    }),
    for (final mode in ['freeze', 'seal', 'preventExtensions'])
      mode: jNative((a) {
        final target = jArg(a, 0);
        if (target is List)
          throw UnsupportedError('Object.$mode on arrays is not implemented');
        if (target is! JObject) return target;
        for (final key in jOwnKeys(target)) {
          final flags = target.flags.putIfAbsent(key, () => JPropertyFlags());
          if (mode != 'preventExtensions') flags.configurable = false;
          if (mode == 'freeze' && !target.accessor(key)) flags.writable = false;
        }
        target.extensible = false;
        return target;
      }),
    'isExtensible': jNative(
      (a) => jArg(a, 0) is JObject && (a[0] as JObject).extensible,
    ),
    for (final mode in ['isFrozen', 'isSealed'])
      mode: jNative((a) {
        final target = jArg(a, 0);
        if (target is List)
          throw UnsupportedError('Object.$mode on arrays is not implemented');
        if (target is! JObject) return true;
        return !target.extensible &&
            jOwnKeys(target).every((key) {
              final flags = target.flags[key] ?? JPropertyFlags();
              return !flags.configurable &&
                  (mode == 'isSealed' ||
                      target.accessor(key) ||
                      !flags.writable);
            });
      }),
  });
  jObjectPrototype.properties['constructor'] = object;
  jBuiltinProperties(object);
  jBuiltinProperties(jObjectPrototype);
  scope.define('Object', object);
  scope.define(
    'Reflect',
    JObject({
      'ownKeys': jNative((a) => jOwnKeys(jRequireObject(jArg(a, 0)))),
      'get': jNative((a) {
        final target = jRequireObject(jArg(a, 0));
        return a.length < 3
            ? jGet(target, jArg(a, 1))
            : target.read(jPropertyKey(a[1]), a[2]);
      }),
      'set': jNative(
        (a) => jRequireObject(jArg(a, 0)).write(
          jPropertyKey(jArg(a, 1)),
          jArg(a, 2),
          a.length < 4 ? a[0] : a[3],
        ),
      ),
      'has': jNative(
        (a) =>
            jHasProperty(jRequireObject(jArg(a, 0)), jPropertyKey(jArg(a, 1))),
      ),
      'deleteProperty': jNative(
        (a) => jRequireObject(jArg(a, 0)).remove(jPropertyKey(jArg(a, 1))),
      ),
      'defineProperty': jNative(
        (a) => jDefineProperty(
          jRequireObject(jArg(a, 0)),
          jPropertyKey(jArg(a, 1)),
          jArg(a, 2),
        ),
      ),
      'getOwnPropertyDescriptor': jNative(
        (a) =>
            jDescriptor(jRequireObject(jArg(a, 0)), jPropertyKey(jArg(a, 1))),
      ),
      'getPrototypeOf': jNative((a) => jRequireObject(jArg(a, 0)).prototype),
      'setPrototypeOf': jNative(
        (a) => jSetPrototype(jRequireObject(jArg(a, 0)), jArg(a, 1)),
      ),
      'isExtensible': jNative((a) => jRequireObject(jArg(a, 0)).extensible),
      'preventExtensions': jNative((a) {
        jRequireObject(jArg(a, 0)).extensible = false;
        return true;
      }),
      'apply': jNative(
        (a) =>
            jCall(jArg(a, 0), jArrayLikeList(jArg(a, 2)), receiver: jArg(a, 1)),
      ),
    }),
  );
}

class JMapEntry {
  dynamic key;
  dynamic value;
  bool active = true;
  JMapEntry(this.key, this.value);
}

int jKeyHash(dynamic value) => value is num && value.isNaN
    ? 731
    : value is JObject || value is List || value is JSymbol
    ? identityHashCode(value)
    : value.hashCode;

class JMap extends JObject {
  final entries = <JMapEntry>[];
  final lookup = HashMap<dynamic, JMapEntry>(
    equals: (a, b) => jSameValue(a, b, zero: true),
    hashCode: jKeyHash,
  );
  JMap({bool set = false}) {
    prototype = set ? jSetPrototypeObject : jMapPrototype;
  }
  void put(dynamic key, dynamic value) {
    if (key is num && key == 0) key = 0;
    final existing = lookup[key];
    if (existing != null) {
      existing.value = value;
      return;
    }
    final entry = JMapEntry(key, value);
    lookup[key] = entry;
    entries.add(entry);
  }

  bool erase(dynamic key) {
    final entry = lookup.remove(key);
    if (entry == null) return false;
    entry.active = false;
    entry.key = jUndefined;
    entry.value = jUndefined;
    return true;
  }

  void clearEntries() {
    for (final entry in entries) {
      entry.active = false;
      entry.key = jUndefined;
      entry.value = jUndefined;
    }
    lookup.clear();
  }

  JIterator iterate(String mode) {
    var index = 0;
    return JIterator(() {
      while (index < entries.length) {
        final entry = entries[index++];
        if (!entry.active) continue;
        return JObject({
          'done': false,
          'value': mode == 'keys'
              ? entry.key
              : mode == 'values'
              ? entry.value
              : [entry.key, entry.value],
        });
      }
      return JObject({'done': true, 'value': jUndefined});
    });
  }
}

class JSet extends JMap {
  JSet() : super(set: true);
}

JMap jMapReceiver(dynamic receiver, {bool set = false}) {
  if (set ? receiver is! JSet : receiver is! JMap || receiver is JSet)
    throw JThrown(
      JError('TypeError', set ? 'Not a Set receiver' : 'Not a Map receiver'),
    );
  return receiver as JMap;
}

JObject jBuildMapPrototype(bool set) {
  JMap receiver(dynamic value) => jMapReceiver(value, set: set);
  JFunction method(dynamic Function(List<dynamic>, JMap) body) =>
      JFunction((a, r) => body(a, receiver(r)), constructible: false);
  final prototype = JObject({
    'clear': method((a, r) {
      r.clearEntries();
      return jUndefined;
    }),
    'delete': method((a, r) => r.erase(jArg(a, 0))),
    'has': method((a, r) => r.lookup.containsKey(jArg(a, 0))),
    if (set)
      'add': method((a, r) {
        final key = jArg(a, 0);
        r.put(key, key is num && key == 0 ? 0 : key);
        return r;
      }),
    if (!set)
      'get': method(
        (a, r) =>
            r.lookup[jArg(a, 0)]?.value ??
            (r.lookup.containsKey(jArg(a, 0)) ? null : jUndefined),
      ),
    if (!set)
      'set': method((a, r) {
        r.put(jArg(a, 0), jArg(a, 1));
        return r;
      }),
    'keys': method((a, r) => r.iterate('keys')),
    'values': method((a, r) => r.iterate('values')),
    'entries': method((a, r) => r.iterate('entries')),
    'forEach': method((a, r) {
      final callback = jArg(a, 0);
      if (callback is! JFunction)
        throw JThrown(JError('TypeError', 'Callback is not callable'));
      for (var index = 0; index < r.entries.length; index++) {
        final entry = r.entries[index];
        if (entry.active)
          jCall(callback, [entry.value, entry.key, r], receiver: jArg(a, 1));
      }
      return jUndefined;
    }),
    if (set)
      for (final name in [
        'union',
        'intersection',
        'difference',
        'symmetricDifference',
        'isSubsetOf',
        'isSupersetOf',
        'isDisjointFrom',
      ])
        name: method((a, r) => jSetOperation(r as JSet, jArg(a, 0), name)),
  });
  prototype.properties['size'] = jUndefined;
  prototype.getters['size'] = JFunction(
    (_, r) => receiver(r).lookup.length,
    constructible: false,
  );
  prototype.symbols[jSymbols['iterator']!] =
      prototype.properties[set ? 'values' : 'entries'];
  prototype.symbols[jSymbols['toStringTag']!] = set ? 'Set' : 'Map';
  if (set) prototype.properties['keys'] = prototype.properties['values'];
  return prototype;
}

final JObject jMapPrototype = jBuildMapPrototype(false);
final JObject jSetPrototypeObject = jBuildMapPrototype(true);

class JSetRecord {
  final dynamic object, has, keys;
  final num size;
  JSetRecord._(this.object, this.size, this.has, this.keys);
  factory JSetRecord(dynamic object) {
    if (object is! JObject && object is! List)
      throw JThrown(JError('TypeError', 'Set-like object required'));
    final numeric = jNumber(jGet(object, 'size'));
    if (numeric.isNaN) throw JThrown(JError('TypeError', 'Invalid set size'));
    final size = numeric.isFinite ? numeric.truncate() : numeric;
    if (size < 0) throw JThrown(JError('RangeError', 'Negative set size'));
    final has = jGet(object, 'has'), keys = jGet(object, 'keys');
    if (has is! JFunction || keys is! JFunction)
      throw JThrown(JError('TypeError', 'Invalid set methods'));
    return JSetRecord._(object, size, has, keys);
  }
  bool contains(dynamic key) => jTruthy(jCall(has, [key], receiver: object));
  JIteratorRecord iterator() {
    final result = jCall(keys, [], receiver: object);
    if (result is! JObject && result is! List)
      throw JThrown(JError('TypeError', 'Iterator must be an object'));
    return JIteratorRecord(result);
  }
}

dynamic jSetOperation(JSet self, dynamic other, String mode) {
  final record = JSetRecord(other);
  final result = JSet();
  // Union/symmetricDifference obtain the iterator before copying the receiver.
  final initialIterator = ['union', 'symmetricDifference'].contains(mode)
      ? record.iterator()
      : null;
  if (['union', 'difference', 'symmetricDifference'].contains(mode)) {
    for (final entry in self.entries) {
      if (entry.active) result.put(entry.key, entry.key);
    }
  }
  if (mode == 'isSubsetOf' && self.lookup.length > record.size) return false;
  if (mode == 'isSupersetOf' && self.lookup.length < record.size) return false;
  final useSelf =
      mode == 'isSubsetOf' ||
      ['intersection', 'difference', 'isDisjointFrom'].contains(mode) &&
          self.lookup.length <= record.size;
  if (useSelf) {
    final entries = mode == 'difference' ? result.entries : self.entries;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (!entry.active) continue;
      final key = entry.key;
      final contains = record.contains(key);
      if (mode == 'intersection' && contains) result.put(key, key);
      if (mode == 'difference' && contains) result.erase(key);
      if (mode == 'isSubsetOf' && !contains ||
          mode == 'isDisjointFrom' && contains)
        return false;
    }
  } else {
    final iterator = initialIterator ?? record.iterator();
    try {
      while (iterator.advance()) {
        final key = iterator.current,
            contains = self.lookup.containsKey(iterator.current);
        if (mode == 'union' ||
            mode == 'intersection' && contains ||
            mode == 'symmetricDifference' && !contains)
          result.put(key, key);
        if (mode == 'difference' || mode == 'symmetricDifference' && contains)
          result.erase(key);
        if (mode == 'isSupersetOf' && !contains ||
            mode == 'isDisjointFrom' && contains)
          return false;
      }
    } catch (_) {
      iterator.close(suppressErrors: true);
      rethrow;
    } finally {
      iterator.close();
    }
  }
  return mode.startsWith('is') ? true : result;
}

bool jWeakKey(dynamic key) =>
    key is JObject || key is List || key is JSymbol && !key.registered;

class JWeakCollection extends JObject {
  final entries = Expando<List<dynamic>>();
  final bool setCollection;
  JWeakCollection(this.setCollection) {
    prototype = setCollection ? jWeakSetPrototype : jWeakMapPrototype;
  }
}

JObject jBuildWeakPrototype(bool set) {
  JFunction method(dynamic Function(List<dynamic>, JWeakCollection) callback) =>
      JFunction((a, receiver) {
        if (receiver is! JWeakCollection || receiver.setCollection != set)
          throw JThrown(
            JError('TypeError', 'Invalid weak collection receiver'),
          );
        return callback(a, receiver);
      }, constructible: false);
  final prototype = JObject({
    'has': method((a, r) => jWeakKey(jArg(a, 0)) && r.entries[a[0]] != null),
    'delete': method((a, r) {
      final key = jArg(a, 0);
      if (!jWeakKey(key) || r.entries[key] == null) return false;
      r.entries[key] = null;
      return true;
    }),
    if (!set)
      'get': method(
        (a, r) => !jWeakKey(jArg(a, 0)) || r.entries[a[0]] == null
            ? jUndefined
            : r.entries[a[0]]![0],
      ),
    set ? 'add' : 'set': method((a, r) {
      final key = jArg(a, 0);
      if (!jWeakKey(key))
        throw JThrown(JError('TypeError', 'Invalid weak collection key'));
      r.entries[key] = [set ? true : jArg(a, 1)];
      return r;
    }),
  });
  prototype.symbols[jSymbols['toStringTag']!] = set ? 'WeakSet' : 'WeakMap';
  return prototype;
}

final JObject jWeakMapPrototype = jBuildWeakPrototype(false);
final JObject jWeakSetPrototype = jBuildWeakPrototype(true);

void jBuiltinProperties(JObject object) {
  for (final key in jOwnKeys(object)) {
    object.flags.putIfAbsent(key, () => JPropertyFlags()).enumerable = false;
  }
}

void installJSCollections(JScope scope) {
  for (final set in [false, true]) {
    final name = set ? 'Set' : 'Map';
    final constructor = JFunction(
      (_, __) => throw JThrown(JError('TypeError', '$name requires new')),
      construct: (a) {
        final object = set ? JSet() : JMap();
        if (!jNullish(jArg(a, 0))) {
          final adder = object.get(set ? 'add' : 'set');
          if (adder is! JFunction)
            throw JThrown(JError('TypeError', 'Invalid collection adder'));
          jForEachIterable(a[0], (value) {
            if (!set && value is! JObject && value is! List)
              throw JThrown(JError('TypeError', 'Map entry must be an object'));
            jCall(
              adder,
              set ? [value] : [jGet(value, 0), jGet(value, 1)],
              receiver: object,
            );
          });
        }
        return object;
      },
    );
    constructor.properties['prototype'] = set
        ? jSetPrototypeObject
        : jMapPrototype;
    (set ? jSetPrototypeObject : jMapPrototype).properties['constructor'] =
        constructor;
    if (!set)
      constructor.properties['groupBy'] = jNative((a) {
        final groups = JMap();
        var index = 0;
        final callback = jArg(a, 1);
        if (callback is! JFunction)
          throw JThrown(JError('TypeError', 'Group callback is not callable'));
        jForEachIterable(jArg(a, 0), (value) {
          final key = jCall(callback, [value, index++]);
          if (!groups.lookup.containsKey(key)) groups.put(key, <dynamic>[]);
          (groups.lookup[key]!.value as List).add(value);
        });
        return groups;
      });
    scope.define(name, constructor);
    final weakName = set ? 'WeakSet' : 'WeakMap';
    final weakConstructor = JFunction(
      (_, __) => throw JThrown(JError('TypeError', '$weakName requires new')),
      construct: (a) {
        final object = JWeakCollection(set);
        if (!jNullish(jArg(a, 0)))
          jForEachIterable(a[0], (value) {
            if (!set && value is! JObject && value is! List)
              throw JThrown(
                JError('TypeError', 'WeakMap entry must be an object'),
              );
            jInvoke(
              object,
              set ? 'add' : 'set',
              set ? [value] : [jGet(value, 0), jGet(value, 1)],
            );
          });
        return object;
      },
    );
    final weakPrototype = set ? jWeakSetPrototype : jWeakMapPrototype;
    weakConstructor.properties['prototype'] = weakPrototype;
    weakPrototype.properties['constructor'] = weakConstructor;
    for (final prototype in [
      weakPrototype,
      set ? jSetPrototypeObject : jMapPrototype,
    ]) {
      jBuiltinProperties(prototype);
      prototype.flags[jSymbols['toStringTag']!]!.writable = false;
    }
    jBuiltinProperties(constructor);
    jBuiltinProperties(weakConstructor);
    scope.define(weakName, weakConstructor);
  }
}

dynamic jJSONParse(dynamic text, dynamic reviver) {
  dynamic convert(dynamic value) {
    if (value is Map)
      return JObject({
        for (final entry in value.entries)
          entry.key as String: convert(entry.value),
      });
    if (value is List) return value.map(convert).toList();
    return value;
  }

  dynamic root;
  try {
    root = convert(jsonDecode(jString(text)));
  } on FormatException {
    throw JThrown(JError('SyntaxError', 'Invalid JSON text'));
  }
  if (reviver is! JFunction) return root;
  dynamic walk(dynamic holder, String key) {
    final value = jGet(holder, key);
    if (value is JObject || value is List) {
      final keys = value is List
          ? [for (var i = 0; i < value.length; i++) '$i']
          : jOwnKeys(value, enumerable: true, strings: true);
      for (final name in keys) {
        final next = walk(value, name as String);
        if (identical(next, jUndefined)) {
          jDelete(value, name);
        } else if (value is JObject) {
          jDefineProperty(
            value,
            name,
            JObject({
              'value': next,
              'writable': true,
              'enumerable': true,
              'configurable': true,
            }),
          );
        } else {
          jSet(value, name, next);
        }
      }
    }
    return jCall(reviver, [key, value], receiver: holder);
  }

  return walk(JObject({'': root}), '');
}

dynamic jJSONStringify(dynamic value, dynamic replacer, dynamic space) {
  final active = HashSet<dynamic>.identity();
  List<String>? properties;
  if (replacer is List) {
    properties = [];
    for (var item in replacer) {
      if (item is JBox) item = item.value;
      if (item is String || item is num) {
        final key = jString(item);
        if (!properties.contains(key)) properties.add(key);
      }
    }
  }
  if (space is JBox) space = space.value;
  final gap = space is String
      ? space.substring(0, math.min(space.length, 10))
      : space is num && !space.isNaN && space > 0
      ? ' ' * math.min(space, 10).floor()
      : '';
  String? serialize(dynamic holder, String key, String indent) {
    var current = jGet(holder, key);
    if (current is JObject) {
      final toJSON = current.get('toJSON');
      if (toJSON is JFunction)
        current = jCall(toJSON, [key], receiver: current);
    }
    if (replacer is JFunction)
      current = jCall(replacer, [key, current], receiver: holder);
    if (current is JBox && current.value is! JSymbol) current = current.value;
    if (current is JFunction ||
        current is JSymbol ||
        identical(current, jUndefined))
      return null;
    if (current == null) return 'null';
    if (current is bool) return '$current';
    if (current is num) return current.isFinite ? jString(current) : 'null';
    if (current is String) return jsonEncode(current);
    if (current is BigInt)
      throw JThrown(JError('TypeError', 'Cannot serialize BigInt'));
    if (current is! JObject && current is! List)
      throw JThrown(JError('TypeError', 'Unsupported JSON value'));
    if (!active.add(current))
      throw JThrown(JError('TypeError', 'Cyclic JSON value'));
    try {
      final nextIndent = indent + gap;
      final parts = <String>[];
      final array = current is List;
      if (array) {
        final length = current.length;
        for (var i = 0; i < length; i++) {
          parts.add(serialize(current, '$i', nextIndent) ?? 'null');
        }
      } else {
        final keys =
            properties ??
            jOwnKeys(current, enumerable: true, strings: true).cast<String>();
        for (final name in keys) {
          final encoded = serialize(current, name, nextIndent);
          if (encoded != null)
            parts.add('${jsonEncode(name)}:${gap.isEmpty ? '' : ' '}$encoded');
        }
      }
      final open = array ? '[' : '{', close = array ? ']' : '}';
      if (parts.isEmpty) return '$open$close';
      return gap.isEmpty
          ? '$open${parts.join(',')}$close'
          : '$open\n$nextIndent${parts.join(',\n$nextIndent')}\n$indent$close';
    } finally {
      active.remove(current);
    }
  }

  return serialize(JObject({'': value}), '', '') ?? jUndefined;
}

const _jHole = Object();
bool jDelete(dynamic object, dynamic key, {bool strict = false}) {
  final property = jPropertyKey(key);
  var success = true;
  if (object is JObject) {
    success = object.remove(property);
  } else if (object is List) {
    if (property == 'length')
      success = false;
    else {
      final index = property is String ? int.tryParse(property) : null;
      if (index != null && index >= 0 && index < object.length)
        object[index] = _jHole;
    }
  }
  if (!success && strict)
    throw JThrown(JError('TypeError', 'Cannot delete property'));
  return success;
}
