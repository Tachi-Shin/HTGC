part of 'js_core.dart';

bool jIsObject(dynamic value) => value is JObject || value is List;
bool jExtensible(dynamic value) =>
    value is JObject ? value.extensible : value is List;
dynamic jPrototype(dynamic value) =>
    value is JObject ? value.prototype : jObjectPrototype;
JProxy? jProxyState(dynamic value) => value is JProxy
    ? value
    : value is JProxyFunction
    ? value.proxy
    : null;
bool jIsArray(dynamic value) {
  final proxy = jProxyState(value);
  if (proxy == null) return value is List;
  if (proxy.handler == null) jProxyError('Cannot use a revoked proxy');
  return jIsArray(proxy.target);
}

Never jProxyError(String message) =>
    throw JThrown(JError('TypeError', message));

bool jPreventExtensions(JObject value) {
  final proxy = jProxyState(value);
  if (proxy != null) return proxy.preventExtensions();
  value.extensible = false;
  return true;
}

class JProxy extends JObject {
  final dynamic target;
  dynamic handler;
  JProxy(this.target, this.handler);
  dynamic trap(String name) {
    if (handler == null) jProxyError('Cannot use a revoked proxy');
    final method = jGet(handler, name);
    if (jNullish(method)) return jUndefined;
    if (method is! JFunction) jProxyError('Proxy trap $name is not callable');
    return method;
  }

  dynamic callTrap(dynamic method, List<dynamic> args) =>
      jCall(method, args, receiver: handler);
  @override
  bool own(Object key) => !identical(descriptor(key), jUndefined);
  @override
  dynamic read(Object key, dynamic receiver) {
    final method = trap('get');
    if (identical(method, jUndefined))
      return target is JObject
          ? (target as JObject).read(key, receiver)
          : jGet(target, key);
    final result = callTrap(method, [target, key, receiver]);
    final desc = jDescriptor(target, key);
    if (desc is JObject && !jTruthy(desc.get('configurable'))) {
      if (desc.own('value') &&
          !jTruthy(desc.get('writable')) &&
          !jSameValue(result, desc.get('value')))
        jProxyError('Proxy get violates a fixed value');
      if (desc.own('get') &&
          identical(desc.get('get'), jUndefined) &&
          !identical(result, jUndefined))
        jProxyError('Proxy get violates an absent getter');
    }
    return result;
  }

  @override
  bool write(Object key, dynamic value, dynamic receiver) {
    final method = trap('set');
    if (identical(method, jUndefined)) {
      if (target is JObject)
        return (target as JObject).write(key, value, receiver);
      jSet(target, key, value);
      return true;
    }
    if (!jTruthy(callTrap(method, [target, key, value, receiver])))
      return false;
    final desc = jDescriptor(target, key);
    if (desc is JObject && !jTruthy(desc.get('configurable'))) {
      if (desc.own('value') &&
          !jTruthy(desc.get('writable')) &&
          !jSameValue(value, desc.get('value')))
        jProxyError('Proxy set violates a fixed value');
      if (desc.own('set') && identical(desc.get('set'), jUndefined))
        jProxyError('Proxy set violates an absent setter');
    }
    return true;
  }

  bool has(Object key) {
    final method = trap('has');
    if (identical(method, jUndefined)) return jHasProperty(target, key);
    final result = jTruthy(callTrap(method, [target, key]));
    if (!result) {
      final desc = jDescriptor(target, key);
      if (desc is JObject &&
          (!jTruthy(desc.get('configurable')) || !jExtensible(target)))
        jProxyError('Proxy has hides a fixed property');
    }
    return result;
  }

  @override
  bool remove(Object key) {
    final method = trap('deleteProperty');
    if (identical(method, jUndefined))
      return target is JObject
          ? (target as JObject).remove(key)
          : jDelete(target, key);
    if (!jTruthy(callTrap(method, [target, key]))) return false;
    final desc = jDescriptor(target, key);
    if (desc is JObject &&
        (!jTruthy(desc.get('configurable')) || !jExtensible(target)))
      jProxyError('Proxy delete hides a fixed property');
    return true;
  }

