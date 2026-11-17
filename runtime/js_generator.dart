part of 'js_core.dart';

// Dart's sync* frame keeps local variables, catch/finally handlers, and the
// program counter alive. Resume completions are injected at each suspension.
class JGeneratorStep {
  final dynamic value, result;
  final bool done, awaited;
  JGeneratorStep(
    this.value, {
    this.done = false,
    this.awaited = false,
    this.result,
  });
}

class JGenerator extends JObject {
  final Iterable<JGeneratorStep> Function(JGenerator) body;
  final bool asynchronous;
  Iterator<JGeneratorStep>? _iterator;
  bool _started = false,
      _executing = false,
      _completed = false,
      _draining = false;
  String _mode = 'next';
  dynamic _input = jUndefined, delegated = jUndefined;
  final _requests = Queue<(String, dynamic, JPromise)>();
  JGenerator(this.body, {this.asynchronous = false}) {
    prototype = asynchronous ? jAsyncGeneratorPrototype : jGeneratorPrototype;
  }

  dynamic resume() {
    final mode = _mode, input = _input;
    _mode = 'next';
    _input = jUndefined;
    if (mode == 'throw') throw JThrown(input);
    if (mode == 'return') throw JAsyncReturn(input);
    return input;
  }

  JGeneratorStep _advance(String mode, dynamic input) {
    if (_executing)
      throw JThrown(JError('TypeError', 'Generator is already running'));
    if (!_started && mode != 'next') _completed = true;
    if (_completed) {
      if (mode == 'throw') throw JThrown(input);
      return JGeneratorStep(mode == 'return' ? input : jUndefined, done: true);
    }
    _mode = mode;
    _input = input;
    _executing = true;
    try {
      _started = true;
      _iterator ??= body(this).iterator;
      if (!_iterator!.moveNext()) {
        _completed = true;
        return JGeneratorStep(jUndefined, done: true);
      }
      final step = _iterator!.current;
      if (step.done) _completed = true;
      return step;
    } catch (_) {
      _completed = true;
      rethrow;
    } finally {
      _executing = false;
    }
  }

  dynamic request(String mode, dynamic input) {
    if (!asynchronous) {
      final step = _advance(mode, input);
      return step.result ?? JObject({'value': step.value, 'done': step.done});
    }
    final promise = JPromise();
    _requests.add((mode, input, promise));
    if (!_draining) _drain();
    return promise;
  }

  Future<void> _drain() async {
    _draining = true;
    while (_requests.isNotEmpty) {
      var (mode, input, promise) = _requests.first;
      try {
        // AsyncGeneratorYield awaits an injected return value before resuming
        // catch/finally. A rejection resumes the body with a throw completion.
        if (mode == 'return') {
          try {
            input = await jAwait(input);
          } catch (error) {
            mode = 'throw';
            input = jExceptionValue(error);
          }
        }
        while (true) {
          final step = _advance(mode, input);
          dynamic value;
          try {
            value = await jAwait(step.value);
          } catch (error) {
            if (step.done) rethrow;
            mode = 'throw';
            input = jExceptionValue(error);
            continue;
          }
          if (step.awaited) {
            mode = 'next';
            input = value;
            continue;
          }
          promise.resolve(JObject({'value': value, 'done': step.done}));
          break;
        }
      } catch (error) {
        promise.reject(jExceptionValue(error));
      }
      _requests.removeFirst();
    }
    _draining = false;
  }
}

JObject jBuildGeneratorPrototype(bool asynchronous) {
  final prototype = JObject();
  if (!asynchronous) prototype.prototype = jIteratorPrototype;
  for (final mode in ['next', 'return', 'throw']) {
    final function = JFunction((args, receiver) {
      if (receiver is! JGenerator || receiver.asynchronous != asynchronous) {
        final error = JError('TypeError', 'Incompatible generator receiver');
        if (asynchronous) return JPromise()..reject(error);
        throw JThrown(error);
      }
      return receiver.request(mode, jArg(args, 0));
    }, constructible: false);
    jNameFunction(function, mode, 1);
    prototype.properties[mode] = function;
  }
  if (asynchronous) {
    prototype.symbols[jSymbols['asyncIterator']!] =
        JFunction((a, r) => r, constructible: false);
  }
  prototype.symbols[jSymbols['toStringTag']!] = asynchronous
      ? 'AsyncGenerator'
      : 'Generator';
  jBuiltinProperties(prototype);
  return prototype;
}

final jGeneratorPrototype = jBuildGeneratorPrototype(false);
final jAsyncGeneratorPrototype = jBuildGeneratorPrototype(true);
JObject jBuildGeneratorFunctionPrototype(bool asynchronous) {
  final generator = asynchronous
      ? jAsyncGeneratorPrototype
      : jGeneratorPrototype;
  final prototype = JObject({'prototype': generator});
  prototype.flags['prototype'] = JPropertyFlags(
    enumerable: false,
    writable: false,
  );
  generator.properties['constructor'] = prototype;
  generator.flags['constructor'] = JPropertyFlags(
    enumerable: false,
    writable: false,
  );
  prototype.symbols[jSymbols['toStringTag']!] = asynchronous
      ? 'AsyncGeneratorFunction'
      : 'GeneratorFunction';
  return prototype;
}

