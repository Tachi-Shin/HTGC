import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'dom.dart';

List<String> cssSplit(String value, [String delimiter = ' ']) {
  final result = <String>[];
  var start = 0, depth = 0;
  String? quote;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (quote != null) {
      if (c == quote && (i == 0 || value[i - 1] != '\\')) quote = null;
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
      continue;
    }
    if (c == '(' || c == '[') depth++;
    if (c == ')' || c == ']') depth--;
    if (depth == 0 &&
        (delimiter == ' ' ? RegExp(r'\s').hasMatch(c) : c == delimiter)) {
      if (value.substring(start, i).trim().isNotEmpty)
        result.add(value.substring(start, i).trim());
      start = i + 1;
    }
  }
  if (value.substring(start).trim().isNotEmpty)
    result.add(value.substring(start).trim());
  return result;
}

class NativeCss {
  final JDomRuntime runtime;
  final List<dynamic> rules;
  final Map<dom.Element, Map<String, String>> _cache = Map.identity();
  final Map<String, Set<dom.Element>> _selectors = {};
  final Map<String, Map<String, dynamic>> keyframes = {};
  bool _layerRollback = false;
  NativeCss(this.runtime, this.rules) {
    final layers = <String, int>{};
    for (final r in rules) {
      final declarations = r['declarations'] as Map?;
      _layerRollback |= declarations?.values.any(
              (entry) => (entry[0] as String).toLowerCase() == 'revert-layer') ??
          false;
      final String? name = r['keyframes'];
      final int layer = r['layer'] ?? 0;
      if (name != null && layer >= (layers[name] ?? layer)) {
        layers[name] = layer;
        keyframes[name] = Map<String, dynamic>.from(r['frames']);
      }
    }
  }
  static const inherited = {
    'color',
    'font-size',
    'font-weight',
    'font-family',
    'font-style',
    'text-align',
    'line-height',
    'letter-spacing',
    'white-space',
    'list-style',
  };
  Map<String, String> get(dom.Element el, [String pseudo = '']) {
    if (pseudo.isEmpty && _cache.containsKey(el)) return _cache[el]!;
    final parent = el.parent is dom.Element
        ? get(el.parent as dom.Element)
        : <String, String>{};
    final result = <String, String>{
      for (final e in parent.entries)
        if (inherited.contains(e.key) || e.key.startsWith('--')) e.key: e.value
    };
    for (final entry in defaults(el).entries) {
      result.addAll(expand(entry.key, entry.value));
    }
    final inlineDeclarations = pseudo.isNotEmpty
        ? const <String>[]
        : [
            ...cssSplit(el.attributes['style'] ?? '', ';'),
            for (final e in runtime.wrap(el).style.values.entries)
              '${e.key}:${e.value}',
          ];
    final rollback = _layerRollback ||
        inlineDeclarations.any((text) => text.toLowerCase().contains('revert-layer'));
    final winners = <String, (String, List<int>)>{};
    final candidates = rollback
        ? <String, Map<(bool, int), (String, List<int>)>>{}
        : null;
    void apply(String name, String value, List<int> score) {
      for (final declaration in expand(name, value).entries) {
        if (candidates == null) {
          final previous = winners[declaration.key];
          if (previous == null || compare(score, previous.$2) >= 0) {
            winners[declaration.key] = (declaration.value, score);
          }
          continue;
        }
        final layers = candidates.putIfAbsent(declaration.key, () => {});
        final inline = score[1] != 0;
        final layer = score[0] == 0 ? score[2] : -score[2];
        final identity = (inline, layer);
        final previous = layers[identity];
        if (previous == null || compare(score, previous.$2) >= 0) {
          layers[identity] = (declaration.value, score);
        }
      }
    }
    var order = 0;
    for (final r in rules) {
      order++;
      if (r['selector'] == null) continue;
      String selector = r['selector'];
      final p = RegExp(r'::(before|after)$').firstMatch(selector);
      if ((p?[1] ?? '') != pseudo) continue;
      if (p != null) selector = selector.substring(0, p.start);
      if (!conditions(r['conditions'], el) || !matches(el, selector)) continue;
      final spec = List<int>.from(r['specificity']);
      final int layer = r['layer'] ?? 0;
      for (final e in (r['declarations'] as Map).entries) {
        final important = e.value[1] == true;
        apply(e.key, e.value[0],
            [important ? 1 : 0, 0, important ? -layer : layer, ...spec, order]);
      }
    }
    if (inlineDeclarations.isNotEmpty) {
      final important = RegExp(r'!\s*important\s*$', caseSensitive: false);
      for (final text in inlineDeclarations) {
        final colon = text.indexOf(':');
        if (colon <= 0) continue;
        final name = text.substring(0, colon).trim();
        final raw = text.substring(colon + 1).trim();
        final match = important.firstMatch(raw);
        final value = match == null ? raw : raw.substring(0, match.start).trim();
        if (value.isEmpty) continue;
        apply(name.startsWith('--') ? name : name.toLowerCase(), value,
            [match == null ? 0 : 1, 1, 0, 0, 0, 0, ++order]);
      }
    }
    for (final entry in candidates?.entries ?? const []) {
      final ordered = entry.value.values.toList()
        ..sort((a, b) => compare(b.$2, a.$2));
      // If an important layer rolls back, all weaker important layers are
      // eligible, but normal layers at or above that layer are also skipped.
      var normalLimit = 2;
      for (final candidate in ordered) {
        final (value, score) = candidate;
        final important = score[0] != 0;
        final inline = score[1] != 0;
        if (!important && (inline ? 1 : score[2]) >= normalLimit) continue;
        if (value.toLowerCase() == 'revert-layer') {
          if (important && !inline) normalLimit = math.min(normalLimit, -score[2]);
          continue;
        }
        winners[entry.key] = candidate;
        break;
      }
    }
    for (final entry in winners.entries) {
      final value = entry.value.$1;
      if (value.toLowerCase() != 'revert') result[entry.key] = value;
    }
    String substitute(String value) {
      for (var i = 0; i < 32 && value.contains('var('); i++) {
        final next = value.replaceAllMapped(
            RegExp(r'var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*))?\)'),
            (m) => result[m[1]] ?? m[2] ?? '');
        if (next == value) break;
        value = next;
      }
      return value;
    }

    for (final key in result.keys.toList()) {
      if (!key.startsWith('--')) result[key] = substitute(result[key]!);
    }
    normalize(result, parent);
    if (pseudo.isEmpty) _cache[el] = result;
    return result;
  }