  List<Object> keys() {
    final method = trap('ownKeys');
    if (identical(method, jUndefined)) return jOwnKeys(target);
    final keys = jArrayLikeList(callTrap(method, [target]));
    final unique = <Object>{};
    for (final key in keys) {
      if (key is! String && key is! JSymbol || !unique.add(key))
        jProxyError('Invalid or duplicate proxy own key');
    }
    final actual = jOwnKeys(target), extensible = jExtensible(target);
    for (final key in actual) {
      final desc = jDescriptor(target, key);
      if ((!extensible ||
              desc is JObject && !jTruthy(desc.get('configurable'))) &&
          !unique.contains(key))
        jProxyError('Proxy ownKeys omits a required key');
    }
    if (!extensible && keys.length != actual.length)
      jProxyError('Proxy ownKeys adds a key to a non-extensible target');
    return keys.cast<Object>();
  }

  bool compatible(dynamic current, JObject desc, bool extensible) {
    final fake = JObject.root();
    if (current is JObject)
      jDefineProperty(fake, 'key', current, normalized: true);
    fake.extensible = extensible;
    return jDefineProperty(fake, 'key', desc, normalized: true);
  }

  dynamic descriptor(Object key) {
    final method = trap('getOwnPropertyDescriptor');
    if (identical(method, jUndefined)) return jDescriptor(target, key);
    final result = callTrap(method, [target, key]);
    if (!identical(result, jUndefined) && !jIsObject(result))
      jProxyError('Proxy descriptor must be an object or undefined');
    final current = jDescriptor(target, key), extensible = jExtensible(target);
    if (identical(result, jUndefined)) {
      if (current is JObject &&
          (!jTruthy(current.get('configurable')) || !extensible))
        jProxyError('Proxy descriptor hides a fixed property');
      return jUndefined;
    }
    final desc = jNormalizeDescriptor(result);
    desc.properties.putIfAbsent('enumerable', () => false);
    desc.properties.putIfAbsent('configurable', () => false);
    if (desc.own('get') || desc.own('set')) {
      desc.properties.putIfAbsent('get', () => jUndefined);
      desc.properties.putIfAbsent('set', () => jUndefined);
    } else {
      desc.properties.putIfAbsent('value', () => jUndefined);
      desc.properties.putIfAbsent('writable', () => false);
    }
    if (!compatible(current, desc, extensible))
      jProxyError('Incompatible proxy descriptor');
    if (!jTruthy(desc.get('configurable')) &&
        (current is! JObject || jTruthy(current.get('configurable'))))
      jProxyError('Proxy reports a new non-configurable property');
    if (!jTruthy(desc.get('configurable')) &&
        desc.own('writable') &&
        !jTruthy(desc.get('writable')) &&
        current is JObject &&
        jTruthy(current.get('writable')))
      jProxyError('Proxy reports a new non-writable property');
    return desc;
  }

  bool define(Object key, JObject desc) {
    final method = trap('defineProperty');
    if (identical(method, jUndefined)) {
      if (target is! JObject)
        throw UnsupportedError(
          'Array property descriptors are not implemented',
        );
      return jDefineProperty(target, key, desc, normalized: true);
    }
    if (!jTruthy(
      callTrap(method, [
        target,
        key,
        JObject(Map<String, dynamic>.from(desc.properties)),
      ]),
    ))
      return false;
    final current = jDescriptor(target, key), extensible = jExtensible(target);
    if (!compatible(current, desc, extensible))
      jProxyError('Incompatible proxy definition');
    if (desc.own('configurable') &&
        !jTruthy(desc.get('configurable')) &&
        (current is! JObject || jTruthy(current.get('configurable'))))
      jProxyError('Proxy cannot invent a non-configurable property');
    if (current is JObject &&
        !jTruthy(current.get('configurable')) &&
        current.own('writable') &&
        jTruthy(current.get('writable')) &&
        desc.own('writable') &&
        !jTruthy(desc.get('writable')))
      jProxyError('Proxy cannot invent a non-writable property');
    return true;
  }

