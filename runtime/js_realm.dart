part of 'js_core.dart';

// A host enters a realm for each script, call or construction. Dart Zones
// retain this execution context across await and scheduled Promise jobs.
class JRealm {
  static final _default = JRealm();
  static final _zoneKey = Object();
  static JRealm get current => Zone.current[_zoneKey] as JRealm? ?? _default;

  T run<T>(T Function() action) => identical(this, current)
      ? action()
      : runZoned(action, zoneValues: {_zoneKey: this});

  final _prototypeNames = Map<JObject, String>.identity();
  final _prototypes = <String, JObject>{};

  void _recordPrototypes(Map<String, dynamic> bindings) {
    for (final entry in bindings.entries) {
      final constructor = entry.value;
      if (constructor is! JFunction) continue;
      final prototype = constructor.properties['prototype'];
      if (prototype is JObject) {
        _prototypeNames[prototype] = entry.key;
        _prototypes[entry.key] = prototype;
      }
    }
  }

  late final Map<String, JFunction> arrayMethods = jBuildArrayMethods();
  late final JObject arrayPrototypeObject = _buildRealmArrayPrototypeObject();
  late final JObject sharedArrayBufferPrototype = JObject();
  late final JObject arrayBufferPrototype = JObject();
  late final JObject dataViewPrototype = JObject();
  late final JObject typedArrayPrototype = JObject();
  late final Map<String, JObject> typedPrototypes = <String, JObject>{};
  late final Map<String, JFunction> typedConstructors = <String, JFunction>{};
  late final Map<String, JObject> errorPrototypes = {};
  late final JObject promisePrototype = _buildRealmPromisePrototype();
  late final JFunction promiseConstructor = buildJSPromiseConstructor();
  late final JObject objectPrototype = _buildRealmObjectPrototype();
  late final JObject numberPrototype = JObject();
  late final JObject bigIntPrototype = JObject();
  late final JObject stringPrototype = JObject();
  late final JObject booleanPrototype = JObject();
  late final Map<String, JObject> builtinIteratorPrototypes = <String, JObject>{};
  late final JObject mapPrototype = jBuildMapPrototype(false);
  late final JObject setPrototypeObject = jBuildMapPrototype(true);
  late final JObject weakMapPrototype = jBuildWeakPrototype(false);
  late final JObject weakSetPrototype = jBuildWeakPrototype(true);
  late final JDate datePrototype = JDate.prototype();
  late final JFunction disposableStack = jDisposableStackConstructor('DisposableStack', false);
  late final JFunction asyncDisposableStack = _buildRealmAsyncDisposableStack();
  late final JFunction functionPrototype = jBuildFunctionPrototype();
  late final JObject asyncFunctionPrototype = _buildRealmAsyncFunctionPrototype();
  late final JFunction throwArgumentsCallee = _buildRealmThrowArgumentsCallee();
  late final JObject asyncIteratorPrototype = _buildRealmAsyncIteratorPrototype();
  late final JObject generatorPrototype = jBuildGeneratorPrototype(false);
  late final JObject asyncGeneratorPrototype = jBuildGeneratorPrototype(true);
  late final JObject generatorFunctionPrototype = jBuildGeneratorFunctionPrototype(false);
  late final JObject asyncGeneratorFunctionPrototype = jBuildGeneratorFunctionPrototype(true);
  late final JObject iteratorHelperPrototype = _buildRealmIteratorHelperPrototype();
  late final JFunction iteratorConstructor = _buildRealmIteratorConstructor();
  late final JObject iteratorPrototype = _jBuildIteratorPrototype();
  late final JObject regExpPrototype = JObject();
  late final Map<String, JFunction> stringMethods = jBuildStringMethods();
  late final JObject weakRefPrototype = JObject();
  late final JObject finalizationRegistryPrototype = JObject();
}

JRealm jFunctionRealm(JFunction fn) {
  if (fn is JBoundFunction) return jFunctionRealm(fn.target);
  if (fn is JProxyFunction) {
    if (fn.proxy.handler == null) jProxyError('Revoked function proxy');
    return jFunctionRealm(fn.proxy.target as JFunction);
  }
  return fn.realm;
}

// Plain Dart lists carry JavaScript array elements. Remember their allocating
// realm without keeping the list alive or wrapping and changing its identity.
final _arrayRealms = Expando<JRealm>();
JRealm jArrayRealm(List value) => _arrayRealms[value] ??= JRealm.current;
T jRealmValue<T>(T value) {
  if (value is List) jArrayRealm(value);
  return value;
}