final jGeneratorFunctionPrototype = jBuildGeneratorFunctionPrototype(false);
final jAsyncGeneratorFunctionPrototype = jBuildGeneratorFunctionPrototype(true);

class JAsyncIteratorRecord {
  final dynamic object, next;
  final bool synchronous;
  bool done = false;
  dynamic current = jUndefined;
  JAsyncIteratorRecord(this.object, this.synchronous)
    : next = jGet(object, 'next');
  JPromise advance() => jAsync((promise) async {
    try {
      if (done) {
        promise.resolve(false);
        return;
      }
      dynamic result = jCall(next, [], receiver: object);
      if (!synchronous) result = await jAwait(result);
      if (!jIsObject(result))
        throw JThrown(JError('TypeError', 'Iterator result must be an object'));
      final finished = jTruthy(jGet(result, 'done'));
      dynamic value = jGet(result, 'value');
      if (synchronous) {
        try {
          value = await jAwait(value);
        } catch (_) {
          if (!finished) await jAwait(close(suppressErrors: true));
          rethrow;
        }
      }
      done = finished;
      current = value;
      promise.resolve(!done);
    } catch (error) {
      done = true;
      promise.reject(jExceptionValue(error));
    }
  });
  JPromise close({bool suppressErrors = false}) => jAsync((promise) async {
    try {
      if (!done) {
        done = true;
        final method = jGet(object, 'return');
        if (!jNullish(method)) {
          dynamic result = jCall(method, [], receiver: object);
          if (!synchronous) result = await jAwait(result);
          if (!jIsObject(result))
            throw JThrown(
              JError('TypeError', 'Iterator return must be an object'),
            );
          if (synchronous) await jAwait(jGet(result, 'value'));
        }
      }
      promise.resolve(jUndefined);
    } catch (error) {
      if (suppressErrors)
        promise.resolve(jUndefined);
      else
        promise.reject(jExceptionValue(error));
    }
  });
}

JAsyncIteratorRecord jGetAsyncIterator(dynamic value) {
  final method = jGet(value, jSymbols['asyncIterator']);
  if (jNullish(method))
    return JAsyncIteratorRecord(jGetIterator(value).object, true);
  final object = jCall(method, [], receiver: value);
  if (!jIsObject(object))
    throw JThrown(JError('TypeError', 'Async iterator must be an object'));
  return JAsyncIteratorRecord(object, false);
}

JFunction jGeneratorFunction(
  JGenerator Function(List<dynamic>, dynamic) body, {
  bool asynchronous = false,
}) {
  late final JFunction function;
  function = JFunction((args, receiver) {
    final generator = body(args, receiver),
        prototype = function.get('prototype');
    if (prototype is JObject) generator.prototype = prototype;
    return generator;
  }, constructible: false);
  function.properties['prototype'] = JObject()
    ..prototype = asynchronous ? jAsyncGeneratorPrototype : jGeneratorPrototype;
  function.prototype = asynchronous
      ? jAsyncGeneratorFunctionPrototype
      : jGeneratorFunctionPrototype;
  function.flags['prototype'] = JPropertyFlags(
    enumerable: false,
    configurable: false,
  );
  return function;
}

Iterable<JGeneratorStep> jYieldDelegate(
  JGenerator generator,
  dynamic value,
) sync* {
  final asyncMethod = generator.asynchronous
      ? jGet(value, jSymbols['asyncIterator'])
      : jUndefined;
  final isAsync = !jNullish(asyncMethod);
  final iterator = isAsync
      ? jCall(asyncMethod, [], receiver: value)
      : jGetIterator(value).object;
  if (!jIsObject(iterator))
    throw JThrown(JError('TypeError', 'Iterator must be an object'));
  final next = jGet(iterator, 'next');
  var mode = 'next';
  dynamic input = jUndefined;
  while (true) {
    final method = mode == 'next' ? next : jGet(iterator, mode);
    if (jNullish(method)) {
      if (mode == 'return') throw JAsyncReturn(input);
      if (mode == 'throw') {
        final close = jGet(iterator, 'return');
        if (!jNullish(close)) {
          dynamic result = jCall(close, [], receiver: iterator);
          if (isAsync) {
            yield JGeneratorStep(result, awaited: true);
            result = generator.resume();
          }
          if (!jIsObject(result))
            throw JThrown(
              JError('TypeError', 'Iterator return must be an object'),
            );
        }
        throw JThrown(
          JError('TypeError', 'Delegated iterator has no throw method'),
        );
      }
    }
    dynamic result = jCall(method, [input], receiver: iterator);
    if (isAsync) {
      yield JGeneratorStep(result, awaited: true);
      result = generator.resume();
    }
    if (!jIsObject(result))
      throw JThrown(JError('TypeError', 'Iterator result must be an object'));
    final done = jTruthy(jGet(result, 'done'));
    dynamic output = jGet(result, 'value');
    if (generator.asynchronous && !isAsync) {
      yield JGeneratorStep(output, awaited: true);
      output = generator.resume();
    }
    if (done) {
      if (mode == 'return') throw JAsyncReturn(output);
      generator.delegated = output;
      return;
    }
    yield JGeneratorStep(
      output,
      result: generator.asynchronous ? null : result,
    );
    mode = generator._mode;
    input = generator._input;
    generator._mode = 'next';
    generator._input = jUndefined;
  }
}
