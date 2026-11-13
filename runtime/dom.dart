import 'dart:async';
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
  final _templates = Expando<dom.DocumentFragment>();
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
      : storage = storage ?? {} {
    prepareTemplates(document);
    final names = <String>{};
    for (final element in document.querySelectorAll('details[open]')) {
      final name = element.attributes['name'];
      if (name != null && name.isNotEmpty && !names.add(name)) {
        element.attributes.remove('open');
      } else {
        wrap(element).queueDetailsToggle(false, true);
      }
    }
  }
  JDomNode wrap(dom.Node node) =>
      _nodes.putIfAbsent(node, () => JDomNode(this, node));
  void changed() => onMutation?.call();

  dom.DocumentFragment templateContent(dom.Element template) =>
      _templates[template] ??= dom.DocumentFragment();

  void prepareTemplates(dom.Node root) {
    if (root is dom.Element && root.localName == 'template') {
      final content = templateContent(root);
      content.nodes.addAll(List<dom.Node>.of(root.nodes));
      root = content;
    }
    for (final child in root.nodes) {
      prepareTemplates(child);
    }
  }

  dom.Node cloneNode(dom.Node original, bool deep, {bool forHtml = false}) {
    final copy = original.clone(false);
    if (!deep) return copy;
    var source = original;
    var destination = copy;
    if (original is dom.Element && original.localName == 'template') {
      source = templateContent(original);
      if (!forHtml) destination = templateContent(copy as dom.Element);
    }
    for (final child in source.nodes) {
      destination.nodes.add(cloneNode(child, true, forHtml: forHtml));
    }
    return copy;
  }
  void setDetailsOpen(dom.Element element, bool open, {String value = ''}) {
    final wasOpen = element.attributes.containsKey('open');
    if (open) {
      element.attributes['open'] = value;
      if (!wasOpen) {
        wrap(element).queueDetailsToggle(false, true);
        final other = otherOpenDetails(element);
        if (other != null) setDetailsOpen(other, false);
      }
    } else {
      element.attributes.remove('open');
      if (wasOpen) wrap(element).queueDetailsToggle(true, false);
    }
    changed();
  }

  dom.Element? otherOpenDetails(dom.Element element) {
    final name = element.attributes['name'];
    if (name == null || name.isEmpty) return null;
    dom.Node root = element;
    while (root.parentNode != null) {
      root = root.parentNode!;
    }
    final elements = switch (root) {
      dom.Document() => root.querySelectorAll('details[open]'),
      dom.DocumentFragment() => root.querySelectorAll('details[open]'),
      dom.Element() => [
          if (root.localName == 'details' && root.attributes.containsKey('open'))
            root,
          ...root.querySelectorAll('details[open]'),
        ],
      _ => const <dom.Element>[],
    };
    for (final other in elements) {
      if (!identical(other, element) && other.attributes['name'] == name) {
        return other;
      }
    }
    return null;
  }

  void updateDetailsGroup(dom.Element element) {
    if (element.localName == 'details' && element.attributes.containsKey('open') &&
        otherOpenDetails(element) != null) {
      setDetailsOpen(element, false);
    }
  }

  void insertDetails(dom.Node root, {bool parsed = false}) {
    for (final element in [if (root is dom.Element) root, ...allElements(root)]) {
      if (element.localName == 'details' && element.attributes.containsKey('open')) {
        if (parsed) wrap(element).queueDetailsToggle(false, true);
        updateDetailsGroup(element);
      }
    }
  }

  dom.Element? firstSummary(dom.Element details) {
    for (final child in details.children) {
      if (child.localName == 'summary') return child;
    }
    return null;
  }
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
  Timer? _detailsToggle;
  bool? _detailsOldOpen;
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

  void queueDetailsToggle(bool wasOpen, bool open) {
    _detailsOldOpen ??= wasOpen;
    _detailsToggle?.cancel();
    _detailsToggle = Timer(Duration.zero, () {
      final oldOpen = _detailsOldOpen!;
      _detailsOldOpen = null;
      _detailsToggle = null;
      dispatch('toggle', data: {
        'oldState': oldOpen ? 'open' : 'closed',
        'newState': open ? 'open' : 'closed',
        'cancelable': false,
        'bubbles': false,
      });
    });
  }

  void dispatch(String type, {Map<String, dynamic> data = const {}}) {
    final event = JObject({
      'type': type,
      'target': this,
      'currentTarget': this,
      'defaultPrevented': false,
      ...data,
    });
    event.set('preventDefault', jNative((a) {
      if (event.get('cancelable') != false) event.set('defaultPrevented', true);
      return jUndefined;
    }));
    for (final fn in List<dynamic>.from(events[type] ?? [])) {
      jCall(fn, [event], receiver: this);
    }
    if (type == 'click' && node is dom.Element &&
        event.get('defaultPrevented') != true) {
      final element = node as dom.Element;
      if (element.localName == 'a') {
        final href = element.attributes['href'];
        if (href != null) runtime.onNavigate?.call(href);
      }
      final parent = element.parent;
      if (parent != null && parent.localName == 'details' &&
          identical(runtime.firstSummary(parent), element)) {
        runtime.setDetailsOpen(parent, !parent.attributes.containsKey('open'));
        return;
      }
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
        if (el == null) return '';
        if (el.localName == 'template') {
          final content = runtime.templateContent(el);
          return (runtime.cloneNode(content, true, forHtml: true)
                  as dom.DocumentFragment).outerHtml;
        }
        if (el.querySelector('template') != null) {
          return (runtime.cloneNode(el, true, forHtml: true) as dom.Element)
              .innerHtml;
        }
        return el.innerHtml;
      case 'content':
        if (el?.localName == 'template') {
          return runtime.wrap(runtime.templateContent(el!));
        }
        return jUndefined;
      case 'className':
        return el?.attributes['class'] ?? '';
      case 'id':
        return el?.id ?? '';
      case 'name':
        if (el?.localName == 'details') return el!.attributes['name'] ?? '';
        return jUndefined;
      case 'open':
        if (el?.localName == 'details' || el?.localName == 'dialog') {
          return el!.attributes.containsKey('open');
        }
        return jUndefined;
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
      case 'cloneNode':
        return jNative((a) =>
            runtime.wrap(runtime.cloneNode(node, jTruthy(jArg(a, 0)))));
      case 'getAttribute':
        return jNative((a) => el!.attributes[jString(a[0])]);
      case 'setAttribute':
        return jNative((a) {
          final key = jString(a[0]);
          final value = jString(a[1]);
          if (el!.localName == 'details' && key == 'open') {
            runtime.setDetailsOpen(el, true, value: value);
          } else {
            el.attributes[key] = value;
            if (key == 'name') runtime.updateDetailsGroup(el);
            runtime.changed();
          }
          return jUndefined;
        });
      case 'removeAttribute':
        return jNative((a) {
          final key = jString(a[0]);
          if (el!.localName == 'details' && key == 'open') {
            runtime.setDetailsOpen(el, false);
          } else {
            el.attributes.remove(key);
            runtime.changed();
          }
          return jUndefined;
        });
      case 'appendChild':
        return jNative((a) {
          final child = a[0] as JDomNode;
          if (child.node is dom.DocumentFragment) {
            final nodes = List<dom.Node>.from(child.node.nodes);
            for (final child in nodes) {
              node.nodes.add(child);
              runtime.insertDetails(child);
            }
            for (final child in nodes) {
              runtime.upgrade(child);
            }
          } else {
            node.nodes.add(child.node);
            runtime.insertDetails(child.node);
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
      case 'name':
        if (el?.localName != 'details') return super.set(name, value);
        el!.attributes['name'] = jString(value);
        runtime.updateDetailsGroup(el);
        break;
      case 'open':
        if (el?.localName != 'details') return super.set(name, value);
        runtime.setDetailsOpen(el!, jTruthy(value));
        return value;
      case 'textContent':
        node.text = jString(value);
        break;
      case 'innerHTML':
        final fragment =
            html.parseFragment(jString(value), container: el!.localName!);
        runtime.prepareTemplates(fragment);
        final destination =
            el.localName == 'template' ? runtime.templateContent(el) : node;
        destination.nodes.clear();
        for (final child in List<dom.Node>.from(fragment.nodes)) {
          destination.nodes.add(child);
          if (el.localName != 'template') runtime.insertDetails(child, parsed: true);
        }
        if (el.localName != 'template') runtime.upgrade(node);
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
