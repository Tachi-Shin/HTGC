part of 'js_core.dart';

final JFunction jFunctionPrototype = jBuildFunctionPrototype();

class JBoundFunction extends JFunction {
  final JFunction target;
  JBoundFunction(this.target, dynamic receiver, List<dynamic> bound)
    : super(
        (args, _) => jCall(target, [...bound, ...args], receiver: receiver),
        constructible: target.constructible,
      ) {
    prototype = target.prototype;
    final size = jHasOwn(target, 'length')
        ? jGet(target, 'length')
        : jUndefined;
    final name = jGet(target, 'name');
    jNameFunction(this, 'bound ${name is String ? name : ''}', 0);
    properties['length'] = size is num
        ? math.max(0.0, jInteger(size) - bound.length)
        : 0.0;
    _boundArguments = bound;
  }
  late final List<dynamic> _boundArguments;
}

JFunction jBuildFunctionPrototype() {
  final prototype = jNamedFunction(jBuiltin((_) => jUndefined), '', 0);
  prototype.prototype = jObjectPrototype;
  void add(
    String name,
    int length,
    dynamic Function(List<dynamic>, JFunction) run,
  ) {
    final method = JFunction((args, receiver) {
      if (receiver is! JFunction)
        throw JThrown(JError('TypeError', 'Function receiver required'));
      return run(args, receiver);
    }, constructible: false);
    prototype.properties[name] = jNamedFunction(method, name, length);
  }

  add(
    'call',
    1,
    (args, receiver) =>
        jCall(receiver, args.skip(1).toList(), receiver: jArg(args, 0)),
  );
  add(
    'apply',
    2,
    (args, receiver) => jCall(
      receiver,
      jNullish(jArg(args, 1)) ? [] : jArrayLikeList(args[1]),
      receiver: jArg(args, 0),
    ),
  );
  add(
    'bind',
    1,
    (args, receiver) =>
        JBoundFunction(receiver, jArg(args, 0), args.skip(1).toList()),
  );
  add('toString', 0, (args, receiver) {
    final name = receiver.properties['name'];
    return receiver.sourceText ??
        'function ${name is String && receiver is! JBoundFunction ? name : ''}() { [native code] }';
  });
  final hasInstance = jSymbols['hasInstance']!;
  prototype.symbols[hasInstance] = jNamedFunction(
    JFunction(
      (args, receiver) =>
          receiver is JFunction &&
          jOrdinaryHasInstance(receiver, jArg(args, 0)),
      constructible: false,
    ),
    '[Symbol.hasInstance]',
    1,
  );
  jBuiltinProperties(prototype);
  prototype.flags[hasInstance] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  return prototype;
}

bool jOrdinaryHasInstance(JFunction function, dynamic instance) {
  if (function is JBoundFunction)
    return jBinary('instanceof', instance, function.target) == true;
  if (!jIsObject(instance)) return false;
  final prototype = jGet(function, 'prototype');
  if (!jIsObject(prototype)) {
    throw JThrown(JError('TypeError', 'Invalid constructor prototype'));
  }
  dynamic candidate = jPrototype(instance);
  while (candidate != null) {
    if (identical(candidate, prototype)) return true;
    candidate = jPrototype(candidate);
  }
  return false;
}

class JDynamicFunctionConstructor extends JFunction {
  final String kind;
  JDynamicFunctionConstructor([this.kind = 'normal'])
    : super(
        (_, __) => throw JThrown(
          JError('TypeError', 'Dynamic Function source is not compiled'),
        ),
      );
}

class JEvalFunction extends JFunction {
  JEvalFunction()
    : super((args, _) {
        final value = jArg(args, 0);
        if (value is! String) return value;
        throw JThrown(
          JError('TypeError', 'Dynamic eval source is not compiled'),
        );
      }, constructible: false);
}

dynamic jCompiledEval(
  dynamic callee,
  List<dynamic> args,
  dynamic Function() body, {
  dynamic receiver = jUndefined,
}
) {
  if (callee is JEvalFunction) return body();
  return jCall(callee, args, receiver: receiver);
}

dynamic jCompiledFunction(
  dynamic callee,
  List<dynamic> args,
  dynamic Function() body, {
  required bool construct,
  String kind = 'normal',
  dynamic receiver = jUndefined,
}) {
  if (callee is JDynamicFunctionConstructor && callee.kind == kind)
    return body();
  return construct
      ? jNew(callee, args)
      : jCall(callee, args, receiver: receiver);
}

