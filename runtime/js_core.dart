// HTGC JavaScript semantics implemented in Dart. No JavaScript engine or eval.
import 'dart:math' as math;
import 'dart:async';

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
      });
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
    for (final value in jIterable(iterable)) {
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
    }
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

class JObject {
  final Map<String, dynamic> properties;
  final Map<String, JFunction> getters = {}, setters = {};
  JObject? prototype;
  JObject([Map<String, dynamic>? properties]) : properties = properties ?? {};
  dynamic get(String name) {
    final getter = getters[name];
    if (getter != null) return jCall(getter, [], receiver: this);
    return properties.containsKey(name)
        ? properties[name]
        : prototype?.get(name) ?? jUndefined;
  }

  dynamic set(String name, dynamic value) {
    final setter = setters[name];
    if (setter != null) {
      jCall(setter, [value], receiver: this);
      return value;
    }
    if (getters.containsKey(name))
      throw JThrown(JError('TypeError', 'Property has no setter: $name'));
    return properties[name] = value;
  }
}

typedef JObjectEntry = (String, String, dynamic);
JObject jObjectLiteral(List<JObjectEntry> entries) {
  final object = JObject();
  for (final (kind, key, value) in entries) {
    if (kind == 'get' || kind == 'set') {
      object.properties[key] = jUndefined;
      (kind == 'get' ? object.getters : object.setters)[key] =
          value as JFunction;
    } else {
      object.getters.remove(key);
      object.setters.remove(key);
      object.properties[key] = value;
    }
  }
  return object;
}

Iterable<JObjectEntry> jObjectSpread(dynamic value) =>
    jProperties(value).entries.map((entry) => ('init', entry.key, entry.value));

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
  JModuleNamespace(this.graph, this.exports);
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
          jNullish(jArg(a, 1)) ? [] : jIterable(a[1]).toList(),
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
  if (v is String) return v;
  if (v is List) return v.map((e) => jNullish(e) ? '' : jString(e)).join(',');
  if (v is JError) return '${v.get('name')}: ${v.get('message')}';
  if (v is JObject) return '[object Object]';
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
  final text = jString(v).trim();
  return text.isEmpty ? 0 : num.tryParse(text) ?? double.nan;
}

Iterable<dynamic> jIterable(dynamic value) {
  if (value is Iterable) return value.cast<dynamic>();
  if (value is String) return value.runes.map((r) => String.fromCharCode(r));
  throw StateError('Not iterable: ${jString(value)}');
}

Map<String, dynamic> jProperties(dynamic value) {
  if (value is JModuleNamespace)
    return {for (final name in value.exports.keys) name: value.get(name)};
  if (value is JObject)
    return {for (final name in value.properties.keys) name: value.get(name)};
  if (value is List)
    return {for (var i = 0; i < value.length; i++) '$i': value[i]};
  if (jNullish(value)) return {};
  throw StateError('Object spread is unsupported for this value');
}

dynamic jCall(
  dynamic fn,
  List<dynamic> args, {
  dynamic receiver = jUndefined,
  bool optional = false,
}) {
  if (identical(fn, jShortCircuit)) return jShortCircuit;
  if (optional && jNullish(fn)) return jShortCircuit;
  if (fn is JFunction) return fn.invoke(args, receiver);
  throw StateError('Not callable: ${jString(fn)}');
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
  throw StateError('Not a constructor');
}

