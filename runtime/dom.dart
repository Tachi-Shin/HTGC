import 'js_core.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

class JDomRuntime {
  final dom.Document document;
  final Map<String, String> storage;
  final void Function()? onMutation;
  final void Function(String)? onNavigate;
  final void Function(Map<String, String>)? saveStorage;
  final Map<dom.Node, JDomNode> _nodes = Map.identity();
  final Map<String, JClass> customElements = {};
  final List<JObserver> observers = [];
  final List<dynamic> frames = [];
  final Map<dom.Element, Map<String, num>> bounds = Map.identity();
  bool dark = false, reducedMotion = false;
  double viewportWidth = 1200, viewportHeight = 800;
  JDomRuntime(this.document,
      {Map<String, String>? storage,
      this.onMutation,
      this.onNavigate,
      this.saveStorage})
      : storage = storage ?? {};
  JDomNode wrap(dom.Node node) =>
      _nodes.putIfAbsent(node, () => JDomNode(this, node));
  void changed() => onMutation?.call();
  List<dom.Element> allElements(dom.Node root) => [
        for (final child in root.nodes) ...[
          if (child is dom.Element) child,
          ...allElements(child)
        ]
      ];
  void upgrade(dom.Node root) {
    for (final el in [if (root is dom.Element) root, ...allElements(root)]) {
      final cls = customElements[el.localName];
      if (cls != null) {
        final node = wrap(el);
        if (node.upgraded) continue;
        node.upgraded = true;
        cls.attach(node);
        final callback = node.get('connectedCallback');
        if (callback is JFunction) jCall(callback, [], receiver: node);
      }
    }
  }

  JScope newScope() {
    final scope = JScope();
    installJSBuiltins(scope);
    final window = JObject();
    final localStorage = JObject({
      'getItem': jNative((a) => storage[jString(a[0])]),
      'setItem': jNative((a) {
        storage[jString(a[0])] = jString(a[1]);
        saveStorage?.call(storage);
        return jUndefined;
      }),
      'removeItem': jNative((a) {
        storage.remove(jString(a[0]));
        saveStorage?.call(storage);
        return jUndefined;
      }),
    });
    final globals = <String, dynamic>{
      'document': wrap(document),
      'window': window,
      'localStorage': localStorage,
      'HTMLElement': jNative((a) => wrap(dom.Element.tag('htgc-element'))),
      'customElements': JObject({
        'define': jNative((a) {
          final name = jString(a[0]);
          if (customElements.containsKey(name))
            throw StateError('Custom element already registered: $name');
          customElements[name] = a[1] as JClass;
          upgrade(document);
          return jUndefined;
        })
      }),
      'requestAnimationFrame': jNative((a) {
        frames.add(a[0]);
        return frames.length;
      }),
      'IntersectionObserver': jNative((a) {
        final observer = JObserver(this, a[0], false);
        observers.add(observer);
        return observer;
      }),
      'ResizeObserver': jNative((a) {
        final observer = JObserver(this, a[0], true);
        observers.add(observer);
        return observer;
      }),
      'matchMedia': jNative((a) {
        final query = jString(a[0]);
        return JObject({
          'matches': query.contains('prefers-reduced-motion')
              ? reducedMotion
              : query.contains('prefers-color-scheme')
                  ? dark
                  : false
        });
      }),
      'devicePixelRatio': 1,
      'innerWidth': viewportWidth,
      'innerHeight': viewportHeight,
    };
    for (final entry in globals.entries) {
      scope.define(entry.key, entry.value);
      window.set(entry.key, entry.value);
    }
    return scope;
  }

  void frame(num milliseconds, {double scrollY = 0}) {
    for (final observer in List<JObserver>.from(observers)) {
      observer.deliver(scrollY);
    }
    final callbacks = List<dynamic>.from(frames);
    frames.clear();
    for (final callback in callbacks) {
      jCall(callback, [milliseconds]);
    }
  }
}

class JDomNode extends JObject {
  final JDomRuntime runtime;
  final dom.Node node;
  final Map<String, List<dynamic>> events = {};
  bool upgraded = false;
  late final JStyle style = JStyle(this);
  JCanvasContext? canvas;
  int canvasWidth = 300, canvasHeight = 150;
  JDomNode(this.runtime, this.node);
  dynamic query(String selector, bool all) {
    final dynamic parent = node;
    if (all)
      return [
        for (final dom.Element el in parent.querySelectorAll(selector))
          runtime.wrap(el)
      ];
    final dom.Element? el = parent.querySelector(selector);
    return el == null ? null : runtime.wrap(el);
  }