final JObject jAsyncFunctionPrototype = JObject()
  ..prototype = jFunctionPrototype;

JFunction jAsyncFunction(JFunction function) {
  function.prototype = jAsyncFunctionPrototype;
  return function;
}

void installJSFunctionPrototype(JScope scope) {
  final function = jNamedFunction(JDynamicFunctionConstructor(), 'Function', 1);
  scope.define('eval', jNamedFunction(JEvalFunction(), 'eval', 1));
  function.properties['prototype'] = jFunctionPrototype;
  function.flags['prototype'] = JPropertyFlags(
    writable: false,
    enumerable: false,
    configurable: false,
  );
  jFunctionPrototype.properties['constructor'] = function;
  jFunctionPrototype.flags['constructor'] = JPropertyFlags(enumerable: false);
  scope.define('Function', function);
  for (final (kind, name, prototype) in <(String, String, JObject)>[
    ('async', 'AsyncFunction', jAsyncFunctionPrototype),
    ('generator', 'GeneratorFunction', jGeneratorFunctionPrototype),
    (
      'asyncGenerator',
      'AsyncGeneratorFunction',
      jAsyncGeneratorFunctionPrototype,
    ),
  ]) {
    final constructor = jNamedFunction(
      JDynamicFunctionConstructor(kind),
      name,
      1,
    );
    constructor.properties['prototype'] = prototype;
    constructor.flags['prototype'] = JPropertyFlags(
      writable: false,
      enumerable: false,
      configurable: false,
    );
    prototype.properties['constructor'] = constructor;
    prototype.flags['constructor'] = JPropertyFlags(
      writable: false,
      enumerable: false,
    );
    prototype.symbols[jSymbols['toStringTag']!] = name;
    jBuiltinProperties(prototype);
  }
}

JObject jArgumentsObject(List<dynamic> args) {
  final object = JObject({
    for (var index = 0; index < args.length; index++) '$index': args[index],
    'length': args.length.toDouble(),
  });
  object.flags['length'] = JPropertyFlags(enumerable: false);
  final restricted = jBuiltin(
    (_) => throw JThrown(JError('TypeError', 'Restricted arguments.callee')),
  );
  object.properties['callee'] = jUndefined;
  object.getters['callee'] = restricted;
  object.setters['callee'] = restricted;
  object.flags['callee'] = JPropertyFlags(
    enumerable: false,
    configurable: false,
  );
  final iterator = jSymbols['iterator']!;
  object.symbols[iterator] = jBuiltin((_) {
    var index = 0;
    return JIterator(() {
      final done = index >= jLength(jGet(object, 'length'));
      return JObject({
        'done': done,
        'value': done ? jUndefined : jGet(object, index++),
      });
    });
  });
  object.flags[iterator] = JPropertyFlags(enumerable: false);
  return object;
}

class JRawJson extends JObject {
  final String text;
  JRawJson(this.text) : super.root({'rawJSON': text}) {
    extensible = false;
    flags['rawJSON'] = JPropertyFlags(writable: false, configurable: false);
  }
}

JRawJson jRawJson(dynamic value) {
  final text = jString(value);
  if (text.isEmpty ||
      ' \t\r\n'.contains(text[0]) ||
      ' \t\r\n'.contains(text[text.length - 1]) ||
      text.startsWith('{') ||
      text.startsWith('[')) {
    throw JThrown(
      JError(
        'SyntaxError',
        'JSON.rawJSON requires a JSON primitive without surrounding whitespace',
      ),
    );
  }
  try {
    jsonDecode(text);
  } on FormatException {
    throw JThrown(JError('SyntaxError', 'Invalid JSON primitive'));
  }
  return JRawJson(text);
}

