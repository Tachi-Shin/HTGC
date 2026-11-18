// HTGC JavaScript semantics implemented in Dart.
import 'dart:math' as math;
import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import 'dart:typed_data';
part 'js_date.dart';
part 'js_proxy.dart';
part 'js_binary.dart';
part 'js_atomics.dart';
part 'js_regexp.dart';
part 'js_regexp_sets.dart';
part 'js_regexp_set_data.dart';
part 'js_generator.dart';
part 'js_array_methods.dart';
part 'js_text_methods.dart';
part 'js_math_methods.dart';
part 'js_function_methods.dart';
part 'js_runtime_eval.dart';
part 'js_byte_encoding.dart';
part 'js_iteration_helpers.dart';
part 'js_iterator_zip.dart';
part 'js_disposal.dart';
part 'js_weakrefs.dart';
part 'js_normalization.dart';
part 'js_unicode_data.dart';

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

// Hosts can observe unhandled promise rejections independently of uncaught throws.
final jPromiseRejectionHook = Object();

class JPromiseCapability {
  late final dynamic promise;
  late final JFunction resolveFunction, rejectFunction;
  JPromiseCapability(dynamic constructor) {
    dynamic resolve = jUndefined, reject = jUndefined;
    final executor = jNamedFunction(jBuiltin((args) {
      if (!identical(resolve, jUndefined) || !identical(reject, jUndefined)) {
        throw JThrown(JError('TypeError', 'Promise capability already initialized'));
      }
      resolve = jArg(args, 0);
      reject = jArg(args, 1);
      return jUndefined;
    }), '', 2);
    promise = jNew(constructor, [executor]);
    if (resolve is! JFunction || reject is! JFunction) {
      throw JThrown(JError('TypeError', 'Invalid promise resolving functions'));
    }
    resolveFunction = resolve;
    rejectFunction = reject;
  }
  void resolve(dynamic value) => jCall(resolveFunction, [value]);
  void reject(dynamic reason) => jCall(rejectFunction, [reason]);
}

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
        if (_handled) return;
        final report = _zone[jPromiseRejectionHook] as void Function(dynamic)?;
        if (report == null) {
          _zone.handleUncaughtError(JThrown(value), StackTrace.current);
        } else {
          report(value);
        }
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

  dynamic then(dynamic fulfilled, [dynamic rejected = jUndefined]) {
    final next = JPromiseCapability(jSpeciesConstructor(this, jPromiseConstructor));
    void reaction(dynamic handler, dynamic value, bool failure) {
      if (handler is JFunction) {
        try {
          value = jCall(handler, [value]);
          failure = false;
        } catch (error) {
          value = jExceptionValue(error);
          failure = true;
        }
      }
      if (failure) { next.reject(value); } else { next.resolve(value); }
    }

    observe(
      (value) => reaction(fulfilled, value, false),
      (error) => reaction(rejected, error, true),
    );
    return next.promise;
  }
}

final JObject jPromisePrototype = JObject({
  'constructor': jPromiseConstructor,
  'then': jBuiltinMethod('then', 2, (a, receiver) {
    if (receiver is! JPromise)
      throw JThrown(JError('TypeError', 'Not a Promise receiver'));
    return receiver.then(jArg(a, 0), jArg(a, 1));
  }),
  'catch': jBuiltinMethod('catch', 1,
    (a, receiver) => jInvoke(receiver, 'then', [jUndefined, jArg(a, 0)]),
  ),
  'finally': jBuiltinMethod('finally', 1, (a, receiver) {
    if (!jIsObject(receiver)) throw JThrown(JError('TypeError', 'Invalid Promise.finally receiver'));
    final constructor = jSpeciesConstructor(receiver, jPromiseConstructor);
    final callback = jArg(a, 0);
    if (callback is! JFunction) return jInvoke(receiver, 'then', [callback, callback]);
    JFunction continuation(bool rejected) => jBuiltin((args) {
      final value = jArg(args, 0);
      final promise = jPromiseResolveWith(constructor, jCall(callback, []));
      return jInvoke(promise, 'then', [jBuiltin((_) {
        if (rejected) throw JThrown(value);
        return value;
      })]);
    });
    return jInvoke(receiver, 'then', [continuation(false), continuation(true)]);
  }),
});

dynamic jPromiseResolveWith(dynamic constructor, dynamic value) {
  if (!jIsObject(constructor)) throw JThrown(JError('TypeError', 'Invalid Promise.resolve receiver'));
  if (value is JPromise && identical(jGet(value, 'constructor'), constructor)) return value;
  final capability = JPromiseCapability(constructor)..resolve(value);
  return capability.promise;
}

JPromise jPromiseResolve(dynamic value) => jPromiseResolveWith(jPromiseConstructor, value) as JPromise;

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