  void dispatch(String type) {
    final event = JObject({
      'type': type,
      'target': this,
      'currentTarget': this,
      'defaultPrevented': false
    });
    event.set('preventDefault', jNative((a) {
      event.set('defaultPrevented', true);
      return jUndefined;
    }));
    for (final fn in List<dynamic>.from(events[type] ?? [])) {
      jCall(fn, [event], receiver: this);
    }
    if (type == 'click' &&
        node is dom.Element &&
        (node as dom.Element).localName == 'a' &&
        event.get('defaultPrevented') != true) {
      final href = (node as dom.Element).attributes['href'];
      if (href != null) runtime.onNavigate?.call(href);
    }
    runtime.changed();
  }

  @override
  dynamic get(String name) {
    final custom = super.get(name);
    if (!identical(custom, jUndefined)) return custom;
    final el = node is dom.Element ? node as dom.Element : null;
    switch (name) {
      case 'documentElement':
        final root = (node as dom.Document).documentElement;
        return root == null ? null : runtime.wrap(root);
      case 'body':
        final body = (node as dom.Document).body;
        return body == null ? null : runtime.wrap(body);
      case 'textContent':
        return node.text ?? '';
      case 'innerHTML':
        return el?.innerHtml ?? '';
      case 'className':
        return el?.attributes['class'] ?? '';
      case 'id':
        return el?.id ?? '';
      case 'tagName':
        return el?.localName?.toUpperCase() ?? '';
      case 'children':
        return [
          for (final child in node.nodes)
            if (child is dom.Element) runtime.wrap(child)
        ];
      case 'childNodes':
        return [for (final child in node.nodes) runtime.wrap(child)];
      case 'parentNode':
        return node.parentNode == null ? null : runtime.wrap(node.parentNode!);
      case 'dataset':
        return JDataset(this);
      case 'style':
        return style;
      case 'width':
        return canvasWidth;
      case 'height':
        return canvasHeight;
      case 'classList':
        return JObject({
          'add': jNative((a) {
            el!.classes.addAll(a.map(jString));
            runtime.changed();
            return jUndefined;
          }),
          'remove': jNative((a) {
            el!.classes.removeAll(a.map(jString));
            runtime.changed();
            return jUndefined;
          }),
          'contains': jNative((a) => el!.classes.contains(jString(a[0]))),
          'toggle': jNative((a) {
            final key = jString(a[0]);
            final add =
                a.length > 1 ? jTruthy(a[1]) : !el!.classes.contains(key);
            if (add) {
              el!.classes.add(key);
            } else {
              el!.classes.remove(key);
            }
            runtime.changed();
            return add;
          }),
        });
      case 'querySelector':
        return jNative((a) => query(jString(a[0]), false));
      case 'querySelectorAll':
        return jNative((a) => query(jString(a[0]), true));
      case 'getElementById':
        return jNative((a) {
          final id = jString(a[0]);
          for (final el in runtime.allElements(node)) {
            if (el.id == id) return runtime.wrap(el);
          }
          return null;
        });
      case 'createElement':
        return jNative((a) => runtime.wrap(dom.Element.tag(jString(a[0]))));
      case 'createTextNode':
        return jNative((a) => runtime.wrap(dom.Text(jString(a[0]))));
      case 'createDocumentFragment':
        return jNative((a) => runtime.wrap(dom.DocumentFragment()));
      case 'getAttribute':
        return jNative((a) => el!.attributes[jString(a[0])]);
      case 'setAttribute':
        return jNative((a) {
          el!.attributes[jString(a[0])] = jString(a[1]);
          runtime.changed();
          return jUndefined;
        });
      case 'removeAttribute':
        return jNative((a) {
          el!.attributes.remove(jString(a[0]));
          runtime.changed();
          return jUndefined;
        });
      case 'appendChild':
        return jNative((a) {
          final child = a[0] as JDomNode;
          if (child.node is dom.DocumentFragment) {
            final nodes = List<dom.Node>.from(child.node.nodes);
            node.nodes.addAll(nodes);
            for (final child in nodes) {
              runtime.upgrade(child);
            }
          } else {
            node.nodes.add(child.node);
            runtime.upgrade(child.node);
          }
          runtime.changed();
          return child;
        });
      case 'addEventListener':
        return jNative((a) {
          (events[jString(a[0])] ??= []).add(a[1]);
          return jUndefined;
        });
      case 'click':
        return jNative((a) {
          dispatch('click');
          return jUndefined;
        });
      case 'getBoundingClientRect':
        return jNative(
            (a) => JObject(Map<String, dynamic>.from(runtime.bounds[el] ??
                {
                  'x': 0,
                  'y': 0,
                  'width': canvasWidth,
                  'height': canvasHeight,
                  'top': 0,
                  'left': 0,
                  'bottom': canvasHeight,
                  'right': canvasWidth
                })));
      case 'getContext':
        return jNative((a) {
          if (jString(a[0]) != '2d')
            throw StateError('Only Canvas 2D is currently supported');
          return canvas ??= JCanvasContext(runtime);
        });
    }
    return jUndefined;
  }