void installJSErrors(JScope scope) {
  for (final name in [
    'Error',
    'TypeError',
    'RangeError',
    'ReferenceError',
    'SyntaxError',
    'URIError',
    'EvalError',
    'AggregateError',
    'SuppressedError',
  ]) {
    final aggregate = name == 'AggregateError',
        suppressed = name == 'SuppressedError';
    final prototype = jErrorPrototypes.putIfAbsent(name, () => JObject());
    if (name != 'Error') prototype.prototype = jErrorPrototypes['Error'];
    JError make(List<dynamic> args) {
      final message = jArg(
        args,
        suppressed
            ? 2
            : aggregate
            ? 1
            : 0,
      );
      final error = JError(
        name,
        identical(message, jUndefined) ? '' : jString(message),
      );
      error.properties.remove('name');
      if (identical(message, jUndefined)) error.properties.remove('message');
      if (suppressed) {
        error.properties.addAll({
          'error': jArg(args, 0),
          'suppressed': jArg(args, 1),
        });
      } else {
        final options = jArg(args, aggregate ? 2 : 1);
        if (jIsObject(options) && jHasProperty(options, 'cause')) {
          error.properties['cause'] = jGet(options, 'cause');
        }
        if (aggregate)
          error.properties['errors'] = jIterable(jArg(args, 0)).toList();
      }
      jBuiltinProperties(error);
      return error;
    }

    final constructor = jNamedFunction(
      JFunction(
        (args, receiver) => make(args),
        constructWithTarget: jBuiltinAllocator(prototype, make),
      ),
      name,
      suppressed
          ? 3
          : aggregate
          ? 2
          : 1,
    );
    prototype.properties.addAll({
      'constructor': constructor,
      'name': name,
      'message': '',
    });
    constructor.properties['prototype'] = prototype;
    constructor.flags['prototype'] = JPropertyFlags(
      writable: false,
      enumerable: false,
      configurable: false,
    );
    if (name == 'Error') {
      constructor.properties['isError'] = jNamedFunction(
        jBuiltin((args) => jArg(args, 0) is JError),
        'isError',
        1,
      );
      prototype.properties['toString'] = jNamedFunction(
        JFunction((args, receiver) {
          if (!jIsObject(receiver))
            throw JThrown(JError('TypeError', 'Error object required'));
          final nameValue = jGet(receiver, 'name');
          final name = identical(nameValue, jUndefined)
              ? 'Error'
              : jString(nameValue);
          final messageValue = jGet(receiver, 'message');
          final message = identical(messageValue, jUndefined)
              ? ''
              : jString(messageValue);
          return name.isEmpty
              ? message
              : message.isEmpty
              ? name
              : '$name: $message';
        }, constructible: false),
        'toString',
        0,
      );
    } else {
      constructor.prototype = scope.get('Error') as JFunction;
    }
    jBuiltinProperties(constructor);
    jBuiltinProperties(prototype);
    scope.define(name, constructor);
  }
}

class JJsonParseRecord {
  final dynamic value;
  final String? source;
  final Map<String, JJsonParseRecord>? children;
  JJsonParseRecord(this.value, {this.source, this.children});
}

// jsonDecode validates the grammar first. This pass preserves the exact token
// boundaries and the last occurrence of each property for the reviver.
class JJsonSourceReader {
  final String text;
  int offset = 0;
  JJsonSourceReader(this.text);

  void skipSpace() {
    while (offset < text.length && ' \t\r\n'.contains(text[offset])) {
      offset++;
    }
  }

  String readString() {
    final start = offset++;
    while (text[offset] != '"') {
      if (text[offset] == r'\') offset++;
      offset++;
    }
    return text.substring(start, ++offset);
  }

  JJsonParseRecord read(dynamic value) {
    skipSpace();
    final start = offset;
    final open = text[offset];
    if (open == '{' || open == '[') {
      final children = <String, JJsonParseRecord>{};
      final object = open == '{';
      final closing = object ? '}' : ']';
      offset++;
      skipSpace();
      var index = 0;
      while (text[offset] != closing) {
        final String key;
        if (object) {
          key = jsonDecode(readString()) as String;
          skipSpace();
          offset++; // colon
        } else {
          key = '${index++}';
        }
        // The final duplicate property is recorded in the map. Earlier
        // occurrences can have a different structure from the decoded value.
        final present = jIsObject(value) ? jGet(value, key) : jUndefined;
        children[key] = read(present);
        skipSpace();
        if (text[offset] == closing) break;
        offset++; // comma
        skipSpace();
      }
      offset++;
      return JJsonParseRecord(value, children: children);
    }
    if (open == '"') {
      readString();
    } else {
      while (offset < text.length && !' \t\r\n,]}'.contains(text[offset])) {
        offset++;
      }
    }
    return JJsonParseRecord(value, source: text.substring(start, offset));
  }
}

class JConstruction {
  final JClass owner;
  final dynamic newTarget;
  dynamic _this = _jUninitialized;
  JConstruction(this.owner, this.newTarget);