dynamic jPromiseAggregate(String mode, dynamic iterable, dynamic constructor) {
  final result = JPromiseCapability(constructor);
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
    final resolve = jGet(constructor, 'resolve');
    if (resolve is! JFunction) throw JThrown(JError('TypeError', 'Promise resolve method is not callable'));
    jForEachIterable(iterable, (value) {
      final index = values.length;
      values.add(jUndefined);
      remaining++;
      var called = false;
      final next = jCall(resolve, [value], receiver: constructor);
      jInvoke(next, 'then', [
        mode == 'race' || mode == 'any' ? result.resolveFunction : jBuiltin((args) {
          if (!called) {
            called = true;
            final resolved = jArg(args, 0);
            values[index] = mode == 'allSettled'
                ? JObject({'status': 'fulfilled', 'value': resolved}) : resolved;
            finish();
          }
          return jUndefined;
        }),
        mode == 'race' || mode == 'all' ? result.rejectFunction : jBuiltin((args) {
          if (!called) {
            called = true;
            final error = jArg(args, 0);
            values[index] = mode == 'allSettled'
                ? JObject({'status': 'rejected', 'reason': error}) : error;
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
  return result.promise;
}

final JFunction jPromiseConstructor = buildJSPromiseConstructor();

JFunction buildJSPromiseConstructor() {
  final constructor = JFunction(
    (a, receiver) => throw JThrown(JError('TypeError', 'Promise requires new')),
    constructWithTarget: (a, target) {
      final executor = jArg(a, 0);
      if (executor is! JFunction)
        throw JThrown(JError('TypeError', 'Promise executor is not callable'));
      final promise = JPromise()..prototype = jPrototypeFromConstructor(target, jPromisePrototype);
      try {
        jCall(executor, [
          jBuiltinMethod('', 1, (values, _) {
            promise.resolve(jArg(values, 0));
            return jUndefined;
          }),
          jBuiltinMethod('', 1, (errors, _) {
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
    'resolve': jBuiltinMethod('resolve', 1, (a, c) => jPromiseResolveWith(c, jArg(a, 0))),
    'reject': jBuiltinMethod('reject', 1, (a, c) => (JPromiseCapability(c)..reject(jArg(a, 0))).promise),
    for (final mode in ['all', 'allSettled', 'any', 'race'])
      mode: jBuiltinMethod(mode, 1, (a, c) => jPromiseAggregate(mode, jArg(a, 0), c)),
    'withResolvers': jBuiltinMethod('withResolvers', 0, (_, c) {
      final capability = JPromiseCapability(c);
      return JObject({'promise': capability.promise, 'resolve': capability.resolveFunction, 'reject': capability.rejectFunction});
    }),
    'try': jBuiltinMethod('try', 1, (a, c) {
      if (!jIsObject(c)) {
        throw JThrown(JError('TypeError', 'Invalid Promise.try receiver'));
      }
      dynamic value;
      try {
        value = jCall(jArg(a, 0), a.skip(1).toList());
      } catch (error) {
        final capability = JPromiseCapability(c)..reject(jExceptionValue(error));
        return capability.promise;
      }
      return jPromiseResolveWith(c, value);
    }),
  });
  jInstallSpeciesGetter(constructor);
  jNameFunction(constructor, 'Promise', 1);
  jBuiltinProperties(constructor);
  return constructor;
}

void installJSPromises(JScope scope) {
  // Lazily linked to avoid recursive initialization of constructor/prototype.
  jPromiseConstructor.properties['prototype'] = jPromisePrototype;
  jPromiseConstructor.flags['prototype'] = JPropertyFlags(enumerable: false, configurable: false, writable: false);
  final tag = jSymbols['toStringTag']!;
  jPromisePrototype.symbols[tag] = 'Promise';
  jPromisePrototype.flags[tag] = JPropertyFlags(writable: false, enumerable: false);
  jBuiltinProperties(jPromisePrototype);
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
  final bool isGlobalScript;
  final bool _functionEnvironment;
  final Set<String> _lexicalNames = {};
  final Set<String> _deletableNames = {};
  JScope? _evalOwner;
  String? simpleCatchName;
  final Map<String, dynamic> _values = {};
  final Set<String> _constants = {};
  final Map<String, dynamic Function()> _imports = {};
  JModuleGraph? _modules;
  JObject? _globalObject;
  JScope? _scriptScope;
  final _templates = <String, JTemplateArray>{};
  JTemplateArray template(
    String site,
    List<dynamic> cooked,
    List<dynamic> raw,
  ) =>
      parent?.template(site, cooked, raw) ??
      _templates.putIfAbsent(site, () => JTemplateArray(cooked, raw: raw));
  JScope([this.parent]) : isGlobalScript = false, _functionEnvironment = false;
  JScope.function(this.parent) : isGlobalScript = false, _functionEnvironment = true;
  JScope.script(this.parent) : isGlobalScript = true, _functionEnvironment = false {
    root._scriptScope = this;
  }
  JScope get root => parent?.root ?? this;
  JScope get globalScope => isGlobalScript ? this : (parent?.globalScope ?? this);
  JScope get scriptGlobalScope => root._scriptScope ?? root;
  dynamic get globalThisValue => root._globalObject ?? jUndefined;
  dynamic get scriptThis => isGlobalScript ? root._globalObject : jUndefined;
  JModuleGraph modules(Map<String, JModuleDefinition> definitions) =>
      isGlobalScript || parent == null
          ? (_modules ??= JModuleGraph(this, definitions))
          : parent!.modules(definitions);

  void attachGlobal(JObject object) {
    if (parent != null || _globalObject != null) {
      throw StateError('Global object is already attached or scope is nested');
    }
    _globalObject = object;
    for (final entry in _values.entries) {
      defineGlobal(entry.key, entry.value);
    }
    _values.clear();
    defineGlobal('undefined', jUndefined, writable: false, configurable: false);
    defineGlobal('NaN', double.nan, writable: false, configurable: false);
    defineGlobal('Infinity', double.infinity, writable: false, configurable: false);
    defineGlobal('globalThis', object);
  }

  void defineGlobal(String name, dynamic value, {bool writable = true, bool configurable = true, bool enumerable = false}) {
    final object = _globalObject;
    if (parent != null || object == null) {
      throw StateError('A global object has not been attached');
    }
    if (!jDefineProperty(object, name, JObject({
      'value': value, 'writable': writable, 'enumerable': enumerable,
      'configurable': configurable,
    }))) {
      throw JThrown(JError('TypeError', 'Cannot define global property: $name'));
    }
  }

  void reserve(String name) {
    if (_values.containsKey(name) || _imports.containsKey(name)) {
      throw JThrown(JError('SyntaxError', 'Identifier already declared: $name'));
    }
    if (isGlobalScript) {
      final descriptor = jDescriptor(root._globalObject, name);
      if (descriptor is JObject && !jTruthy(jGet(descriptor, 'configurable'))) {
        throw JThrown(JError('SyntaxError', 'Restricted global property: $name'));
      }
    }
    _lexicalNames.add(name);
    _values[name] = _jUninitialized;
  }

  void importBinding(String name, dynamic Function() read) {
    _imports[name] = read;
  }

  JScope get _variableEnvironment => _evalOwner ??
      (_functionEnvironment || isGlobalScript || parent == null ? this : parent!._variableEnvironment);

  // EvalDeclarationInstantiation must validate *all* names before introducing
  // bindings on the caller, including observable global object properties.
  void prepareEval(bool strict, List<String> vars, List<String> functions) {
    final owner = strict ? this : parent!._variableEnvironment;
    _evalOwner = owner;
    if (strict) return;
    final names = {...vars, ...functions};
    for (JScope? env = parent; env != null; env = env.parent) {
      for (final name in names) {
        final conflict = identical(env, owner)
            ? env._lexicalNames.contains(name) || env._imports.containsKey(name)
            : env.simpleCatchName != name && (env._values.containsKey(name) || env._imports.containsKey(name));
        if (conflict) throw JThrown(JError('SyntaxError', 'Eval redeclares lexical binding: $name'));
      }
      if (identical(env, owner)) break;
    }
    final object = owner._declarationObject;
    if (object == null) return;
    for (final name in names) {
      final descriptor = jDescriptor(object, name);
      final allowed = descriptor is! JObject ? object.extensible :
          !functions.contains(name) || jTruthy(descriptor.get('configurable')) ||
          (jTruthy(descriptor.get('writable')) && jTruthy(descriptor.get('enumerable')));
      if (!allowed) throw JThrown(JError('TypeError', 'Cannot declare global binding: $name'));
    }
  }

  JObject? get _declarationObject => isGlobalScript || parent == null ? root._globalObject : null;

  void _declareEval(String name, dynamic value, {required bool function}) {
    final object = _declarationObject;
    if (object != null) {
      final descriptor = jDescriptor(object, name);
      if (descriptor is! JObject || function && jTruthy(descriptor.get('configurable'))) {
        root.defineGlobal(name, value, enumerable: true);
      } else if (function) {
        jSet(object, name, value);
      }
    } else {
      if (!_values.containsKey(name)) {
        _deletableNames.add(name);
        _values[name] = value;
      } else if (function) {
        _values[name] = value;
      }
    }
  }

  bool deleteBinding(String name) {
    if (_values.containsKey(name)) {
      if (!_deletableNames.remove(name)) return false;
      _values.remove(name);
      return true;
    }
    if (_imports.containsKey(name)) return false;
    if (parent != null) return parent!.deleteBinding(name);
    return _globalObject == null || jDelete(_globalObject, name);
  }

  void declareVar(String name) {
    if (_evalOwner != null) {
      _evalOwner!._declareEval(name, jUndefined, function: false);
      return;
    }
    if (isGlobalScript) {
      if (_values.containsKey(name) || _imports.containsKey(name)) {
        throw JThrown(JError('SyntaxError', 'Identifier already declared: $name'));
      }
      final object = root._globalObject!;
      if (!jHasOwn(object, name)) {
        root.defineGlobal(name, jUndefined, enumerable: true, configurable: false);
      }
      return;
    }
    _values.putIfAbsent(name, () => jUndefined);
  }

  void declareFunction(String name, dynamic value) {
    if (_evalOwner != null) {
      _evalOwner!._declareEval(name, value, function: true);
      return;
    }
    if (!isGlobalScript) {
      _values[name] = value;
      return;
    }
    if (_values.containsKey(name) || _imports.containsKey(name)) {
      throw JThrown(JError('SyntaxError', 'Identifier already declared: $name'));
    }
    final object = root._globalObject!;
    if (jHasOwn(object, name)) {
      jSet(object, name, value);
    } else {
      root.defineGlobal(name, value, enumerable: true, configurable: false);
    }
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
        throw JThrown(JError('ReferenceError', '$name is not initialized'));
      }
      return value;
    }
    final read = _imports[name];
    if (read != null) return read();
    if (parent != null) return parent!.get(name);
    final global = _globalObject;
    if (global != null && jHasProperty(global, name)) return jGet(global, name);
    if (name == 'undefined') return jUndefined;
    if (name == 'NaN') return double.nan;
    if (name == 'Infinity') return double.infinity;
    throw JThrown(JError('ReferenceError', '$name is not defined'));
  }

  JScope copyIteration(List<String> names) {
    final copy = JScope(parent);
    for (final name in names) {
      copy.define(name, get(name));
    }
    return copy;
  }

  dynamic getForTypeof(String name) {
    if (_values.containsKey(name) || _imports.containsKey(name)) return get(name);
    if (parent != null) return parent!.getForTypeof(name);
    final global = _globalObject;
    if (global != null && jHasProperty(global, name)) return jGet(global, name);
    if (name == 'NaN') return double.nan;
    if (name == 'Infinity') return double.infinity;
    return jUndefined;
  }

  dynamic put(String name, dynamic value, {bool strict = true}) {
    if (_values.containsKey(name)) {
      if (identical(_values[name], _jUninitialized)) {
        throw JThrown(JError('ReferenceError', '$name is not initialized'));
      }
      if (_constants.contains(name))
        throw JThrown(JError('TypeError', 'Assignment to constant: $name'));
      return _values[name] = value;
    }
    if (_imports.containsKey(name))
      throw JThrown(JError('TypeError', 'Assignment to import: $name'));
    if (parent != null) return parent!.put(name, value, strict: strict);
    final global = _globalObject;
    if (global != null) {
      if (!strict) {
        global.write(name, value, global);
        return value;
      }
      if (jHasProperty(global, name)) return jSet(global, name, value);
    }
    throw JThrown(
      JError('ReferenceError', 'Assignment to undeclared name: $name'),
    );
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
    final existing = jDescriptor(receiver, key);
    if (existing is JObject) {
      if (existing.own('get') || !jTruthy(existing.get('writable')))
        return false;
      return jDefineProperty(
        receiver,
        key,
        JObject({'value': value}),
        normalized: true,
      );
    }
    return jDefineProperty(
      receiver,
      key,
      JObject({
        'value': value,
        'writable': true,
        'enumerable': true,
        'configurable': true,
      }),
      normalized: true,
    );
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
  final proxy = jProxyState(value);
  if (proxy != null)
    return proxy.keys().where((key) {
      if (strings && key is! String) return false;
      if (!enumerable) return true;
      final descriptor = proxy.descriptor(key);
      return descriptor is JObject && descriptor.get('enumerable') == true;
    }).toList();
  if (value is JTypedArray)
    return [
      for (var i = 0; i < value.length; i++) '$i',
      ...jOrdinaryTypedKeys(value, enumerable: enumerable, strings: strings),
    ];
  if (jNullish(value))
    throw JThrown(
      JError('TypeError', 'Cannot convert null or undefined to object'),
    );
  if (value is JModuleNamespace)
    return value.exports.keys.cast<Object>().toList();
  if (value is List || value is String) {
    final extras = value is List ? jArrayExtras(value) : null;
    return [
      for (var i = 0; i < value.length; i++)
        if (value is! List || !identical(value[i], _jHole)) '$i',
      if (!enumerable) 'length',
      if (extras != null)
        ...jOwnKeys(extras, enumerable: enumerable, strings: strings),
    ];
  }
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
    if (object is List && jArrayExtras(object)?.own(key) == true) return true;
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
  final proxy = jProxyState(object);
  if (proxy != null) return proxy.has(key);
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
  final proxy = jProxyState(object);
  if (proxy != null) return proxy.define(key, descriptor);
  if (object is JTypedArray && jTypedIndex(key) != null)
    return object.defineIndex(key, descriptor);
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
  if (object is JMappedArguments) object.propertyDefined(key, descriptor);
  return true;
}

dynamic jDescriptor(dynamic value, Object key) {
  final proxy = jProxyState(value);
  if (proxy != null) return proxy.descriptor(key);
  if (value is List) {
    final extras = jArrayExtras(value);
    if (extras != null && extras.own(key)) return jDescriptor(extras, key);
  }
  if (!jHasOwn(value, key)) return jUndefined;
  if (value is! JObject)
    return JObject({
      'value': jGet(value, key),
      'writable': value is List && value is! JTemplateArray,
      'enumerable': key != 'length',
      'configurable':
          key != 'length' && value is List && value is! JTemplateArray,
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
  final proxy = jProxyState(object);
  if (proxy != null) return proxy.setPrototype(prototype);
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
  'toLocaleString': JFunction(
    (args, receiver) => jInvoke(receiver, 'toString', []),
    constructible: false,
  ),
  'valueOf': JFunction(
    (a, receiver) => receiver is JBox ? receiver.value : receiver,
    constructible: false,
  ),
  'toString': JFunction((a, receiver) {
    if (receiver == null) return '[object Null]';
    if (identical(receiver, jUndefined)) return '[object Undefined]';
    final array = jIsArray(receiver);
    final tag = jGet(receiver, jSymbols['toStringTag']);
    return '[object ${tag is String
        ? tag
        : array
        ? 'Array'
        : receiver is JError
        ? 'Error'
        : receiver is JDate
        ? 'Date'
        : receiver is JRegex
        ? 'RegExp'
        : receiver is JFunction
        ? 'Function'
        : 'Object'}]';
  }, constructible: false),
});

typedef JObjectEntry = (String, Object, dynamic);
JObject jObjectLiteral(List<JObjectEntry> entries) {
  final object = JObject();
  for (final entry in entries) {
    jApplyObjectEntry(object, entry);
  }
  return object;
}

void jApplyObjectEntry(JObject object, JObjectEntry entry) {
  final (kind, key, definition) = entry;
  dynamic value = definition;
  if (definition is JFunction Function(JObject)) {
    final function = definition(object);
    final name = jFunctionKeyName(key);
    function.properties['name'] = kind == 'init' ? name : '$kind $name';
    value = function;
  }
  if (kind == 'get' || kind == 'set') {
    if (!object.accessor(key)) {
      object.getters.remove(key);
      object.setters.remove(key);
    }
    object.store(key, jUndefined);
    object._accessors.add(key);
    (kind == 'get' ? object.getters : object.setters)[key] = value as JFunction;
  } else if (kind == 'prototype') {
    if (value == null || value is JObject) object.prototype = value;
  } else {
    object.getters.remove(key);
    object.setters.remove(key);
    object._accessors.remove(key);
    object.store(key, value);
  }
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
  final bool hasAwait, json;
  const JModuleDefinition(
    this.dependencies,
    this.imports,
    this.exports,
    this.initialize,
    this.execute, {
    this.hasAwait = false,
    this.json = false,
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
  final _metadata = <String, JObject>{};
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

  Uri moduleUrl(String owner) => Uri(scheme: 'htgc', host: 'local', path: '/$owner');

  JObject meta(String key, String owner) => _metadata.putIfAbsent(
    key, () => JObject.root({'url': moduleUrl(owner).toString()}),
  );

  String importType(dynamic options) {
    if (identical(options, jUndefined)) return 'javascript';
    if (!jIsObject(options)) {
      throw JThrown(JError('TypeError', 'Import options must be an object'));
    }
    final attributes = jGet(options, 'with');
    if (identical(attributes, jUndefined)) return 'javascript';
    if (!jIsObject(attributes)) {
      throw JThrown(JError('TypeError', 'Import attributes must be an object'));
    }
    final values = <String, String>{};
    for (final key in jOwnKeys(attributes, enumerable: true, strings: true)) {
      final value = jGet(attributes, key);
      if (value is! String) {
        throw JThrown(JError('TypeError', 'Import attribute values must be strings'));
      }
      values[key as String] = value;
    }
    if (values.isEmpty) return 'javascript';
    if (values.length == 1 && values['type'] == 'json') return 'json';
    throw JThrown(JError('TypeError', 'Unsupported import attributes'));
  }

  JPromise importModule(String owner, dynamic specifier, [dynamic options = jUndefined]) {
    final result = JPromise();
    String key;
    try {
      final text = jString(specifier);
      final type = importType(options);
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
      key = Uri.decodeComponent(moduleUrl(owner).resolveUri(uri).path.substring(1));
      if (definitions[key] case final definition?) {
        if (definition.json != (type == 'json')) {
          throw JThrown(JError('TypeError', 'Module type mismatch: $text'));
        }
      }
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
  final dynamic Function(List<dynamic>, dynamic)? constructWithTarget;
  final bool constructible;
  JFunction(
    this.invoke, {
    this.construct,
    this.constructWithTarget,
    this.constructible = true,
  });
  String? sourceText;

  @override
  JObject? get prototype =>
      _prototype ?? (_nullPrototype ? null : jFunctionPrototype);
}

JFunction jNative(dynamic Function(List<dynamic>) callback) =>
    JFunction((args, receiver) => callback(args));

JFunction jBuiltin(dynamic Function(List<dynamic>) callback) =>
    JFunction((args, receiver) => callback(args), constructible: false);

JFunction jFunction(dynamic Function(List<dynamic>, dynamic, dynamic) body) {
  late final JFunction function;
  function = JFunction(
    (args, receiver) => body(args, receiver, jUndefined),
    constructWithTarget: (arguments, newTarget) {
      final prototype = jGet(newTarget, 'prototype');
      final instance = JObject()
        ..prototype = prototype is JObject ? prototype : jObjectPrototype;
      final result = body(arguments, instance, newTarget);
      return result is JObject || result is List ? result : instance;
    },
  );
  final prototype = JObject({'constructor': function});
  prototype.flags['constructor'] = JPropertyFlags(enumerable: false);
  function.properties['prototype'] = prototype;
  function.flags['prototype'] = JPropertyFlags(
    enumerable: false,
    configurable: false,
  );
  return function;
}

JFunction jNamedFunction(
  JFunction function,
  String name,
  int length, {
  String? source,
}) {
  if (source != null) function.sourceText = source;
  jNameFunction(function, name, length);
  return function;
}

class JClass extends JFunction {
  JFunction? body;
  final privateMethods = <JPrivateName>[];
  final fields = <void Function(dynamic)>[];

  JClass(dynamic Function(List<dynamic>, dynamic) construct)
    : super(
        (args, receiver) => throw JThrown(
          JError('TypeError', 'Class constructor requires new'),
        ),
        constructWithTarget: construct,
      );

  void attach(JObject instance) {
    instance.prototype = properties['prototype'] as JObject;
  }
}

JClass jDefaultClass(
  String name,
  dynamic base, {
  required bool derived,
  String? source,
}) {
  final constructor = base is JFunction && base.constructible ? base : null;
  if (derived && base != null && constructor == null) {
    throw JThrown(JError('TypeError', 'Class extends a non-constructor'));
  }
  final parentPrototype = !derived
      ? jObjectPrototype
      : constructor == null
      ? null
      : jGet(constructor, 'prototype');
  if (parentPrototype != null && parentPrototype is! JObject) {
    throw JThrown(JError('TypeError', 'Invalid superclass prototype'));
  }
  final prototype = JObject()..prototype = parentPrototype;
  late final JClass classFunction;
  classFunction = JClass((args, newTarget) {
    final context = JConstruction(classFunction, newTarget);
    if (!derived) {
      context.initialize(
        JObject()
          ..prototype = jPrototypeFromConstructor(newTarget, jObjectPrototype),
      );
    }
    final body = classFunction.body;
    if (body == null)
      return derived ? context.callSuper(args) : context.thisValue;
    final result = jCall(body, args, receiver: context);
    if (jIsObject(result)) return result;
    if (derived && !identical(result, jUndefined)) {
      throw JThrown(
        JError(
          'TypeError',
          'Derived constructor must return an object or undefined',
        ),
      );
    }
    return context.thisValue;
  });
  if (constructor != null) classFunction.prototype = constructor;
  classFunction.properties['prototype'] = prototype;
  classFunction.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  prototype.properties['constructor'] = classFunction;
  prototype.flags['constructor'] = JPropertyFlags(enumerable: false);
  jNamedFunction(classFunction, name, 0, source: source);
  return classFunction;
}

JObject jPrototypeFromConstructor(dynamic newTarget, JObject fallback) {
  final prototype = jGet(newTarget, 'prototype');
  return prototype is JObject ? prototype : fallback;
}

JObject Function(List<dynamic>, dynamic) jBuiltinAllocator(
  JObject fallback,
  JObject Function(List<dynamic>) allocate,
) => (args, newTarget) {
  final prototype = jPrototypeFromConstructor(newTarget, fallback);
  return allocate(args)..prototype = prototype;
};

void jDefineClassMethod(
  JFunction constructor,
  bool isStatic,
  String kind,
  Object key,
  JFunction method,
) {
  final owner = isStatic
      ? constructor
      : constructor.properties['prototype'] as JObject;
  final name = key is JSymbol ? '[${key.description ?? ''}]' : key as String;
  jNameFunction(
    method,
    kind == 'init' ? name : '$kind $name',
    (method.properties['length'] as num).toInt(),
  );
  jApplyObjectEntry(owner, (kind, key, method));
  owner.flags[key] = JPropertyFlags(enumerable: false);
}

class JRef {
  final dynamic Function() read;
  final dynamic Function(dynamic) write;
  JRef(this.read, this.write);
  factory JRef.scope(JScope scope, String key, {bool strict = true}) =>
      JRef(() => scope.get(key), (v) => scope.put(key, v, strict: strict));
  factory JRef.member(dynamic object, dynamic key) =>
      JRef(() => jGet(object, key), (v) => jSet(object, key, v));
}

bool jTruthy(dynamic v) {
  if (jNullish(v) || identical(v, jShortCircuit)) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is BigInt) return v != BigInt.zero;
  if (v is String) return v.isNotEmpty;
  return true;
}

String jString(dynamic v) {
  if (identical(v, jUndefined)) return 'undefined';
  if (v == null) return 'null';
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
  if (v is num) return jNumberString(v.toDouble());
  return v.toString();
}

double jNumber(dynamic v) {
  if (v == null) return 0.0;
  if (identical(v, jUndefined)) return double.nan;
  if (v is num) return v.toDouble();
  if (v is bool) return v ? 1.0 : 0.0;
  if (v is JSymbol || v is BigInt)
    throw JThrown(
      JError(
        'TypeError',
        'Cannot implicitly convert Symbol or BigInt to Number',
      ),
    );
  if (v is JObject || v is List) return jNumber(jPrimitive(v, hint: 'number'));
  final text = jTrim(jString(v));
  if (text.isEmpty) return 0.0;
  final radix = jRadixInteger(text);
  if (radix != null) return radix.toDouble();
  if (!RegExp(
    r'^[+-]?(?:Infinity|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)$',
  ).hasMatch(text))
    return double.nan;
  return double.tryParse(text) ?? double.nan;
}

int jRelativeIndex(dynamic value, int length) {
  final numeric = jNumber(value);
  if (numeric.isNaN) return 0;
  if (numeric == double.infinity) return length;
  if (numeric == double.negativeInfinity) return 0;
  final index = numeric.truncate();
  return (index < 0 ? length + index : index).clamp(0, length);
}

// ECMA-262 StringNumericLiteral whitespace (not Dart's broader trim set).
final _jWhitespace = RegExp(
  r'^[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\u0009-\u000d\u0020\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
);
String jTrim(String value) => value.replaceAll(_jWhitespace, '');

BigInt? jRadixInteger(String text) {
  if (RegExp(r'^0[xX][0-9a-fA-F]+$').hasMatch(text))
    return BigInt.parse(text.substring(2), radix: 16);
  if (RegExp(r'^0[oO][0-7]+$').hasMatch(text))
    return BigInt.parse(text.substring(2), radix: 8);
  if (RegExp(r'^0[bB][01]+$').hasMatch(text))
    return BigInt.parse(text.substring(2), radix: 2);
  return null;
}

BigInt? jStringBigInt(String value) {
  final text = jTrim(value);
  if (text.isEmpty) return BigInt.zero;
  return jRadixInteger(text) ??
      (RegExp(r'^[+-]?[0-9]+$').hasMatch(text) ? BigInt.tryParse(text) : null);
}

dynamic jNumeric(dynamic value) {
  final primitive = jPrimitive(value, hint: 'number');
  return primitive is BigInt ? primitive : jNumber(primitive);
}

BigInt jBigInt(dynamic value, {bool allowNumber = false}) {
  value = jPrimitive(value, hint: 'number');
  if (value is BigInt) return value;
  if (value is bool) return value ? BigInt.one : BigInt.zero;
  if (value is String) {
    final parsed = jStringBigInt(value);
    if (parsed != null) return parsed;
    throw JThrown(JError('SyntaxError', 'Invalid BigInt string'));
  }
  if (allowNumber && value is num) {
    if (!value.isFinite || value != value.truncateToDouble())
      throw JThrown(JError('RangeError', 'BigInt requires an integral Number'));
    return BigInt.from(value);
  }
  throw JThrown(JError('TypeError', 'Cannot convert value to BigInt'));
}

String jNumberString(double value) {
  if (value.isNaN) return 'NaN';
  if (value == 0) return '0';
  if (value.isInfinite) return value.isNegative ? '-Infinity' : 'Infinity';
  final sign = value.isNegative ? '-' : '';
  final parts = value.abs().toString().toLowerCase().split('e');
  final mantissa = parts[0];
  var point =
      (mantissa.contains('.') ? mantissa.indexOf('.') : mantissa.length) +
      (parts.length == 2 ? int.parse(parts[1]) : 0);
  var digits = mantissa.replaceAll('.', '');
  while (digits.startsWith('0')) {
    digits = digits.substring(1);
    point--;
  }
  digits = digits.replaceFirst(RegExp(r'0+$'), '');
  if (point > 0 && point <= 21) {
    return sign +
        (point >= digits.length
            ? digits + '0' * (point - digits.length)
            : '${digits.substring(0, point)}.${digits.substring(point)}');
  }
  if (point <= 0 && point > -6) return '${sign}0.${'0' * -point}$digits';
  final exponent = point - 1;
  return '$sign${digits[0]}${digits.length == 1 ? '' : '.${digits.substring(1)}'}e${exponent >= 0 ? '+' : ''}$exponent';
}

// Exact binary64 fraction, used for radix conversion and decimal rounding.
(BigInt, BigInt) jDoubleFraction(double value) {
  final data = ByteData(8)..setFloat64(0, value.abs());
  final high = data.getUint32(0), low = data.getUint32(4);
  final exponent = (high >> 20) & 0x7ff;
  var numerator = (BigInt.from(high & 0xfffff) << 32) | BigInt.from(low);
  if (exponent != 0) numerator |= BigInt.one << 52;
  final power = (exponent == 0 ? 1 : exponent) - 1075;
  return power >= 0
      ? (numerator << power, BigInt.one)
      : (numerator, BigInt.one << -power);
}

String jNumberRadix(double value, int radix) {
  final (numerator, denominator) = jDoubleFraction(value);
  var integer = numerator ~/ denominator;
  var remainder = numerator % denominator;
  final digits = <int>[];
  final base = BigInt.from(radix);
  // Half an ULP at this value. At exact powers of two the lower interval
  // is narrower; use that bound on both sides to avoid premature rounding.
  final data = ByteData(8)..setFloat64(0, value.abs());
  final high = data.getUint32(0), low = data.getUint32(4);
  final exponent = (high >> 20) & 0x7ff;
  final power =
      (exponent == 0 ? 1 : exponent) -
      1076 -
      (exponent > 1 && (high & 0xfffff) == 0 && low == 0 ? 1 : 0);
  var tolerance = power >= 0 ? denominator << power : denominator;
  final scale = power >= 0 ? BigInt.one : BigInt.one << -power;
  while (remainder != BigInt.zero) {
    remainder *= base;
    digits.add((remainder ~/ denominator).toInt());
    remainder %= denominator;
    tolerance *= base;
    final down = remainder * scale <= tolerance;
    final up = (denominator - remainder) * scale <= tolerance;
    if (down || up) {
      if (up && (!down || remainder * BigInt.two > denominator)) {
        var i = digits.length - 1;
        while (i >= 0 && digits[i] == radix - 1) {
          digits[i--] = 0;
        }
        if (i < 0) {
          integer += BigInt.one;
        } else {
          digits[i]++;
        }
      }
      break;
    }
  }
  while (digits.isNotEmpty && digits.last == 0) {
    digits.removeLast();
  }
  const alphabet = '0123456789abcdefghijklmnopqrstuvwxyz';
  return '${value.isNegative ? '-' : ''}${integer.toRadixString(radix)}${digits.isEmpty ? '' : '.${digits.map((d) => alphabet[d]).join()}'}';
}

(String, int) jDecimalDigits(double value, int precision) {
  if (value == 0) return ('0' * precision, 0);
  var exponent = int.parse(value.abs().toStringAsExponential().split('e')[1]);
  var (n, d) = jDoubleFraction(value);
  final power = precision - 1 - exponent;
  if (power >= 0) {
    n *= BigInt.from(10).pow(power);
  } else {
    d *= BigInt.from(10).pow(-power);
  }
  var digits = ((n * BigInt.two + d) ~/ (d * BigInt.two)).toString();
  if (digits.length > precision) {
    digits = digits.substring(0, precision);
    exponent++;
  }
  return (digits.padLeft(precision, '0'), exponent);
}

int jUint32(dynamic value) {
  final number = jNumber(value);
  if (!number.isFinite || number == 0) return 0;
  return (BigInt.from(number) & BigInt.from(0xffffffff)).toInt();
}

int jInt32(dynamic value) => jSigned32(jUint32(value));
int jSigned32(int value) {
  final bits = value & 0xffffffff;
  return bits >= 0x80000000 ? bits - 0x100000000 : bits;
}

bool jStrictEqual(dynamic a, dynamic b) {
  if (a is num && b is num) return a == b;
  if (a is BigInt && b is BigInt) return a == b;
  return a.runtimeType == b.runtimeType && a == b;
}

bool jLooseEqual(dynamic a, dynamic b) {
  if (jStrictEqual(a, b)) return true;
  if (jNullish(a) || jNullish(b)) return jNullish(a) && jNullish(b);
  if (a is num && b is String) return jLooseEqual(a, jNumber(b));
  if (a is String && b is num) return jLooseEqual(jNumber(a), b);
  if (a is BigInt && b is String) return a == jStringBigInt(b);
  if (a is String && b is BigInt) return jStringBigInt(a) == b;
  if (a is bool) return jLooseEqual(jNumber(a), b);
  if (b is bool) return jLooseEqual(a, jNumber(b));
  final aObject = a is JObject || a is List;
  final bObject = b is JObject || b is List;
  if (aObject != bObject)
    return aObject
        ? jLooseEqual(jPrimitive(a), b)
        : jLooseEqual(a, jPrimitive(b));
  if (a is BigInt && b is num)
    return b.isFinite && b == b.truncateToDouble() && a == BigInt.from(b);
  if (a is num && b is BigInt) return jLooseEqual(b, a);
  return false;
}

int? jBigIntCompare(BigInt a, num b) {
  if (b.isNaN) return null;
  if (b.isInfinite) return b.isNegative ? 1 : -1;
  final truncated = BigInt.from(b);
  final result = a.compareTo(truncated);
  if (result != 0 || b == b.truncateToDouble()) return result;
  return b.isNegative ? 1 : -1;
}

int? jCompare(dynamic a, dynamic b) {
  // Relational operators always coerce the left source operand first.
  a = jPrimitive(a, hint: 'number');
  b = jPrimitive(b, hint: 'number');
  if (a is String && b is String) return a.compareTo(b);
  if (a is BigInt && b is String) {
    b = jStringBigInt(b);
    if (b == null) return null;
  }
  if (a is String && b is BigInt) {
    a = jStringBigInt(a);
    if (a == null) return null;
  }
  a = jNumeric(a);
  b = jNumeric(b);
  if (a is BigInt && b is BigInt) return a.compareTo(b);
  if (a is BigInt) return jBigIntCompare(a, b);
  if (b is BigInt) {
    final result = jBigIntCompare(b, a);
    return result == null ? null : -result;
  }
  if (a.isNaN || b.isNaN) return null;
  return a == b
      ? 0
      : a < b
      ? -1
      : 1;
}

dynamic jNumericBinary(String op, dynamic a, dynamic b) {
  a = jNumeric(a);
  b = jNumeric(b);
  if ((a is BigInt) != (b is BigInt))
    throw JThrown(JError('TypeError', 'Cannot mix BigInt and Number'));
  if (a is BigInt && b is BigInt) {
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '*':
        return a * b;
      case '/':
      case '%':
        if (b == BigInt.zero)
          throw JThrown(JError('RangeError', 'BigInt division by zero'));
        return op == '/' ? a ~/ b : a.remainder(b);
      case '**':
        if (b.isNegative)
          throw JThrown(JError('RangeError', 'Negative BigInt exponent'));
        if (b == BigInt.zero) return BigInt.one;
        if (a == BigInt.zero || a == BigInt.one) return a;
        if (a == -BigInt.one) return b.isEven ? BigInt.one : -BigInt.one;
        if (b > BigInt.from(10000000) || a.bitLength * b.toInt() > 10000000)
          throw JThrown(
            JError('RangeError', 'BigInt exceeds implementation size limit'),
          );
        return a.pow(b.toInt());
      case '&':
        return a & b;
      case '|':
        return a | b;
      case '^':
        return a ^ b;
      case '>>>':
        throw JThrown(
          JError('TypeError', 'BigInt has no unsigned right shift'),
        );
      case '<<':
      case '>>':
        final left = op == '<<' ? !b.isNegative : b.isNegative;
        final count = b.abs();
        if (a == BigInt.zero) return a;
        if (!left && count >= BigInt.from(a.bitLength + 1))
          return a.isNegative ? -BigInt.one : BigInt.zero;
        if (count > BigInt.from(10000000) ||
            left && a.bitLength + count.toInt() > 10000000)
          throw JThrown(
            JError('RangeError', 'BigInt exceeds implementation size limit'),
          );
        return left ? a << count.toInt() : a >> count.toInt();
    }
  }
  final x = a as double, y = b as double;
  switch (op) {
    case '+':
      return x + y;
    case '-':
      return x - y;
    case '*':
      return x * y;
    case '/':
      return x / y;
    case '%':
      return x.remainder(y);
    case '**':
      if (y.isNaN) return double.nan;
      if (y == 0) return 1.0;
      if (x.abs() == 1 && y.isInfinite) return double.nan;
      return math.pow(x, y).toDouble();
    case '&':
      return (jInt32(x) & jInt32(y)).toDouble();
    case '|':
      return (jInt32(x) | jInt32(y)).toDouble();
    case '^':
      return (jInt32(x) ^ jInt32(y)).toDouble();
    case '<<':
      return jSigned32(jInt32(x) << (jUint32(y) & 31)).toDouble();
    case '>>':
      return (jInt32(x) >> (jUint32(y) & 31)).toDouble();
    case '>>>':
      return (jUint32(x) >> (jUint32(y) & 31)).toDouble();
  }
  throw StateError('Numeric operator $op');
}

double jInteger(dynamic value) {
  final number = jNumber(value);
  return number.isNaN || number == 0 ? 0.0 : number.truncateToDouble();
}

final JObject jNumberPrototype = JObject();
final JObject jBigIntPrototype = JObject();
final JObject jStringPrototype = JObject();
final JObject jBooleanPrototype = JObject();

void installJSPrimitiveWrappers(JScope scope) {
  dynamic stringValue(List<dynamic> a, {bool construct = false}) => a.isEmpty
      ? ''
      : !construct && a[0] is JSymbol
      ? (a[0] as JSymbol).descriptive
      : jString(a[0]);
  final string = JFunction(
    (a, _) => stringValue(a),
    constructWithTarget: (a, target) => JBox(stringValue(a, construct: true))
      ..prototype = jPrototypeFromConstructor(target, jStringPrototype),
  );
  string.properties['raw'] = jNamedFunction(jBuiltin(jStringRaw), 'raw', 1);
  string.properties['fromCharCode'] = jBuiltin(
    (a) => String.fromCharCodes(a.map((v) => jUint32(v) & 0xffff)),
  );
  string.properties['fromCodePoint'] = jBuiltin(
    (a) => String.fromCharCodes(
      a.map((v) {
        final code = jNumber(v);
        if (!code.isFinite ||
            code < 0 ||
            code > 0x10ffff ||
            code != code.truncateToDouble())
          throw JThrown(JError('RangeError', 'Invalid code point'));
        return code.toInt();
      }),
    ),
  );
  final boolean = JFunction(
    (a, _) => jTruthy(jArg(a, 0)),
    constructWithTarget: (a, target) => JBox(jTruthy(jArg(a, 0)))
      ..prototype = jPrototypeFromConstructor(target, jBooleanPrototype),
  );
  for (final isString in [true, false]) {
    final prototype = isString ? jStringPrototype : jBooleanPrototype;
    final constructor = isString ? string : boolean;
    prototype.properties['constructor'] = constructor;
    constructor.properties['prototype'] = prototype;
    constructor.flags['prototype'] = JPropertyFlags(
      writable: false,
      enumerable: false,
      configurable: false,
    );
    for (final method in ['toString', 'valueOf']) {
      final function = JFunction((a, receiver) {
        final value = identical(receiver, prototype)
            ? (isString ? '' : false)
            : receiver is JBox
            ? receiver.value
            : receiver;
        if (isString ? value is! String : value is! bool)
          throw JThrown(
            JError('TypeError', 'Incompatible primitive wrapper receiver'),
          );
        return method == 'toString' ? jString(value) : value;
      }, constructible: false);
      jNameFunction(function, method, 0);
      prototype.properties[method] = function;
    }
    jBuiltinProperties(prototype);
    jNameFunction(constructor, isString ? 'String' : 'Boolean', 1);
  }
  jStringPrototype.symbols[jSymbols['iterator']!] = JFunction((_, receiver) {
    final value = receiver is JBox ? receiver.value : receiver;
    if (value is! String) {
      throw JThrown(JError('TypeError', 'String iterator requires a string'));
    }
    return jBuiltinIterator(value);
  }, constructible: false);
  jStringPrototype.properties.addAll(jStringMethods);
  jBuiltinProperties(jStringPrototype);
  jStringPrototype.properties['length'] = 0;
  jStringPrototype.flags['length'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  scope.define('String', string);
  scope.define('Boolean', boolean);
}

dynamic jNumericReceiver(dynamic receiver, bool bigint) {
  final value = receiver is JBox ? receiver.value : receiver;
  if (bigint ? value is BigInt : value is num) return value;
  if (!bigint && identical(receiver, jNumberPrototype)) return 0.0;
  throw JThrown(JError('TypeError', 'Incompatible numeric receiver'));
}

double jParseInt(dynamic value, dynamic radixValue) {
  var text = jTrim(jString(value));
  final negative = text.startsWith('-');
  if (text.startsWith('+') || negative) text = text.substring(1);
  var radix = jInt32(radixValue);
  if (radix != 0 && (radix < 2 || radix > 36)) return double.nan;
  final stripPrefix = radix == 0 || radix == 16;
  if (radix == 0) radix = 10;
  if (stripPrefix && (text.startsWith('0x') || text.startsWith('0X'))) {
    text = text.substring(2);
    radix = 16;
  }
  var count = 0;
  const digits = '0123456789abcdefghijklmnopqrstuvwxyz';
  for (final code in text.toLowerCase().codeUnits) {
    final digit = digits.indexOf(String.fromCharCode(code));
    if (digit < 0 || digit >= radix) break;
    count++;
  }
  if (count == 0) return double.nan;
  final result = BigInt.parse(
    text.substring(0, count),
    radix: radix,
  ).toDouble();
  return negative ? -result : result;
}

double jParseFloat(dynamic value) {
  final match = RegExp(
    r'^[+-]?(?:Infinity|(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)',
  ).firstMatch(jTrim(jString(value)));
  return match == null ? double.nan : double.parse(match[0]!);
}

void installJSNumbers(JScope scope) {
  final parseInt = jBuiltin((a) => jParseInt(jArg(a, 0), jArg(a, 1)));
  final parseFloat = jBuiltin((a) => jParseFloat(jArg(a, 0)));
  dynamic numberValue(List<dynamic> a) {
    if (a.isEmpty) return 0.0;
    final value = jNumeric(a[0]);
    return value is BigInt ? value.toDouble() : value;
  }

  final number = JFunction(
    (a, _) => numberValue(a),
    constructWithTarget: (a, target) => JBox(numberValue(a))
      ..prototype = jPrototypeFromConstructor(target, jNumberPrototype),
  );
  number.properties.addAll({
    'prototype': jNumberPrototype,
    'name': 'Number',
    'length': 1,
    'EPSILON': 2.220446049250313e-16,
    'MAX_VALUE': 1.7976931348623157e308,
    'MIN_VALUE': 5e-324,
    'MAX_SAFE_INTEGER': 9007199254740991.0,
    'MIN_SAFE_INTEGER': -9007199254740991.0,
    'NaN': double.nan,
    'POSITIVE_INFINITY': double.infinity,
    'NEGATIVE_INFINITY': double.negativeInfinity,
    'isNaN': jBuiltin((a) => jArg(a, 0) is num && (a[0] as num).isNaN),
    'isFinite': jBuiltin((a) => jArg(a, 0) is num && (a[0] as num).isFinite),
    'isInteger': jBuiltin(
      (a) =>
          jArg(a, 0) is num &&
          (a[0] as num).isFinite &&
          a[0] == (a[0] as num).truncateToDouble(),
    ),
    'isSafeInteger': jBuiltin(
      (a) =>
          jArg(a, 0) is num &&
          (a[0] as num).isFinite &&
          a[0] == (a[0] as num).truncateToDouble() &&
          (a[0] as num).abs() <= 9007199254740991,
    ),
    'parseInt': parseInt,
    'parseFloat': parseFloat,
  });
  final bigint = JFunction(
    (a, _) => jBigInt(jArg(a, 0), allowNumber: true),
    construct: (_) =>
        throw JThrown(JError('TypeError', 'BigInt cannot be called with new')),
  );
  bigint.properties.addAll({
    'prototype': jBigIntPrototype,
    'name': 'BigInt',
    'length': 1,
  });
  for (final signed in [false, true]) {
    bigint.properties[signed ? 'asIntN' : 'asUintN'] = JFunction((a, _) {
      final bits = jInteger(jArg(a, 0));
      if (bits < 0 || bits > 9007199254740991)
        throw JThrown(JError('RangeError', 'Invalid BigInt bit width'));
      final value = jBigInt(jArg(a, 1));
      if (bits == 0) return BigInt.zero;
      if (value == BigInt.zero ||
          (signed
              ? value.bitLength < bits
              : !value.isNegative && value.bitLength <= bits))
        return value;
      if (bits > 10000000)
        throw JThrown(
          JError('RangeError', 'BigInt exceeds implementation size limit'),
        );
      final modulus = BigInt.one << bits.toInt();
      final result = value % modulus;
      return signed && result >= (modulus >> 1) ? result - modulus : result;
    }, constructible: false);
  }
  for (final big in [false, true]) {
    final prototype = big ? jBigIntPrototype : jNumberPrototype;
    prototype.properties['constructor'] = big ? bigint : number;
    prototype.properties['valueOf'] = JFunction(
      (a, receiver) => jNumericReceiver(receiver, big),
      constructible: false,
    );
    prototype.properties['toString'] = JFunction((a, receiver) {
      final value = jNumericReceiver(receiver, big);
      final radix = identical(jArg(a, 0), jUndefined) ? 10.0 : jInteger(a[0]);
      if (radix < 2 || radix > 36)
        throw JThrown(JError('RangeError', 'Radix must be between 2 and 36'));
      if (big) return (value as BigInt).toRadixString(radix.toInt());
      if (radix == 10 || !(value as num).isFinite || value == 0)
        return jString(value);
      return jNumberRadix(value.toDouble(), radix.toInt());
    }, constructible: false);
    prototype.properties['toLocaleString'] = JFunction(
      (args, receiver) => jString(jNumericReceiver(receiver, big)),
      constructible: false,
    );
    jBuiltinProperties(prototype);
  }
  jBigIntPrototype.symbols[jSymbols['toStringTag']!] = 'BigInt';
  jBigIntPrototype.flags[jSymbols['toStringTag']!] = JPropertyFlags(
    writable: false,
    enumerable: false,
  );
  for (final method in ['toFixed', 'toExponential', 'toPrecision']) {
    jNumberPrototype.properties[method] = JFunction((a, receiver) {
      final value = (jNumericReceiver(receiver, false) as num).toDouble();
      final omitted = identical(jArg(a, 0), jUndefined);
      if (method == 'toPrecision' && omitted) return jString(value);
      final digits = jInteger(jArg(a, 0));
      if (method != 'toFixed' && !value.isFinite) return jString(value);
      if (digits < (method == 'toPrecision' ? 1 : 0) || digits > 100)
        throw JThrown(JError('RangeError', 'Invalid precision'));
      if (!value.isFinite) return jString(value);
      final positive = value == 0 ? 0.0 : value;
      if (method == 'toFixed') {
        if (value.abs() >= 1e21) return jString(value);
        final (n, d) = jDoubleFraction(value);
        final scaled = n * BigInt.from(10).pow(digits.toInt());
        final rounded = (scaled * BigInt.two + d) ~/ (d * BigInt.two);
        final text = rounded.toString().padLeft(digits.toInt() + 1, '0');
        final point = text.length - digits.toInt();
        return '${value < 0 ? '-' : ''}${text.substring(0, point)}${digits == 0 ? '' : '.${text.substring(point)}'}';
      }
      if (method == 'toExponential' && omitted)
        return positive.toStringAsExponential().replaceFirst(
          RegExp(r'\.0e'),
          'e',
        );
      final precision = digits.toInt() + (method == 'toExponential' ? 1 : 0);
      final (decimal, exponent) = jDecimalDigits(positive, precision);
      final sign = value < 0 ? '-' : '';
      if (method == 'toExponential' || exponent < -6 || exponent >= precision) {
        return '$sign${decimal[0]}${decimal.length == 1 ? '' : '.${decimal.substring(1)}'}e${exponent >= 0 ? '+' : ''}$exponent';
      }
      if (exponent < 0) return '${sign}0.${'0' * (-exponent - 1)}$decimal';
      final point = exponent + 1;
      return sign +
          (point >= decimal.length
              ? decimal + '0' * (point - decimal.length)
              : '${decimal.substring(0, point)}.${decimal.substring(point)}');
    }, constructible: false);
  }
  jBuiltinProperties(jNumberPrototype);
  jBuiltinProperties(bigint);
  jBuiltinProperties(number);
  for (final constructor in [bigint, number]) {
    for (final key in ['name', 'length']) {
      constructor.flags[key] = JPropertyFlags(
        writable: false,
        enumerable: false,
      );
    }
    for (final key in constructor.properties.keys) {
      final method = constructor.properties[key];
      if (method is JFunction)
        jNameFunction(
          method,
          key,
          key == 'asIntN' || key == 'asUintN' || key == 'parseInt' ? 2 : 1,
        );
    }
  }
  for (final prototype in [jNumberPrototype, jBigIntPrototype]) {
    for (final key in prototype.properties.keys) {
      final method = prototype.properties[key];
      if (method is JFunction && key != 'constructor')
        jNameFunction(
          method,
          key,
          key == 'valueOf' ||
                  identical(prototype, jBigIntPrototype) && key == 'toString'
              ? 0
              : 1,
        );
    }
  }
  for (final key in [
    'EPSILON',
    'MAX_VALUE',
    'MIN_VALUE',
    'MAX_SAFE_INTEGER',
    'MIN_SAFE_INTEGER',
    'NaN',
    'POSITIVE_INFINITY',
    'NEGATIVE_INFINITY',
    'prototype',
  ]) {
    number.flags[key] = JPropertyFlags(
      writable: false,
      enumerable: false,
      configurable: false,
    );
  }
  bigint.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  scope.define('Number', number);
  scope.define('BigInt', bigint);
  scope.define('parseInt', parseInt);
  scope.define('parseFloat', parseFloat);
  scope.define('isNaN', jBuiltin((a) => jNumber(jArg(a, 0)).isNaN));
  scope.define('isFinite', jBuiltin((a) => jNumber(jArg(a, 0)).isFinite));
}

String jFunctionKeyName(dynamic key) => key is JSymbol
    ? (key.description == null ? '' : '[${key.description}]')
    : key as String;

void jNameFunction(JFunction function, String name, int length) {
  function.properties.addAll({'name': name, 'length': length});
  for (final key in ['name', 'length']) {
    function.flags[key] = JPropertyFlags(writable: false, enumerable: false);
  }
}

double jMathRound(double value) {
  if (!value.isFinite || value == 0) return value;
  if (value >= -0.5 && value < 0) return -0.0;
  final floor = value.floorToDouble();
  return value - floor < 0.5 ? floor : floor + 1;
}

double jHypot(List<dynamic> arguments) {
  final values = arguments.map(jNumber).map((v) => v.abs()).toList();
  if (values.any((v) => v.isInfinite)) return double.infinity;
  if (values.any((v) => v.isNaN)) return double.nan;
  final largest = values.fold<double>(0.0, math.max);
  if (largest == 0) return 0.0;
  var sum = 0.0, correction = 0.0;
  for (final value in values) {
    final scaled = value / largest;
    final term = scaled * scaled - correction;
    final next = sum + term;
    correction = (next - sum) - term;
    sum = next;
  }
  return math.sqrt(sum) * largest;
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
dynamic jNew(dynamic constructor, List<dynamic> args, {dynamic newTarget}) {
  newTarget ??= constructor;
  if (constructor is JBoundFunction && constructor.constructible) {
    return jNew(
      constructor.target,
      [...constructor._boundArguments, ...args],
      newTarget: identical(constructor, newTarget)
          ? constructor.target
          : newTarget,
    );
  }
  if (constructor is JProxyFunction) {
    if (!constructor.constructible) jProxyError('Not a constructor');
    return constructor.proxy.construct(args, newTarget);
  }
  if (constructor is JFunction) {
    if (!constructor.constructible)
      throw JThrown(JError('TypeError', 'Not a constructor'));
    if (constructor.constructWithTarget != null)
      return constructor.constructWithTarget!(args, newTarget);
    if (!identical(newTarget, constructor))
      throw UnsupportedError(
        'Custom newTarget for built-in constructors is not implemented',
      );
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
  if (value is List) {
    final extras = jArrayExtras(value);
    if (extras != null && extras.own(property))
      return extras.read(property, value);
  }
  if (property is JSymbol) {
    if (value is JObject) return value.read(property, value);
    if (value is BigInt) return jBigIntPrototype.read(property, value);
    if (value is num) return jNumberPrototype.read(property, value);
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
    final method = jArrayMethods[name];
    if (method != null) return method;
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
          if (value is JTemplateArray) jSet(value, 'length', value.length);
          value.addAll(a);
          return value.length;
        });
      case 'pop':
        return jNative((a) {
          if (value is JTemplateArray) jSet(value, 'length', value.length);
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

    }
  }
  if (value is String) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null && '$i' == name)
      return i >= 0 && i < value.length && !identical(value[i], _jHole)
          ? value[i]
          : jUndefined;
    final method = jStringMethods[name];
    if (method != null) return method;
    switch (name) {
      case 'split':
      case 'match':
      case 'matchAll':
      case 'replace':
      case 'replaceAll':
      case 'search':
        return jBuiltin((a) => jStringRegExp(name, value, a));
    }
  }
  if (value is String) return jStringPrototype.read(name, value);
  if (value is JSymbol) {
    if (name == 'description') return value.description ?? jUndefined;
    if (name == 'toString') return jNative((_) => value.descriptive);
    if (name == 'valueOf') return jNative((_) => value);
  }
  if (value is num) return jNumberPrototype.read(name, value);
  if (value is BigInt) return jBigIntPrototype.read(name, value);
  if (value is bool) return jBooleanPrototype.read(name, value);
  return jUndefined;
}

int? jArrayIndex(String name) {
  final index = int.tryParse(name);
  return index != null && index >= 0 && index < 4294967295 && '$index' == name
      ? index
      : null;
}

dynamic jSet(dynamic value, dynamic key, dynamic assigned) {
  final property = jPropertyKey(key);
  if (value is JTemplateArray) {
    throw JThrown(
      JError('TypeError', 'Cannot assign to a frozen template object'),
    );
  }
  if (value is List &&
      (property is JSymbol ||
          property is String &&
              property != 'length' &&
              jArrayIndex(property) == null)) {
    final extras = jArrayExtras(value, create: true)!;
    if (!extras.write(property, assigned, extras))
      throw JThrown(JError('TypeError', 'Cannot assign array property'));
    return assigned;
  }
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
  final old = jNumeric(ref.read());
  final next = old is BigInt ? old + BigInt.from(delta) : old + delta;
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
      return -jNumeric(value);
    case '+':
      return jNumber(value);
    case '~':
      final number = jNumeric(value);
      return number is BigInt ? ~number : (~jInt32(number)).toDouble();
    case 'void':
      return jUndefined;
    case 'typeof':
      if (value is JSymbol) return 'symbol';
      if (value is BigInt) return 'bigint';
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
      return jStrictEqual(a, b);
    case '!==':
      return !jBinary('===', a, b);
    case '==':
      return jLooseEqual(a, b);
    case '!=':
      return !jBinary('==', a, b);
    case '+':
      a = jPrimitive(a);
      b = jPrimitive(b);
      if (a is String || b is String) return jString(a) + jString(b);
      return jNumericBinary(op, a, b);
    case '-':
    case '*':
    case '/':
    case '%':
    case '**':
    case '&':
    case '|':
    case '^':
    case '<<':
    case '>>':
    case '>>>':
      return jNumericBinary(op, a, b);
    case '<':
    case '>':
    case '<=':
    case '>=':
      final comparison = jCompare(a, b);
      if (comparison == null) return false;
      return op == '<'
          ? comparison < 0
          : op == '>'
          ? comparison > 0
          : op == '<='
          ? comparison <= 0
          : comparison >= 0;
    case 'in':
      if (b is! JObject && b is! List)
        throw JThrown(
          JError('TypeError', 'Right operand of in must be an object'),
        );
      return jHasProperty(b, jPropertyKey(a));
    case 'instanceof':
      if (!jIsObject(b))
        throw JThrown(
          JError('TypeError', 'Right operand of instanceof must be an object'),
        );
      final method = jGet(b, jSymbols['hasInstance']);
      if (!jNullish(method)) return jTruthy(jCall(method, [a], receiver: b));
      if (b is! JFunction)
        throw JThrown(
          JError('TypeError', 'Right operand of instanceof must be callable'),
        );
      if (!jIsObject(a)) return false;
      final prototype = jGet(b, 'prototype');
      if (!jIsObject(prototype))
        throw JThrown(
          JError('TypeError', 'Constructor prototype must be an object'),
        );
      dynamic current = a;
      while ((current = jPrototype(current)) != null) {
        if (identical(current, prototype)) return true;
      }
      return false;
  }
  throw StateError('Binary operator $op');
}

void installJSBuiltins(JScope scope, {JObject? globalObject}) {
  installJSObjects(scope);
  installJSFunctionPrototype(scope);
  installJSProxies(scope);
  installJSBinary(scope);
  installJSAtomics(scope);
  installJSRegExp(scope);
  installJSCollections(scope);
  installJSWeakReferences(scope);
  installJSIterators(scope);
  scope.define('DisposableStack', jDisposableStack);
  scope.define('AsyncDisposableStack', jAsyncDisposableStack);
  final json = JObject({
    'parse': jNative((a) => jJSONParse(jArg(a, 0), jArg(a, 1))),
    'rawJSON': jNamedFunction(
      jBuiltin((a) => jRawJson(jArg(a, 0))),
      'rawJSON',
      1,
    ),
    'isRawJSON': jNamedFunction(
      jBuiltin((a) => jArg(a, 0) is JRawJson),
      'isRawJSON',
      1,
    ),
    'stringify': jNative(
      (a) => jJSONStringify(jArg(a, 0), jArg(a, 1), jArg(a, 2)),
    ),
  });
  jBuiltinProperties(json);
  scope.define('JSON', json);
  installJSPromises(scope);
  installJSErrors(scope);
  installJSPrimitiveWrappers(scope);
  installJSNumbers(scope);
  installJSDates(scope);
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
    'isArray': jNative((a) => jIsArray(jArg(a, 0))),
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
  final arrayPrototype = JObject(Map<String, dynamic>.of(jArrayMethods));
  arrayPrototype.properties['constructor'] = array;
  arrayPrototype.properties['length'] = 0.0;
  jBuiltinProperties(arrayPrototype);
  array.properties['prototype'] = arrayPrototype;
  array.properties['fromAsync'] = jNamedFunction(
    JFunction(
      (args, receiver) => jArrayFromAsync(args, receiver),
      constructible: false,
    ),
    'fromAsync',
    1,
  );
  for (final component in [false, true]) {
    final encode = component ? 'encodeURIComponent' : 'encodeURI';
    final decode = component ? 'decodeURIComponent' : 'decodeURI';
    scope.define(
      encode,
      jNamedFunction(
        jBuiltin((args) => jEncodeUri(jString(jArg(args, 0)), component)),
        encode,
        1,
      ),
    );
    scope.define(
      decode,
      jNamedFunction(
        jBuiltin((args) => jDecodeUri(jString(jArg(args, 0)), component)),
        decode,
        1,
      ),
    );
  }
  scope.define(
    'escape',
    jNamedFunction(
      jBuiltin((args) => jLegacyEscape(jString(jArg(args, 0)), false)),
      'escape',
      1,
    ),
  );
  scope.define(
    'unescape',
    jNamedFunction(
      jBuiltin((args) => jLegacyEscape(jString(jArg(args, 0)), true)),
      'unescape',
      1,
    ),
  );
  scope.define('Array', array);
  final random = math.Random();
  final mathObject = JObject({
    'PI': math.pi,
    'E': math.e,
    'LN2': math.ln2,
    'LN10': math.ln10,
    'LOG2E': math.log2e,
    'LOG10E': math.log10e,
    'SQRT2': math.sqrt2,
    'SQRT1_2': math.sqrt1_2,
    'round': jNative((a) => jMathRound(jNumber(jArg(a, 0)))),
    'trunc': jNative((a) => jNumber(jArg(a, 0)).truncateToDouble()),
    'sign': jNative((a) {
      final n = jNumber(jArg(a, 0));
      return n.isNaN || n == 0
          ? n
          : n.isNegative
          ? -1.0
          : 1.0;
    }),
    'imul': jNative(
      (a) => jSigned32(
        ((BigInt.from(jUint32(jArg(a, 0))) * BigInt.from(jUint32(jArg(a, 1)))) &
                BigInt.from(0xffffffff))
            .toInt(),
      ).toDouble(),
    ),
    'clz32': jNative((a) => (32 - jUint32(jArg(a, 0)).bitLength).toDouble()),
    'fround': jNative((a) => (Float32List(1)..[0] = jNumber(jArg(a, 0)))[0]),
    'pow': jNative(
      (a) => jNumericBinary('**', jNumber(jArg(a, 0)), jNumber(jArg(a, 1))),
    ),
    'atan2': jNative(
      (a) => math.atan2(jNumber(jArg(a, 0)), jNumber(jArg(a, 1))),
    ),
    for (final entry in <String, double Function(num)>{
      'sin': math.sin,
      'cos': math.cos,
      'tan': math.tan,
      'asin': math.asin,
      'acos': math.acos,
      'atan': math.atan,
      'exp': math.exp,
      'log': math.log,
    }.entries)
      entry.key: jNative((a) => entry.value(jNumber(jArg(a, 0)))),
    'log2': jNative((a) => math.log(jNumber(jArg(a, 0))) / math.ln2),
    'log10': jNative((a) => math.log(jNumber(jArg(a, 0))) / math.ln10),
    'random': jNative((a) => random.nextDouble()),
    'floor': jNative((a) => jNumber(jArg(a, 0)).floorToDouble()),
    'ceil': jNative((a) => jNumber(jArg(a, 0)).ceilToDouble()),
    'abs': jNative((a) => jNumber(jArg(a, 0)).abs()),
    'sqrt': jNative((a) => math.sqrt(jNumber(jArg(a, 0)))),
    'min': jNative((a) => a.map(jNumber).fold<num>(double.infinity, math.min)),
    'max': jNative(
      (a) => a.map(jNumber).fold<num>(double.negativeInfinity, math.max),
    ),
    'hypot': jNative(jHypot),
    ...jMathAdditionalMethods(),
  });
  jBuiltinProperties(mathObject);
  scope.define('Math', mathObject);
  scope.define(
    'console',
    JObject({
      'log': jNative((a) {
        print(a.map(jString).join(' '));
        return jUndefined;
      }),
    }),
  );
  scope.attachGlobal(globalObject ?? JObject());
}

final _jBuiltinIteratorPrototypes = <String, JObject>{};

JObject jBuiltinIteratorPrototype(String kind) =>
    _jBuiltinIteratorPrototypes.putIfAbsent(kind, () {
      final object = JObject({
        'next': jBuiltinMethod('next', 0, (_, receiver) {
          if (receiver is! JIterator || receiver.kind != kind) {
            throw JThrown(JError('TypeError', 'Expected $kind'));
          }
          return receiver.next();
        }),
      })..prototype = jIteratorPrototype;
      final tag = jSymbols['toStringTag']!;
      object.symbols[tag] = kind;
      jBuiltinProperties(object);
      object.flags[tag]!.writable = false;
      return object;
    });

class JIterator extends JObject {
  final JObject Function() step;
  final String kind;
  bool completed = false;
  JIterator(this.step, {this.kind = 'Array Iterator'}) {
    prototype = jBuiltinIteratorPrototype(kind);
  }

  JObject next() {
    if (completed) return jIterationResult();
    final result = step();
    if (jTruthy(jGet(result, 'done'))) completed = true;
    return result;
  }
}

JIterator jBuiltinIterator(dynamic value, [String mode = 'values']) {
  var index = 0;
  if (value is String) {
    return JIterator(() {
      if (index >= value.length) return jIterationResult();
      final end = jAdvanceString(value, index, true);
      final character = value.substring(index, end);
      index = end;
      return jIterationResult(character, false);
    }, kind: 'String Iterator');
  }
  final input = value as List;
  return JIterator(() {
    if (index >= input.length) return jIterationResult();
    final i = index++;
    return jIterationResult(switch (mode) {
      'keys' => i,
      'entries' => [i, jGet(input, i)],
      _ => jGet(input, i),
    }, false);
  });
}

class JIteratorRecord {
  final dynamic object, next;
  bool done = false;
  dynamic current = jUndefined;
  JIteratorRecord(this.object) : next = jGet(object, 'next');
  JIteratorRecord.direct(this.object, this.next);
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
    if (value is num) prototype = jNumberPrototype;
    if (value is BigInt) prototype = jBigIntPrototype;
    if (value is bool) prototype = jBooleanPrototype;
    if (value is String) {
      prototype = jStringPrototype;
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
  late final JFunction object;
  object = JFunction((a, _) => jObject(jArg(a, 0)), constructWithTarget: (a, target) =>
      identical(object, target) ? jObject(jArg(a, 0)) :
      (JObject()..prototype = jPrototypeFromConstructor(target, jObjectPrototype)));
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
        if (target is JTemplateArray) return target;
        if (target is List)
          throw UnsupportedError('Object.$mode on arrays is not implemented');
        if (target is! JObject) return target;
        if (!jPreventExtensions(target))
          jProxyError('Cannot prevent extensions');
        if (mode != 'preventExtensions')
          for (final key in jOwnKeys(target)) {
            final desc = jDescriptor(target, key);
            if (desc is! JObject) continue;
            final update = JObject({
              'configurable': false,
              if (mode == 'freeze' && desc.own('value')) 'writable': false,
            });
            if (!jDefineProperty(target, key, update, normalized: true))
              jProxyError('Cannot seal property');
          }
        return target;
      }),
    'isExtensible': jNative(
      (a) => jArg(a, 0) is JObject && (a[0] as JObject).extensible,
    ),
    for (final mode in ['isFrozen', 'isSealed'])
      mode: jNative((a) {
        final target = jArg(a, 0);
        if (target is JTemplateArray) return true;
        if (target is List)
          throw UnsupportedError('Object.$mode on arrays is not implemented');
        if (target is! JObject) return true;
        return !target.extensible &&
            jOwnKeys(target).every((key) {
              final desc = jDescriptor(target, key);
              if (desc is! JObject) return true;
              return !jTruthy(desc.get('configurable')) &&
                  (mode == 'isSealed' ||
                      desc.own('get') ||
                      !jTruthy(desc.get('writable')));
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
        return jPreventExtensions(jRequireObject(jArg(a, 0)));
      }),
      'apply': jNative(
        (a) =>
            jCall(jArg(a, 0), jArrayLikeList(jArg(a, 2)), receiver: jArg(a, 1)),
      ),
      'construct': jBuiltin((a) {
        final target = jArg(a, 0), newTarget = a.length < 3 ? target : a[2];
        if (target is! JFunction ||
            !target.constructible ||
            newTarget is! JFunction ||
            !newTarget.constructible)
          throw JThrown(
            JError('TypeError', 'Reflect.construct requires constructors'),
          );
        return jNew(target, jArrayLikeList(jArg(a, 1)), newTarget: newTarget);
      }),
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
    }, kind: this is JSet ? 'Set Iterator' : 'Map Iterator');
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
    if (!set)
      for (final computed in [false, true])
        computed ? 'getOrInsertComputed' : 'getOrInsert': method((args, map) {
          var key = jArg(args, 0);
          if (key is num && key == 0) key = 0.0;
          final input = jArg(args, 1);
          if (computed && input is! JFunction) {
            throw JThrown(JError('TypeError', 'Callback is not callable'));
          }
          final entry = map.lookup[key];
          if (entry != null) return entry.value;
          final value = computed ? jCall(input, [key]) : input;
          map.put(key, value);
          return value;
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
    if (!set)
      for (final computed in [false, true])
        computed ? 'getOrInsertComputed' : 'getOrInsert': method((args, map) {
          final key = jArg(args, 0);
          final input = jArg(args, 1);
          if (computed && input is! JFunction) {
            throw JThrown(JError('TypeError', 'Callback is not callable'));
          }
          if (!jWeakKey(key))
            throw JThrown(JError('TypeError', 'Invalid weak collection key'));
          final entry = map.entries[key];
          if (entry != null) return entry[0];
          final value = computed ? jCall(input, [key]) : input;
          map.entries[key] = [value];
          return value;
        }),
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
      constructWithTarget: (a, target) {
        final object = (set ? JSet() : JMap())
          ..prototype = jPrototypeFromConstructor(target, set ? jSetPrototypeObject : jMapPrototype);
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
    jInstallSpeciesGetter(constructor);
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
      constructWithTarget: (a, target) {
        final object = JWeakCollection(set)
          ..prototype = jPrototypeFromConstructor(target, set ? jWeakSetPrototype : jWeakMapPrototype);
        if (!jNullish(jArg(a, 0))) {
          final adder = jGet(object, set ? 'add' : 'set');
          if (adder is! JFunction) throw JThrown(JError('TypeError', 'Invalid weak collection adder'));
          jForEachIterable(a[0], (value) {
            if (!set && value is! JObject && value is! List)
              throw JThrown(
                JError('TypeError', 'WeakMap entry must be an object'),
              );
            jCall(adder, set ? [value] : [jGet(value, 0), jGet(value, 1)], receiver: object);
          });
        }
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
    if (value is num) return value.toDouble();
    return value;
  }

  dynamic root;
  final original = jString(text);
  try {
    // Dart decodes the integer spelling -0 as int zero. Preserve its sign
    // without rewriting quoted strings or relaxing the JSON grammar.
    final source = original.replaceAllMapped(
      RegExp(r'("(?:[^"\\]|\\.)*")|(-0)(?=[\x20\t\r\n]*(?:[,}\]]|$))'),
      (match) => match[1] ?? '-0.0',
    );
    root = convert(jsonDecode(source));
  } on FormatException {
    throw JThrown(JError('SyntaxError', 'Invalid JSON text'));
  }
  if (reviver is! JFunction) return root;
  final record = JJsonSourceReader(original).read(root);
  dynamic walk(dynamic holder, String key, JJsonParseRecord? parsed) {
    final value = jGet(holder, key);
    final original = parsed != null && jSameValue(parsed.value, value)
        ? parsed
        : null;
    if (value is JObject || value is List) {
      final keys = value is List
          ? [for (var i = 0; i < value.length; i++) '$i']
          : jOwnKeys(value, enumerable: true, strings: true);
      for (final name in keys) {
        final next = walk(value, name as String, original?.children?[name]);
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
    final context = JObject();
    if (original?.source case final String source) {
      context.properties['source'] = source;
    }
    return jCall(reviver, [key, value, context], receiver: holder);
  }

  return walk(JObject({'': root}), '', record);
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
    if (current is JObject || current is BigInt) {
      final toJSON = jGet(current, 'toJSON');
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
    if (current is JRawJson) return current.text;
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
      final array = jIsArray(current);
      if (array) {
        final length = jLength(jGet(current, 'length'));
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
  if (object is JTemplateArray) {
    success = !jHasOwn(object, property);
  } else if (object is JObject) {
    success = object.remove(property);
  } else if (object is List) {
    final extras = jArrayExtras(object);
    if (extras != null && extras.own(property))
      return jDelete(extras, property, strict: strict);
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