dynamic jGet(dynamic value, dynamic key, {bool optional = false}) {
  if (identical(value, jShortCircuit)) return jShortCircuit;
  if (optional && jNullish(value)) return jShortCircuit;
  if (jNullish(value))
    throw StateError('Cannot read ${jString(key)} of ${jString(value)}');
  final name = jString(key);
  if (value is JObject) return value.get(name);
  if (value is List) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null) return i >= 0 && i < value.length ? value[i] : jUndefined;
    switch (name) {
      case 'push':
        return jNative((a) {
          value.addAll(a);
          return value.length;
        });
      case 'pop':
        return jNative((a) => value.isEmpty ? jUndefined : value.removeLast());
      case 'join':
        return jNative(
          (a) => value
              .map((x) => jNullish(x) ? '' : jString(x))
              .join(a.isEmpty ? ',' : jString(a[0])),
        );
      case 'map':
        return jNative(
          (a) => [
            for (var i = 0; i < value.length; i++)
              jCall(a[0], [value[i], i, value]),
          ],
        );
      case 'filter':
        return jNative(
          (a) => [
            for (var i = 0; i < value.length; i++)
              if (jTruthy(jCall(a[0], [value[i], i, value]))) value[i],
          ],
        );
      case 'forEach':
        return jNative((a) {
          for (var i = 0; i < value.length; i++)
            jCall(a[0], [value[i], i, value]);
          return jUndefined;
        });
      case 'some':
        return jNative((a) {
          for (var i = 0; i < value.length; i++) {
            if (jTruthy(jCall(a[0], [value[i], i, value]))) return true;
          }
          return false;
        });
      case 'every':
        return jNative((a) {
          for (var i = 0; i < value.length; i++) {
            if (!jTruthy(jCall(a[0], [value[i], i, value]))) return false;
          }
          return true;
        });
      case 'sort':
        return jNative((a) {
          final indexed = [
            for (var i = 0; i < value.length; i++) [value[i], i],
          ];
          indexed.sort((x, y) {
            final c = a.isEmpty
                ? jString(x[0]).compareTo(jString(y[0]))
                : jNumber(jCall(a[0], [x[0], y[0]])).sign.toInt();
            return c == 0 ? (x[1] as int).compareTo(y[1] as int) : c;
          });
          for (var i = 0; i < value.length; i++) {
            value[i] = indexed[i][0];
          }
          return value;
        });
      case 'includes':
        return jNative((a) => value.any((x) => jBinary('===', x, jArg(a, 0))));
      case 'indexOf':
        return jNative(
          (a) => value.indexWhere((x) => jBinary('===', x, jArg(a, 0))),
        );
      case 'slice':
        return jNative((a) {
          int ix(dynamic v) {
            final n = jNumber(v).toInt();
            return (n < 0 ? value.length + n : n).clamp(0, value.length);
          }

          return value.sublist(
            a.isEmpty ? 0 : ix(a[0]),
            a.length < 2 ? value.length : ix(a[1]),
          );
        });
    }
  }
  if (value is String) {
    if (name == 'length') return value.length;
    final i = int.tryParse(name);
    if (i != null) return i >= 0 && i < value.length ? value[i] : jUndefined;
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
  if (value is JRegex && name == 'test')
    return jNative((a) => value.value.hasMatch(jString(a[0])));
  if (value is num && name == 'toString') return jNative((a) => jString(value));
  return jUndefined;
}

dynamic jSet(dynamic value, dynamic key, dynamic assigned) {
  final name = jString(key);
  if (value is JObject) return value.set(name, assigned);
  if (value is List) {
    if (name == 'length') {
      final size = jNumber(assigned).toInt();
      while (value.length < size) {
        value.add(jUndefined);
      }
      value.length = size;
      return assigned;
    }
    final i = int.tryParse(name);
    if (i != null && i >= 0) {
      while (value.length <= i) {
        value.add(jUndefined);
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
      return -jNumber(value);
    case '+':
      return jNumber(value);
    case '~':
      return ~jNumber(value).toInt();
    case 'void':
      return jUndefined;
    case 'typeof':
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
      return b is JObject && b.properties.containsKey(jString(a));
  }
  throw StateError('Binary operator $op');
}

void installJSBuiltins(JScope scope) {
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
    scope.define(
      name,
      jNative((a) => JError(name, a.isEmpty ? '' : jString(a[0]))),
    );
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
  scope.define('String', jNative((a) => a.isEmpty ? '' : jString(a[0])));
  scope.define('Number', jNative((a) => a.isEmpty ? 0 : jNumber(a[0])));
  scope.define(
    'Date',
    jNative((a) {
      final now = DateTime.now();
      return JObject({'getFullYear': jNative((a) => now.year)});
    }),
  );
  scope.define(
    'Array',
    JObject({
      'from': jNative((a) {
        final input = a[0];
        final list = input is Iterable || input is String
            ? jIterable(input).toList()
            : List<dynamic>.filled(
                jNumber(jGet(input, 'length')).toInt(),
                jUndefined,
              );
        return a.length < 2
            ? list
            : [
                for (var i = 0; i < list.length; i++) jCall(a[1], [list[i], i]),
              ];
      }),
    }),
  );
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