  int compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      final d = a[i].compareTo(b[i]);
      if (d != 0) return d;
    }
    return 0;
  }

  bool matches(dom.Element element, String selector) {
    selector = selector
        .replaceAll(':root', 'html')
        .replaceAll(':focus-visible', '[data-htgc-focus]')
        .replaceAll(':focus', '[data-htgc-focus]')
        .replaceAll(':hover', '[data-htgc-hover]');
    final set = _selectors.putIfAbsent(
        selector, () => runtime.document.querySelectorAll(selector).toSet());
    return set.contains(element);
  }

  bool conditions(List<dynamic>? items, dom.Element element) {
    for (final item in items ?? []) {
      final String type = item[0], value = item[1];
      if (type == 'container')
        return false; // No query container exists unless container-type is established.
      if (type == 'supports')
        throw UnsupportedError('@supports is not implemented');
      if (value.contains('prefers-reduced-motion') && !runtime.reducedMotion)
        return false;
      if (value.contains('prefers-color-scheme: dark') && !runtime.dark)
        return false;
      for (final m
          in RegExp(r'(min|max)-width\s*:\s*([\d.]+)px').allMatches(value)) {
        final width = double.parse(m[2]!);
        if (m[1] == 'min' && runtime.viewportWidth < width ||
            m[1] == 'max' && runtime.viewportWidth > width) return false;
      }
    }
    return true;
  }

  Map<String, String> defaults(dom.Element el) {
    final tag = el.localName;
    final s = <String, String>{
      'display': 'block',
      'font-size': '16px',
      'font-weight': '400',
      'line-height': 'normal',
      'color': '#000000'
    };
    if (el.parent is dom.Element) {
      s.remove('font-size');
      s.remove('font-weight');
      s.remove('line-height');
      s.remove('color');
    }
    if (['span', 'a', 'strong', 'b', 'small', 'code', 'label', 'em', 'i', 'br']
        .contains(tag)) s['display'] = 'inline';
    if (['head', 'script', 'style', 'title', 'meta', 'link', 'noscript', 'template']
        .contains(tag)) s['display'] = 'none';
    if (tag == 'body') s['margin'] = '8px';
    if (tag == 'a') {
      s['color'] = '#0000ee';
      s['text-decoration'] = 'underline';
    }
    if (tag == 'strong' || tag == 'b') s['font-weight'] = '700';
    if (tag == 'em' || tag == 'i') s['font-style'] = 'italic';
    if (tag == 'small') s['font-size'] = '0.8333em';
    if (tag == 'p') s['margin'] = '1em 0';
    if (['ul', 'ol'].contains(tag)) {
      s['margin'] = '1em 0';
      s['padding-left'] = '40px';
    }
    if (tag == 'li') s['display'] = 'list-item';
    if (tag != null && RegExp(r'^h[1-6]$').hasMatch(tag)) {
      final sizes = ['2em', '1.5em', '1.17em', '1em', '.83em', '.67em'];
      s.addAll({
        'font-size': sizes[int.parse(tag[1]) - 1],
        'font-weight': '700',
        'margin': '.67em 0'
      });
    }
    if (tag == 'button') {
      s.addAll({
        'display': 'inline-block',
        'padding': '2px 6px',
        'background': '#efefef',
        'color': '#000000',
        'border': '2px solid #888888'
      });
    }
    return s;
  }

  Map<String, String> expand(String name, String value) {
    const aliases = {
      'inline-size': 'width',
      'block-size': 'height',
      'max-inline-size': 'max-width',
      'min-inline-size': 'min-width',
      'max-block-size': 'max-height',
      'min-block-size': 'min-height',
    };
    if (name == 'font') {
      final match = RegExp(r'([\d.]+(?:px|rem|em))(?:/([\d.]+(?:px|rem|em)?))?')
          .firstMatch(value);
      if (match != null) {
        return {
          'font-size': match[1]!,
          'line-height': match[2] ?? 'normal',
          'font-family': value.substring(match.end).trim()
        };
      }
    }
    if (['margin', 'padding', 'inset'].contains(name)) {
      final parts = cssSplit(value);
      final prefix = name == 'inset' ? '' : '$name-';
      if (parts.isNotEmpty) {
        return {
          '${prefix}top': parts.first,
          '${prefix}right': parts.length > 1 ? parts[1] : parts.first,
          '${prefix}bottom': parts.length > 2 ? parts[2] : parts.first,
          '${prefix}left': parts.length > 3
              ? parts[3]
              : parts.length > 1
                  ? parts[1]
                  : parts.first,
        };
      }
    }
    if (['margin-inline', 'padding-inline', 'margin-block', 'padding-block']
        .contains(name)) {
      final parts = cssSplit(value);
      final split = name.split('-');
      if (parts.isNotEmpty) {
        final inline = split[1] == 'inline';
        final prefix = split[0];
        return {
          '$prefix-${inline ? 'left' : 'top'}': parts.first,
          '$prefix-${inline ? 'right' : 'bottom'}': parts.last
        };
      }
    }
    if (name == 'place-items') {
      final parts = cssSplit(value);
      return {
        'place-items': value,
        'align-items': parts.first,
        'justify-items': parts.last
      };
    }
    return {aliases[name] ?? name: value};
  }

  void normalize(Map<String, String> style, Map<String, String> parent) {
    final parentSize =
        double.tryParse((parent['font-size'] ?? '16').replaceAll('px', '')) ??
            16;
    style['font-size'] =
        '${length(style['font-size'] ?? '${parentSize}px', font: parentSize) ?? parentSize}px';
  }

  double? length(String? value, {double basis = 0, double font = 16}) {
    if (value == null ||
        value == 'auto' ||
        value == 'none' ||
        value == 'normal') return null;
    value = value.trim();
    for (final fn in ['min', 'max', 'clamp']) {
      if (value.startsWith('$fn(') && value.endsWith(')')) {
        final a =
            cssSplit(value.substring(fn.length + 1, value.length - 1), ',')
                .map((x) => length(x, basis: basis, font: font) ?? 0)
                .toList();
        if (fn == 'min') return a.reduce(math.min);
        if (fn == 'max') return a.reduce(math.max);
        return a[1].clamp(a[0], a[2]);
      }
    }
    final m =
        RegExp(r'^(-?[\d.]+)(px|em|rem|vw|vh|svh|%|s|ms)?$').firstMatch(value);
    if (m == null) return null;
    final n = double.tryParse(m[1]!) ?? 0;
    switch (m[2]) {
      case 'em':
        return n * font;
      case 'rem':
        return n * 16;
      case 'vw':
        return n * runtime.viewportWidth / 100;
      case 'vh':
      case 'svh':
        return n * runtime.viewportHeight / 100;
      case '%':
        return n * basis / 100;
      case 's':
        return n * 1000;
      default:
        return n;
    }
  }
}