  dynamic get thisValue {
    if (identical(_this, _jUninitialized)) {
      throw JThrown(
        JError('ReferenceError', 'Must call super before accessing this'),
      );
    }
    return _this;
  }

  dynamic initialize(dynamic receiver) {
    if (!identical(_this, _jUninitialized)) {
      throw JThrown(
        JError('ReferenceError', 'Super constructor has already bound this'),
      );
    }
    _this = receiver;
    for (final method in owner.privateMethods) {
      method.install(receiver);
    }
    for (final initialize in owner.fields) {
      initialize(receiver);
    }
    return receiver;
  }

  dynamic callSuper(List<dynamic> args) =>
      initialize(jNew(owner.prototype, args, newTarget: newTarget));
}

JObject jClassHome(JClass owner, bool isStatic) =>
    isStatic ? owner : owner.properties['prototype'] as JObject;

void jSetClassConstructor(JClass owner, JFunction body) {
  owner.body = body;
  owner.properties['length'] = body.properties['length'];
}

void jDefineClassField(dynamic receiver, Object key, dynamic value) {
  if (receiver is! JObject ||
      !jDefineProperty(
        receiver,
        key,
        JObject({
          'value': value,
          'writable': true,
          'enumerable': true,
          'configurable': true,
        }),
        normalized: true,
      )) {
    throw JThrown(JError('TypeError', 'Cannot initialize class field'));
  }
}

JRef jSuperReference(dynamic receiver, JObject home, dynamic key) {
  final property = jPropertyKey(key);
  final superclass = home.prototype;
  if (superclass == null)
    throw JThrown(JError('TypeError', 'Super prototype is null'));
  return JRef(() => superclass.read(property, receiver), (value) {
    if (!superclass.write(property, value, receiver)) {
      throw JThrown(JError('TypeError', 'Cannot assign super property'));
    }
    return value;
  });
}

JCallSite jSuperCallSite(
  dynamic receiver,
  JObject home,
  dynamic key, {
  bool optional = false,
}) => JCallSite(
  jSuperReference(receiver, home, key).read(),
  receiver: receiver,
  optional: optional,
);

class JPrivateSlot {
  dynamic value;
  JPrivateSlot(this.value);
}

class JPrivateName {
  final slots = Expando<JPrivateSlot>();
  JFunction? method, getter, setter;

  bool has(dynamic receiver) {
    if (!jIsObject(receiver))
      throw JThrown(
        JError('TypeError', 'Private member receiver must be an object'),
      );
    return slots[receiver] != null;
  }

  void install(dynamic receiver, [dynamic value = jUndefined]) {
    if (has(receiver))
      throw JThrown(JError('TypeError', 'Private member is already installed'));
    slots[receiver] = JPrivateSlot(value);
  }

  JPrivateSlot slot(dynamic receiver) {
    if (!has(receiver))
      throw JThrown(
        JError('TypeError', 'Object does not declare this private member'),
      );
    return slots[receiver]!;
  }

  dynamic read(dynamic receiver) {
    final entry = slot(receiver);
    if (method != null) return method;
    if (getter != null) return jCall(getter, [], receiver: receiver);
    if (setter != null)
      throw JThrown(JError('TypeError', 'Private accessor has no getter'));
    return entry.value;
  }

  dynamic write(dynamic receiver, dynamic value) {
    final entry = slot(receiver);
    if (setter != null) {
      jCall(setter, [value], receiver: receiver);
    } else {
      if (method != null || getter != null) {
        throw JThrown(JError('TypeError', 'Private member is not writable'));
      }
      entry.value = value;
    }
    return value;
  }

  JRef reference(dynamic receiver) =>
      JRef(() => read(receiver), (value) => write(receiver, value));

  JCallSite callSite(dynamic receiver, {bool optional = false}) =>
      JCallSite(read(receiver), receiver: receiver, optional: optional);

  void define(String kind, String name, JFunction function) {
    jNameFunction(
      function,
      kind == 'method' ? '#$name' : '$kind #$name',
      (function.properties['length'] as num).toInt(),
    );
    switch (kind) {
      case 'method':
        method = function;
      case 'get':
        getter = function;
      case 'set':
        setter = function;
    }
  }
}
