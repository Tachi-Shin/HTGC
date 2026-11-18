part of 'js_core.dart';

// Keep targets alive through the current event-loop turn and its microtasks.
final _jKeptObjects = <Object>[];
bool _jClearKeptScheduled = false;
void jKeepDuringJob(Object target) {
  _jKeptObjects.add(target);
  if (_jClearKeptScheduled) return;
  _jClearKeptScheduled = true;
  Timer.run(() {
    _jKeptObjects.clear();
    _jClearKeptScheduled = false;
  });
}

JObject get jWeakRefPrototype => JRealm.current.weakRefPrototype;
JObject get jFinalizationRegistryPrototype => JRealm.current.finalizationRegistryPrototype;

class JWeakRef extends JObject {
  final WeakReference<Object> target;
  JWeakRef(Object value) : target = WeakReference(value) {
    jKeepDuringJob(value);
  }
}

class JFinalizationCell {
  final WeakReference<JFinalizationRegistry> registry;
  final WeakReference<Object>? token;
  final Object detachToken = Object();
  final dynamic heldValue;
  bool active = true;

  JFinalizationCell(JFinalizationRegistry owner, Object? token, this.heldValue)
    : registry = WeakReference(owner),
      token = token == null ? null : WeakReference(token);
}

class JFinalizationRegistry extends JObject {
  final JFunction callback;
  final Zone zone = Zone.current;
  final cells = <JFinalizationCell>[];
  late final Finalizer<JFinalizationCell> finalizer = Finalizer((cell) {
    final registry = cell.registry.target;
    if (registry == null || !cell.active) return;
    cell.active = false;
    registry.cells.remove(cell);
    // Host cleanup runs asynchronously in the registry's creation zone.
    Timer.run(
      () => registry.zone.runGuarded(() {
        jCall(registry.callback, [cell.heldValue]);
      }),
    );
  });

  JFinalizationRegistry(this.callback);

  void register(Object target, dynamic heldValue, Object? token) {
    final cell = JFinalizationCell(this, token, heldValue);
    cells.add(cell);
    finalizer.attach(target, cell, detach: cell.detachToken);
  }

  bool unregister(Object token) {
    var removed = false;
    for (final cell in List<JFinalizationCell>.from(cells)) {
      if (!identical(cell.token?.target, token)) continue;
      cell.active = false;
      cells.remove(cell);
      finalizer.detach(cell.detachToken);
      removed = true;
    }
    return removed;
  }
}

void installJSWeakReferences(JScope scope) {
  final weakRef = jNamedFunction(
    JFunction(
      (_, __) => throw JThrown(JError('TypeError', 'WeakRef requires new')),
      constructWithTarget: (args, newTarget) {
        final target = jArg(args, 0);
        if (!jWeakKey(target)) {
          throw JThrown(JError('TypeError', 'Invalid WeakRef target'));
        }
        final prototype = jPrototypeFromConstructor(
          newTarget,
          jWeakRefPrototype,
        );
        return JWeakRef(target as Object)..prototype = prototype;
      },
    ),
    'WeakRef',
    1,
  );
  final registry = jNamedFunction(
    JFunction(
      (_, __) => throw JThrown(
        JError('TypeError', 'FinalizationRegistry requires new'),
      ),
      constructWithTarget: (args, newTarget) {
        final callback = jArg(args, 0);
        if (callback is! JFunction) {
          throw JThrown(
            JError('TypeError', 'Cleanup callback must be callable'),
          );
        }
        final prototype = jPrototypeFromConstructor(
          newTarget,
          jFinalizationRegistryPrototype,
        );
        return JFinalizationRegistry(callback)..prototype = prototype;
      },
    ),
    'FinalizationRegistry',
    1,
  );

  weakRef.properties['prototype'] = jWeakRefPrototype;
  registry.properties['prototype'] = jFinalizationRegistryPrototype;
  for (final constructor in [weakRef, registry]) {
    constructor.flags['prototype'] = JPropertyFlags(
      writable: false,
      enumerable: false,
      configurable: false,
    );
    jBuiltinProperties(constructor);
  }
  jWeakRefPrototype.properties.addAll({
    'constructor': weakRef,
    'deref': jBuiltinMethod('deref', 0, (_, receiver) {
      if (receiver is! JWeakRef) {
        throw JThrown(JError('TypeError', 'WeakRef receiver required'));
      }
      final target = receiver.target.target;
      if (target == null) return jUndefined;
      jKeepDuringJob(target);
      return target;
    }),
  });
  jFinalizationRegistryPrototype.properties.addAll({
    'constructor': registry,
    'register': jBuiltinMethod('register', 2, (args, receiver) {
      if (receiver is! JFinalizationRegistry) {
        throw JThrown(
          JError('TypeError', 'FinalizationRegistry receiver required'),
        );
      }
      final target = jArg(args, 0),
          heldValue = jArg(args, 1),
          token = jArg(args, 2);
      if (!jWeakKey(target) ||
          jSameValue(target, heldValue) ||
          (!identical(token, jUndefined) && !jWeakKey(token))) {
        throw JThrown(JError('TypeError', 'Invalid finalization registration'));
      }
      receiver.register(
        target as Object,
        heldValue,
        identical(token, jUndefined) ? null : token as Object,
      );
      return jUndefined;
    }),
    'unregister': jBuiltinMethod('unregister', 1, (args, receiver) {
      if (receiver is! JFinalizationRegistry) {
        throw JThrown(
          JError('TypeError', 'FinalizationRegistry receiver required'),
        );
      }
      final token = jArg(args, 0);
      if (!jWeakKey(token)) {
        throw JThrown(JError('TypeError', 'Invalid unregister token'));
      }
      return receiver.unregister(token as Object);
    }),
  });
  for (final (prototype, name) in <(JObject, String)>[
    (jWeakRefPrototype, 'WeakRef'),
    (jFinalizationRegistryPrototype, 'FinalizationRegistry'),
  ]) {
    final tag = jSymbols['toStringTag']!;
    prototype.symbols[tag] = name;
    jBuiltinProperties(prototype);
    prototype.flags[tag]!.writable = false;
  }
  scope.define('WeakRef', weakRef);
  scope.define('FinalizationRegistry', registry);
}