  @override
  dynamic set(String name, dynamic value) {
    final el = node is dom.Element ? node as dom.Element : null;
    switch (name) {
      case 'textContent':
        node.text = jString(value);
        break;
      case 'innerHTML':
        final fragment =
            html.parseFragment(jString(value), container: el!.localName!);
        node.nodes.clear();
        node.nodes.addAll(List<dom.Node>.from(fragment.nodes));
        runtime.upgrade(node);
        break;
      case 'className':
        el!.attributes['class'] = jString(value);
        break;
      case 'id':
        el!.id = jString(value);
        break;
      case 'width':
        canvasWidth = jNumber(value).toInt();
        canvas?.commands.clear();
        break;
      case 'height':
        canvasHeight = jNumber(value).toInt();
        canvas?.commands.clear();
        break;
      default:
        return super.set(name, value);
    }
    runtime.changed();
    return value;
  }
}

class JDataset extends JObject {
  final JDomNode node;
  JDataset(this.node);
  String key(String name) =>
      'data-' +
      name.replaceAllMapped(RegExp('[A-Z]'), (m) => '-${m[0]!.toLowerCase()}');
  @override
  dynamic get(String name) =>
      (node.node as dom.Element).attributes[key(name)] ?? jUndefined;
  @override
  dynamic set(String name, dynamic value) {
    (node.node as dom.Element).attributes[key(name)] = jString(value);
    node.runtime.changed();
    return value;
  }
}

class JStyle extends JObject {
  final JDomNode node;
  JStyle(this.node);
  final Map<String, String> values = {};
  @override
  dynamic get(String name) {
    if (name == 'setProperty') return jNative((a) => set(jString(a[0]), a[1]));
    if (name == 'getPropertyValue')
      return jNative((a) => values[jString(a[0])] ?? '');
    return values[name] ?? '';
  }

  @override
  dynamic set(String name, dynamic value) {
    values[name] = jString(value);
    node.runtime.changed();
    return value;
  }
}

class JObserver extends JObject {
  final JDomRuntime runtime;
  final dynamic callback;
  final bool resize;
  final Map<JDomNode, Map<String, num>?> observed = {};
  JObserver(this.runtime, this.callback, this.resize);
  @override
  dynamic get(String name) {
    if (name == 'observe')
      return jNative((a) {
        observed.putIfAbsent(a[0], () => null);
        return jUndefined;
      });
    if (name == 'unobserve')
      return jNative((a) {
        observed.remove(a[0]);
        return jUndefined;
      });
    if (name == 'disconnect')
      return jNative((a) {
        observed.clear();
        return jUndefined;
      });
    return super.get(name);
  }

  void deliver(double scroll) {
    final entries = <dynamic>[];
    for (final item
        in Map<JDomNode, Map<String, num>?>.from(observed).entries) {
      final box = runtime.bounds[item.key.node];
      if (box == null) continue;
      if (resize) {
        if (item.value?['width'] == box['width'] &&
            item.value?['height'] == box['height']) continue;
        observed[item.key] = Map.of(box);
        entries.add(JObject(
            {'target': item.key, 'contentRect': JObject(Map.from(box))}));
      } else {
        final visible = (box['bottom'] ?? 0) > scroll &&
            (box['top'] ?? 0) < scroll + runtime.viewportHeight;
        if (item.value?['visible'] == (visible ? 1 : 0)) continue;
        observed[item.key] = {'visible': visible ? 1 : 0};
        entries.add(JObject({
          'target': item.key,
          'isIntersecting': visible,
          'intersectionRatio': visible ? 1 : 0
        }));
      }
    }
    if (entries.isNotEmpty) jCall(callback, [entries, this]);
  }
}

class JCanvasContext extends JObject {
  final JDomRuntime runtime;
  final List<List<dynamic>> commands = [];
  JCanvasContext(this.runtime)
      : super({
          'globalAlpha': 1.0,
          'fillStyle': '#000000',
          'strokeStyle': '#000000'
        });
  @override
  dynamic get(String name) {
    if (['clearRect', 'beginPath', 'arc', 'fill', 'moveTo', 'lineTo', 'stroke']
        .contains(name))
      return jNative((a) {
        if (name == 'clearRect') commands.clear();
        commands.add([name, ...a, Map<String, dynamic>.from(properties)]);
        runtime.changed();
        return jUndefined;
      });
    return super.get(name);
  }
}