  @override
  JObject? get prototype {
    final method = trap('getPrototypeOf');
    if (identical(method, jUndefined)) return jPrototype(target);
    final result = callTrap(method, [target]);
    if (result != null && result is! JObject)
      jProxyError('Invalid proxy prototype');
    if (!jExtensible(target) && !identical(result, jPrototype(target)))
      jProxyError('Proxy changes a fixed prototype');
    return result;
  }

  bool setPrototype(dynamic value) {
    final method = trap('setPrototypeOf');
    if (identical(method, jUndefined))
      return jSetPrototype(jRequireObject(target), value);
    if (!jTruthy(callTrap(method, [target, value]))) return false;
    if (!jExtensible(target) && !identical(value, jPrototype(target)))
      jProxyError('Proxy changes a fixed prototype');
    return true;
  }

  @override
  bool get extensible {
    final method = trap('isExtensible');
    if (identical(method, jUndefined)) return jExtensible(target);
    final result = jTruthy(callTrap(method, [target]));
    final actual = jExtensible(target);
    if (result != actual)
      jProxyError('Proxy isExtensible disagrees with target');
    return result;
  }

  bool preventExtensions() {
    final method = trap('preventExtensions');
    if (identical(method, jUndefined))
      return jPreventExtensions(jRequireObject(target));
    if (!jTruthy(callTrap(method, [target]))) return false;
    if (jExtensible(target)) jProxyError('Proxy target is still extensible');
    return true;
  }

  dynamic apply(List<dynamic> args, dynamic receiver) {
    final method = trap('apply');
    return identical(method, jUndefined)
        ? jCall(target, args, receiver: receiver)
        : callTrap(method, [target, receiver, args]);
  }

  dynamic construct(List<dynamic> args, dynamic newTarget) {
    final method = trap('construct');
    final result = identical(method, jUndefined)
        ? jNew(target, args, newTarget: newTarget)
        : callTrap(method, [target, args, newTarget]);
    if (!jIsObject(result))
      jProxyError('Proxy construct must return an object');
    return result;
  }
}

class JProxyFunction extends JFunction {
  final JProxy proxy;
  JProxyFunction(this.proxy)
    : super(
        (a, r) => proxy.apply(a, r),
        constructible: (proxy.target as JFunction).constructible,
      );
  @override
  dynamic read(Object key, dynamic receiver) => proxy.read(key, receiver);
  @override
  bool own(Object key) => proxy.own(key);
  @override
  bool write(Object key, dynamic value, dynamic receiver) =>
      proxy.write(key, value, receiver);
  @override
  bool remove(Object key) => proxy.remove(key);
  @override
  JObject? get prototype => proxy.prototype;
  @override
  bool get extensible => proxy.extensible;
}

void installJSProxies(JScope scope) {
  dynamic create(List<dynamic> a) {
    if (!jIsObject(jArg(a, 0)) || !jIsObject(jArg(a, 1)))
      jProxyError('Proxy target and handler must be objects');
    final state = JProxy(a[0], a[1]);
    return a[0] is JFunction ? JProxyFunction(state) : state;
  }

  final constructor = JFunction(
    (a, r) => jProxyError('Proxy requires new'),
    construct: create,
  );
  constructor.properties['revocable'] = jBuiltin((a) {
    final proxy = create(a), state = jProxyState(proxy)!;
    return JObject({
      'proxy': proxy,
      'revoke': jBuiltin((a) {
        state.handler = null;
        return jUndefined;
      }),
    });
  });
  jNameFunction(constructor, 'Proxy', 2);
  jBuiltinProperties(constructor);
  scope.define('Proxy', constructor);
}
