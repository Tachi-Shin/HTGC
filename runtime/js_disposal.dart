part of 'js_core.dart';

void jCheckDisposer(dynamic callback) {
  if (callback is! JFunction) {
    throw JThrown(JError('TypeError', 'Disposer must be callable'));
  }
}

class JResources {
  final _entries = <(bool, dynamic Function()?)>[];
  bool get hasAsync => _entries.any((entry) => entry.$1);

  dynamic add(dynamic value, {bool asynchronous = false}) {
    if (jNullish(value)) {
      if (asynchronous) addCallback(null, asynchronous: true);
      return value;
    }
    if (!jIsObject(value)) {
      throw JThrown(
        JError('TypeError', 'Disposable resource must be an object'),
      );
    }
    if (asynchronous) {
      final method = jGet(value, jSymbols['asyncDispose']);
      if (!jNullish(method)) {
        jCheckDisposer(method);
        addCallback(
          () => jCall(method, [], receiver: value),
          asynchronous: true,
        );
        return value;
      }
    }
    final method = jGet(value, jSymbols['dispose']);
    jCheckDisposer(method);
    addCallback(() {
      if (!asynchronous) return jCall(method, [], receiver: value);
      // An await-using fallback awaits an intrinsic Promise that ignores
      // any result of the synchronous disposer.
      final result = JPromise();
      try {
        jCall(method, [], receiver: value);
        result.resolve(jUndefined);
      } catch (error) {
        result.reject(jExceptionValue(error));
      }
      return result;
    }, asynchronous: asynchronous);
    return value;
  }

  void addCallback(dynamic Function()? callback, {required bool asynchronous}) {
    _entries.add((asynchronous, callback));
  }

  Object combine(Object error, Object? previous) {
    if (previous == null || previous is JAsyncReturn) return error;
    final suppressed = JError('SuppressedError', '')
      ..properties['error'] = jExceptionValue(error)
      ..properties['suppressed'] = jExceptionValue(previous);
    jBuiltinProperties(suppressed);
    return JThrown(suppressed);
  }

  void dispose(Object? previous) {
    var failure = previous;
    while (_entries.isNotEmpty) {
      final (_, callback) = _entries.removeLast();
      try {
        callback?.call();
      } catch (error) {
        failure = combine(error, failure);
      }
    }
    if (!identical(failure, previous)) throw failure!;
  }

  JPromise disposeAsync(Object? previous) => jAsync((promise) async {
    var failure = previous;
    var needsAwait = false, hasAwaited = false;
    while (_entries.isNotEmpty) {
      final (asynchronous, callback) = _entries.removeLast();
      try {
        if (!asynchronous && needsAwait && !hasAwaited) {
          needsAwait = false;
          await jAwait(jUndefined);
        }
        if (callback == null) {
          needsAwait = true;
        } else {
          final result = callback();
          if (asynchronous) {
            hasAwaited = true;
            await jAwait(result);
          }
        }
      } catch (error) {
        failure = combine(error, failure);
      }
    }
    if (needsAwait && !hasAwaited) await jAwait(jUndefined);
    if (identical(failure, previous)) {
      promise.resolve(jUndefined);
    } else {
      promise.reject(jExceptionValue(failure!));
    }
  });
}

class JDisposableStack extends JObject {
  JResources resources = JResources();
  bool disposed = false;
  final bool asynchronous;
  JDisposableStack(this.asynchronous, JObject prototype) {
    this.prototype = prototype;
  }

  void checkPending() {
    if (disposed) throw JThrown(JError('ReferenceError', 'Stack is disposed'));
  }
}

JFunction jDisposableStackConstructor(String name, bool asynchronous) {
  final prototype = JObject();
  final constructor = jNamedFunction(
    JFunction(
      (_, __) => throw JThrown(JError('TypeError', '$name requires new')),
      constructWithTarget: jBuiltinAllocator(
        prototype,
        (_) => JDisposableStack(asynchronous, prototype),
      ),
    ),
    name,
    0,
  );

  JDisposableStack stack(dynamic receiver) {
    if (receiver is! JDisposableStack ||
        receiver.asynchronous != asynchronous) {
      throw JThrown(JError('TypeError', 'Invalid $name receiver'));
    }
    return receiver;
  }

  final disposeName = asynchronous ? 'disposeAsync' : 'dispose';
  final dispose = jBuiltinMethod(disposeName, 0, (_, receiver) {
    if (asynchronous) {
      try {
        final target = stack(receiver);
        if (target.disposed) return jPromiseResolve(jUndefined);
        target.disposed = true;
        return target.resources.disposeAsync(null);
      } catch (error) {
        return JPromise()..reject(jExceptionValue(error));
      }
    }
    final target = stack(receiver);
    if (!target.disposed) {
      target.disposed = true;
      target.resources.dispose(null);
    }
    return jUndefined;
  });
  prototype.properties.addAll({
    'constructor': constructor,
    'use': jBuiltinMethod('use', 1, (args, receiver) {
      final target = stack(receiver)..checkPending();
      return target.resources.add(jArg(args, 0), asynchronous: asynchronous);
    }),
    'adopt': jBuiltinMethod('adopt', 2, (args, receiver) {
      final target = stack(receiver)..checkPending();
      final value = jArg(args, 0), callback = jArg(args, 1);
      jCheckDisposer(callback);
      target.resources.addCallback(
        () => jCall(callback, [value]),
        asynchronous: asynchronous,
      );
      return value;
    }),
    'defer': jBuiltinMethod('defer', 1, (args, receiver) {
      final target = stack(receiver)..checkPending();
      final callback = jArg(args, 0);
      jCheckDisposer(callback);
      target.resources.addCallback(
        () => jCall(callback, []),
        asynchronous: asynchronous,
      );
      return jUndefined;
    }),
    disposeName: dispose,
    'move': jBuiltinMethod('move', 0, (_, receiver) {
      final source = stack(receiver)..checkPending();
      final target = JDisposableStack(asynchronous, prototype)
        ..resources = source.resources;
      source.resources = JResources();
      source.disposed = true;
      return target;
    }),
  });
  prototype.symbols.addAll({
    jSymbols[asynchronous ? 'asyncDispose' : 'dispose']!: dispose,
    jSymbols['toStringTag']!: name,
  });
  jDefineProperty(
    prototype,
    'disposed',
    JObject({
      'get': jBuiltinMethod(
        'get disposed',
        0,
        (_, receiver) => stack(receiver).disposed,
      ),
      'configurable': true,
    }),
  );
  constructor.properties['prototype'] = prototype;
  jBuiltinProperties(prototype);
  jBuiltinProperties(constructor);
  constructor.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  prototype.flags[jSymbols['toStringTag']!]!.writable = false;
  return constructor;
}

final jDisposableStack = jDisposableStackConstructor('DisposableStack', false);
final jAsyncDisposableStack = jDisposableStackConstructor(
  'AsyncDisposableStack',
  true,
);