Color cssColor(String? text, [Color fallback = Colors.transparent]) {
  if (text == null) return fallback;
  text = text.trim().toLowerCase();
  const named = {
    'transparent': 0x00000000,
    'black': 0xff000000,
    'white': 0xffffffff,
    'red': 0xffff0000,
    'blue': 0xff0000ff,
    'green': 0xff008000,
    'gray': 0xff808080
  };
  if (named.containsKey(text)) return Color(named[text]!);
  if (text.startsWith('#')) {
    var hex = text.substring(1);
    if (hex.length == 3 || hex.length == 4)
      hex = hex.split('').map((c) => c + c).join();
    if (hex.length == 6)
      hex = 'ff$hex';
    else if (hex.length == 8) hex = hex.substring(6) + hex.substring(0, 6);
    return Color(int.tryParse(hex, radix: 16) ?? fallback.toARGB32());
  }
  final m = RegExp(r'^rgba?\((.*)\)$').firstMatch(text);
  if (m != null) {
    final parts =
        m[1]!.split(RegExp(r'[,\s/]+')).where((x) => x.isNotEmpty).toList();
    int channel(String s) => ((double.tryParse(s.replaceAll('%', '')) ?? 0) *
            (s.endsWith('%') ? 2.55 : 1))
        .round()
        .clamp(0, 255);
    return Color.fromRGBO(
        channel(parts[0]),
        channel(parts[1]),
        channel(parts[2]),
        parts.length > 3 ? (double.tryParse(parts[3]) ?? 1) : 1);
  }
  return fallback;
}
