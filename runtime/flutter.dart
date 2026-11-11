import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:html/dom.dart' as dom;
import 'package:url_launcher/url_launcher.dart';
import 'js_core.dart';
import 'dom.dart';
import 'css.dart';

class NativeSiteApp extends StatefulWidget {
  final String entry;
  final Map<String, dynamic> pages, assets;
  final List<void Function(JScope)> scripts;
  final Map<String, String> storage;
  final void Function(Map<String, String>)? saveStorage;
  final void Function(Uri)? externalLink;
  final bool? reducedMotion;
  final Map<String, void Function(String)> handlers;
  const NativeSiteApp(
      {super.key,
      required this.entry,
      required this.pages,
      required this.assets,
      required this.scripts,
      required this.storage,
      this.saveStorage,
      this.externalLink,
      this.reducedMotion,
      this.handlers = const {}});
  @override
  NativeSiteState createState() => NativeSiteState();
}

class NativeSiteState extends State<NativeSiteApp>
    with SingleTickerProviderStateMixin {
  late JDomRuntime runtime;
  late NativeCss css;
  late String current;
  final ScrollController scroll = ScrollController();
  final Map<dom.Element, GlobalKey> nodeKeys = Map.identity();
  final Map<String, Uint8List> imageBytes = {};
  final List<String> history = [];
  final formKey = GlobalKey<FormState>();
  late Ticker ticker;
  double elapsed = 0;
  bool loading = false, queued = false, hasAnimation = false;
  dom.Document get document => runtime.document;
  @override
  void initState() {
    super.initState();
    ticker = createTicker((duration) {
      elapsed = duration.inMicroseconds / 1000;
      if (hasAnimation || runtime.frames.isNotEmpty) {
        if (mounted) setState(() {});
      }
    });
    load(widget.entry);
    scroll.addListener(queue);
  }

  dom.Node fromSpec(dynamic spec) {
    if (spec is String) return dom.Text(spec);
    final el = dom.Element.tag(spec['tag']);
    el.attributes.addAll(Map<String, String>.from(spec['attributes']));
    for (final child in spec['children']) {
      el.nodes.add(fromSpec(child));
    }
    return el;
  }

  void load(String path) {
    loading = true;
    current = path;
    nodeKeys.clear();
    final data = widget.pages[path];
    if (data == null) throw StateError('Page is not compiled: $path');
    final doc = dom.Document();
    doc.nodes.add(fromSpec(data['tree']));
    runtime = JDomRuntime(doc,
        storage: widget.storage,
        onMutation: queue,
        onNavigate: navigate,
        saveStorage: widget.saveStorage);
    final platform = WidgetsBinding.instance.platformDispatcher;
    runtime.dark = platform.platformBrightness == Brightness.dark;
    runtime.reducedMotion =
        widget.reducedMotion ?? platform.accessibilityFeatures.disableAnimations;
    final root = runtime.newScope();
    for (final int script in data['scripts']) {
      widget.scripts[script](JScope(root));
    }
    loading = false;
  }

  void queue() {
    if (loading || queued || !mounted) return;
    queued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      queued = false;
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void navigate(String href) {
    final uri = Uri(scheme: 'https', host: 'htgc.invalid', path: '/$current')
        .resolve(href);
    if (uri.host != 'htgc.invalid' || !['http', 'https'].contains(uri.scheme)) {
      if (!['http', 'https', 'mailto', 'tel'].contains(uri.scheme)) return;
      if (widget.externalLink != null) {
        widget.externalLink!(uri);
      } else {
        launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      return;
    }
    var path = Uri.decodeComponent(uri.path).replaceFirst(RegExp(r'^/'), '');
    if (path.isEmpty || path.endsWith('/')) path += 'index.html';
    if (path != current) {
      history.add(current);
      setState(() => load(path));
      if (scroll.hasClients) scroll.jumpTo(0);
    }
    if (uri.fragment.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final el = document.getElementById(Uri.decodeComponent(uri.fragment));
        final context = nodeKeys[el]?.currentContext;
        if (context != null) Scrollable.ensureVisible(context);
      });
    }
  }

  void back() {
    if (history.isNotEmpty) setState(() => load(history.removeLast()));
  }

  @override
  void dispose() {
    ticker.dispose();
    scroll.dispose();
    super.dispose();
  }

  void measure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final e in nodeKeys.entries) {
        final box = e.value.currentContext?.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final point = box.localToGlobal(Offset.zero);
          runtime.bounds[e.key] = {
            'x': point.dx,
            'y': point.dy,
            'top': point.dy + (scroll.hasClients ? scroll.offset : 0),
            'left': point.dx,
            'width': box.size.width,
            'height': box.size.height,
            'bottom': point.dy +
                box.size.height +
                (scroll.hasClients ? scroll.offset : 0),
            'right': point.dx + box.size.width
          };
        }
      }
      runtime.frame(elapsed, scrollY: scroll.hasClients ? scroll.offset : 0);
      if (hasAnimation || runtime.frames.isNotEmpty) {
        if (!ticker.isActive) ticker.start();
      } else if (ticker.isActive) {
        ticker.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: widget.pages[current]['title'],
        theme: ThemeData(useMaterial3: false),
        home: Builder(builder: (context) {
          final media = MediaQuery.of(context);
          runtime.viewportWidth = media.size.width;
          runtime.viewportHeight = media.size.height;
          runtime.dark = media.platformBrightness == Brightness.dark;
          runtime.reducedMotion = widget.reducedMotion ?? media.disableAnimations;
          css = NativeCss(
              runtime, List<dynamic>.from(widget.pages[current]['styles']));
          hasAnimation = false;
          final body = document.body!;
          final style = css.get(body);
          final children = body.nodes
              .where((n) => n is dom.Element && css.get(n)['display'] != 'none')
              .cast<dom.Element>()
              .toList();
          final fixed = <dom.Element>[];
          final flow = <dom.Element>[];
          for (final child in children) {
            final elements = [child, ...runtime.allElements(child)];
            if (flow.isEmpty &&
                elements.any((e) => css.get(e)['position'] == 'sticky'))
              fixed.add(child);
            else
              flow.add(child);
          }
          measure();
          final scrollBody = SingleChildScrollView(
              controller: scroll,
              child: Form(
                  key: formKey,
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final el in flow) buildNode(el)])));
          return Scaffold(
              backgroundColor: backgroundColor(style),
              body: DecoratedBox(
                  decoration: decoration(style, media.size.width),
                  child: paintBackground(
                      style,
                      Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final el in fixed) buildNode(el),
                            Expanded(child: scrollBody)
                          ]))));
        }));
  }

  double font(Map<String, String> s) => css.length(s['font-size']) ?? 16;
  EdgeInsets edges(Map<String, String> s, String prefix, double width) =>
      EdgeInsets.fromLTRB(
          css.length(s['$prefix-left'], basis: width, font: font(s)) ?? 0,
          css.length(s['$prefix-top'], basis: width, font: font(s)) ?? 0,
          css.length(s['$prefix-right'], basis: width, font: font(s)) ?? 0,
          css.length(s['$prefix-bottom'], basis: width, font: font(s)) ?? 0);
  TextStyle textStyle(Map<String, String> s) {
    final size = font(s);
    final line = double.tryParse(s['line-height'] ?? '');
    return TextStyle(
        color: cssColor(s['color'], Colors.black),
        fontSize: size,
        fontWeight: FontWeight.values[
            ((int.tryParse(s['font-weight'] ?? '400') ?? 400) / 100)
                    .round()
                    .clamp(1, 9) -
                1],
        fontStyle:
            s['font-style'] == 'italic' ? FontStyle.italic : FontStyle.normal,
        height: line ??
            (css.length(s['line-height'], font: size)?.toDouble() != null
                ? css.length(s['line-height'], font: size)! / size
                : null),
        letterSpacing: css.length(s['letter-spacing'], font: size),
        decoration: s['text-decoration'] == 'underline'
            ? TextDecoration.underline
            : TextDecoration.none);
  }

  Color backgroundColor(Map<String, String> s) {
    final raw = s['background-color'] ?? s['background'] ?? 'transparent';
    final parts = cssSplit(raw, ',');
    return cssColor(parts.isEmpty ? null : parts.last);
  }

  BorderSide borderSide(String? raw, Map<String, String> s) {
    if (raw == null || raw == 'none') return BorderSide.none;
    final tokens = cssSplit(raw);
    final color = cssColor(s['border-color'] ??
        (tokens.length > 2 ? tokens.sublist(2).join(' ') : s['color']));
    return BorderSide(
        width: css.length(tokens.first, font: font(s)) ?? 1, color: color);
  }

  Border borders(Map<String, String> s) {
    final base = borderSide(s['border'], s);
    return Border(
        top:
            s.containsKey('border-top') ? borderSide(s['border-top'], s) : base,
        right: s.containsKey('border-right')
            ? borderSide(s['border-right'], s)
            : base,
        bottom: s.containsKey('border-bottom')
            ? borderSide(s['border-bottom'], s)
            : base,
        left: s.containsKey('border-left')
            ? borderSide(s['border-left'], s)
            : base);
  }

  BoxDecoration decoration(Map<String, String> s, double width,
      {bool mask = false}) {
    final border = borders(s);
    final shadows = <BoxShadow>[];
    for (final raw in cssSplit(s['box-shadow'] ?? '', ',')) {
      final p = cssSplit(raw);
      if (p.length >= 4) {
        shadows.add(BoxShadow(
            offset: Offset(css.length(p[0]) ?? 0, css.length(p[1]) ?? 0),
            blurRadius: css.length(p[2]) ?? 0,
            color: cssColor(p.sublist(3).join(' '))));
      }
    }
    return BoxDecoration(
        color: mask ? null : backgroundColor(s),
        border: border,
        borderRadius: border.isUniform
            ? BorderRadius.circular(
                css.length(s['border-radius'], basis: width, font: font(s)) ??
                    0)
            : null,
        boxShadow: shadows);
  }

  bool inline(dom.Node n) =>
      n is dom.Text ||
      n is dom.Element &&
          ['inline', 'inline-block', 'inline-flex']
              .contains(css.get(n)['display']);
  InlineSpan span(dom.Node n, Map<String, String> inherited) {
    if (n is dom.Text)
      return TextSpan(text: n.text.replaceAll(RegExp(r'\s+'), ' '));
    final el = n as dom.Element;
    final s = css.get(el);
    if (s['display'] == 'none' || s.containsKey('clip'))
      return const TextSpan(text: '');
    if (el.localName == 'br') return const TextSpan(text: '\n');
    if (['a', 'img', 'input', 'meter'].contains(el.localName) ||
        s['display'] != 'inline')
      return WidgetSpan(child: buildNode(el, shrink: true));
    return TextSpan(
        style: textStyle(s),
        children: [for (final child in el.nodes) span(child, s)]);
  }

  Widget textFlow(List<dom.Node> children, Map<String, String> s) => RichText(
      textAlign: s['text-align'] == 'center'
          ? TextAlign.center
          : s['text-align'] == 'right'
              ? TextAlign.right
              : TextAlign.left,
      text: TextSpan(
          style: textStyle(s),
          children: [for (final child in children) span(child, s)]));
  String assetPath(String reference) {
    if (reference.startsWith('/')) return reference.substring(1);
    return Uri(path: current).resolve(reference).path;
  }

  Uint8List bytes(String path) => imageBytes.putIfAbsent(
      path, () => base64Decode(widget.assets[path] as String));
  Widget imageWidget(String reference, double? width, double? height,
      {Color? tint, BoxFit fit = BoxFit.contain}) {
    final path =
        widget.assets.containsKey(reference) ? reference : assetPath(reference);
    if (!widget.assets.containsKey(path))
      return Image.network(reference, width: width, height: height, fit: fit);
    if (path.toLowerCase().endsWith('.svg'))
      return SvgPicture.memory(bytes(path),
          width: width,
          height: height,
          fit: fit,
          colorFilter:
              tint == null ? null : ColorFilter.mode(tint, BlendMode.srcIn));
    return Image.memory(bytes(path),
        width: width,
        height: height,
        fit: fit,
        filterQuality: FilterQuality.medium);
  }

  Widget buildNode(dom.Element el,
      {bool shrink = false, double? containingHeight}) {
    final s = css.get(el);
    if (s['display'] == 'none') return const SizedBox.shrink();
    final key = nodeKeys.putIfAbsent(el, () => GlobalKey());
    return KeyedSubtree(
        key: key,
        child: LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : runtime.viewportWidth;
          final heightBasis = containingHeight ??
              (constraints.hasBoundedHeight
                  ? constraints.maxHeight
                  : runtime.viewportHeight);
          return box(el, s, width, heightBasis,
              shrink: shrink || !constraints.hasBoundedWidth);
        }));
  }

  Widget box(dom.Element el, Map<String, String> s, double available,
      double heightBasis,
      {bool shrink = false, String pseudo = ''}) {
    if (pseudo.isNotEmpty && !s.containsKey('content'))
      return const SizedBox.shrink();
    final f = font(s),
        margin = edges(s, 'margin', available),
        padding = edges(s, 'padding', available).add(borders(s).dimensions) as EdgeInsets;
    final outerWidth = math.max(0.0, available - margin.horizontal);
    final maxWidth = css.length(s['max-width'], basis: outerWidth, font: f) ??
        double.infinity;
    final requestedWidth = css.length(s['width'], basis: outerWidth, font: f);
    final block = !shrink &&
        !['inline', 'inline-block', 'inline-flex'].contains(s['display']);
    final width = requestedWidth == null && !block
        ? null
        : math.min(requestedWidth ?? outerWidth, maxWidth);
    final height = css.length(s['height'], basis: heightBasis, font: f);
    final innerWidth = math.max(
        0.0, math.min(width ?? outerWidth, maxWidth) - padding.horizontal);
    final children = el.nodes
        .where((n) =>
            n is dom.Element || n is dom.Text && n.text.trim().isNotEmpty)
        .toList();
    final flow = <dom.Node>[];
    final absolute = <dom.Element>[];
    if (pseudo.isEmpty) {
      for (final child in children) {
        if (child is dom.Element && css.get(child)['position'] == 'absolute')
          absolute.add(child);
        else
          flow.add(child);
      }
    }
    Widget content;
    final mask = s['mask-image'] ?? s['-webkit-mask-image'];
    if (mask != null) {
      final ref =
          RegExp(r'url\(["\x27]?(.*?)["\x27]?\)').firstMatch(mask)?[1] ?? '';
      content = imageWidget(ref, width, height, tint: backgroundColor(s));
    } else if (pseudo.isNotEmpty) {
      content = Text(
          (s['content'] ?? '').replaceAll(RegExp(r'^["\x27]|["\x27]$'), ''),
          style: textStyle(s));
    } else if (el.localName == 'img') {
      content = imageWidget(el.attributes['src'] ?? '', width, height,
          fit: s['object-fit'] == 'cover' ? BoxFit.cover : BoxFit.contain);
    } else if (el.localName == 'canvas') {
      content = CustomPaint(
          size: Size(width ?? 300, height ?? 150),
          painter: NativeCanvasPainter(runtime.wrap(el).canvas));
    } else if (el.localName == 'meter') {
      content = SizedBox(
          width: width ?? 160,
          height: height ?? 12,
          child: LinearProgressIndicator(
              value: double.tryParse(el.attributes['value'] ?? '0'),
              color: Colors.green,
              backgroundColor: Colors.black12));
    } else if (['input', 'textarea'].contains(el.localName)) {
      if (el.attributes['type'] == 'hidden') return const SizedBox.shrink();
      content = TextFormField(
          key: ValueKey(el),
          initialValue: el.attributes['value'],
          style: textStyle(s),
          maxLines: el.localName == 'textarea'
              ? int.tryParse(el.attributes['rows'] ?? '6') ?? 6
              : 1,
          decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero),
          validator: (value) {
            if (el.attributes.containsKey('required') && (value ?? '').isEmpty)
              return '入力してください';
            if (el.attributes['type'] == 'email' &&
                (value ?? '').isNotEmpty &&
                !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value!))
              return 'メールアドレスを確認してください';
            return null;
          },
          onChanged: (value) {
            el.attributes['value'] = value;
            widget.handlers[el.attributes['oninput']]?.call(value);
            runtime.wrap(el).dispatch('input');
          });
    } else if (s['display'] == 'grid' && s['grid-template-columns'] != null) {
      final template = s['grid-template-columns']!;
      final gap = css.length(s['gap'], basis: innerWidth, font: f) ?? 0;
      List<double> columns = [];
      if (template.contains('repeat(')) {
        final minimum = RegExp(r'minmax\(([^,]+),').firstMatch(template)?[1];
        final min = css.length(minimum, basis: innerWidth, font: f) ?? 220;
        final capacity =
            math.max(1, ((innerWidth + gap) / (min + gap)).floor());
        final count = template.contains('auto-fit')
            ? math.min(capacity, math.max(1, flow.length))
            : capacity;
        columns = List.filled(
            count, math.max(0, (innerWidth - gap * (count - 1)) / count));
      } else {
        final tracks = cssSplit(template);
        final fixed = tracks.where((t) => !t.endsWith('fr')).fold<double>(
            0, (a, b) => a + (css.length(b, basis: innerWidth, font: f) ?? 0));
        final fractions = tracks.where((t) => t.endsWith('fr')).fold<double>(
            0, (a, b) => a + (double.tryParse(b.replaceAll('fr', '')) ?? 1));
        final remaining =
            math.max(0, innerWidth - fixed - gap * (tracks.length - 1));
        columns = [
          for (final track in tracks)
            track.endsWith('fr')
                ? remaining *
                    (double.tryParse(track.replaceAll('fr', '')) ?? 1) /
                    math.max(1, fractions)
                : css.length(track, basis: innerWidth, font: f) ?? 0
        ];
      }
      content = NativeGrid(
          columns: columns,
          gap: gap,
          align: s['align-items'] ?? 'stretch',
          autoHeights: [
            for (final child in flow)
              child is! dom.Element ||
                  (css.get(child)['height'] ?? 'auto') == 'auto'
          ],
          children: [
            for (final child in flow)
              child is dom.Element ? buildNode(child) : textFlow([child], s)
          ]);
    } else if (['flex', 'inline-flex'].contains(s['display'])) {
      final items = [
        for (final child in flow)
          child is dom.Element
              ? buildNode(child, shrink: true)
              : textFlow([child], s)
      ];
      final gap = css.length(s['gap'], basis: innerWidth, font: f) ?? 0;
      if (s['flex-wrap'] == 'wrap')
        content = Wrap(
            spacing: gap,
            runSpacing: gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: items);
      else if (s['flex-direction'] == 'column')
        content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) SizedBox(height: gap),
                items[i]
              ]
            ]);
      else
        content = NativeFlex(
            gap: gap,
            justify: s['justify-content'] ?? 'start',
            align: s['align-items'] ?? 'stretch',
            children: items);
    } else if (flow.every(inline)) {
      final marker = s['display'] == 'list-item' && s['list-style'] != 'none';
      content = textFlow([if (marker) dom.Text('• '), ...flow], s);
    } else {
      final items = <Widget>[];
      var run = <dom.Node>[];
      void flush() {
        if (run.isNotEmpty) {
          items.add(textFlow(run, s));
          run = [];
        }
      }

      for (final child in flow) {
        if (inline(child)) {
          run.add(child);
        } else {
          flush();
          items.add(buildNode(child as dom.Element));
        }
      }
      flush();
      final gap = s['display'] == 'grid'
          ? css.length(s['gap'], basis: innerWidth, font: f) ?? 0.0
          : 0.0;
      content = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: s['justify-items'] == 'center'
              ? CrossAxisAlignment.center
              : CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) SizedBox(height: gap),
              items[i]
            ]
          ]);
    }
    if (s['display'] == 'grid' && s['place-items'] == 'center')
      content = Center(child: content);
    content = Padding(padding: padding, child: content);
    final minHeight =
        css.length(s['min-height'], basis: heightBasis, font: f) ?? 0;
    content = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight, maxWidth: maxWidth),
        child: content);
    if (absolute.isNotEmpty ||
        pseudo.isEmpty &&
            ['before', 'after']
                .any((p) => css.get(el, p).containsKey('content'))) {
      final layers = <({int z, int order, Widget child})>[];
      layers.add((z: 0, order: 0, child: content));
      final containingHeight =
          height ?? (minHeight > 0 ? minHeight : heightBasis);
      Widget position(Widget child, Map<String, String> style) => Positioned(
          left: css.length(style['left'], basis: width ?? available, font: f),
          right: css.length(style['right'], basis: width ?? available, font: f),
          top: css.length(style['top'], basis: containingHeight, font: f),
          bottom: css.length(style['bottom'], basis: containingHeight, font: f),
          child: child);
      for (var index = 0; index < absolute.length; index++) {
        final child = absolute[index];
        final st = css.get(child);
        layers.add((
          z: int.tryParse(st['z-index'] ?? '0') ?? 0,
          order: index + 1,
          child:
              position(buildNode(child, containingHeight: containingHeight), st)
        ));
      }
      if (pseudo.isEmpty) {
        for (final p in ['before', 'after']) {
          final st = css.get(el, p);
          if (st.containsKey('content'))
            layers.add((
              z: int.tryParse(st['z-index'] ?? '0') ?? 0,
              order: p == 'before' ? -1 : absolute.length + 1,
              child: position(
                  box(el, st, width ?? available, height ?? heightBasis,
                      pseudo: p, shrink: true),
                  st)
            ));
        }
      }
      layers.sort((a, b) {
        final stacking = a.z.compareTo(b.z);
        return stacking == 0 ? a.order.compareTo(b.order) : stacking;
      });
      content = Stack(
          clipBehavior: Clip.none,
          children: layers.map((e) => e.child).toList());
    }
    final radius =
        css.length(s['border-radius'], basis: width ?? available, font: f) ?? 0;
    if (radius > 0 || s['overflow'] == 'hidden') {
      content = ClipRRect(
          borderRadius: BorderRadius.circular(radius), child: content);
    }
    content = paintBackground(s, content);
    content = DecoratedBox(
        decoration: decoration(s, width ?? available, mask: mask != null),
        child: content);
    final outline = borderSide(s['outline'], s);
    if (outline != BorderSide.none) {
      content = CustomPaint(
          foregroundPainter: NativeOutlinePainter(outline, radius),
          child: content);
    }
    if (s.containsKey('clip')) {
      content = ClipRect(clipper: NativeTinyClip(), child: content);
    }
    content = SizedBox(width: width, height: height, child: content);
    final autoLeft = s['margin-left'] == 'auto';
    final autoRight = s['margin-right'] == 'auto';
    if (autoLeft || autoRight || width != null && width < outerWidth) {
      final alignment = autoLeft && autoRight
          ? Alignment.topCenter
          : autoLeft
              ? Alignment.topRight
              : Alignment.topLeft;
      content = Align(
          alignment: alignment,
          widthFactor: autoLeft || autoRight ? null : 1,
          child: content);
    }
    content = Padding(padding: margin, child: content);
    var transform = s['transform'] ?? 'none';
    if (!runtime.reducedMotion &&
        s['animation'] != null &&
        s['animation'] != 'none') {
      hasAnimation = true;
      final fields = cssSplit(s['animation']!);
      final frames = css.keyframes[fields.first];
      final ms = fields.length > 1 ? css.length(fields[1]) ?? 1000 : 1000;
      if (frames != null) {
        final a =
            Map<String, dynamic>.from(frames['from'] ?? frames['0%'] ?? {});
        final b =
            Map<String, dynamic>.from(frames['to'] ?? frames['100%'] ?? {});
        if (a['transform'] != null && b['transform'] != null) {
          transform = interpolateTransform(
              a['transform'][0], b['transform'][0], (elapsed % ms) / ms);
        }
      }
    }
    final translation = transformTranslation(
        transform, width ?? available, height ?? heightBasis);
    if (translation.$1 != Offset.zero)
      content = Transform.translate(offset: translation.$1, child: content);
    if (translation.$2 != Offset.zero)
      content =
          FractionalTranslation(translation: translation.$2, child: content);
    final opacity = (double.tryParse(s['opacity'] ?? '1') ?? 1).clamp(0.0, 1.0);
    final transition = RegExp(r'([\d.]+m?s)').firstMatch(s['transition'] ?? '');
    content = AnimatedOpacity(
        opacity: opacity,
        duration: Duration(
            milliseconds: runtime.reducedMotion
                ? 0
                : (css.length(transition?[1]) ?? 0).round()),
        child: content);
    if (s.containsKey('backdrop-filter')) {
      final blur =
          RegExp(r'blur\(([^)]+)\)').firstMatch(s['backdrop-filter']!)?[1];
      final sigma = css.length(blur) ?? 0;
      content = ClipRect(
          child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: content));
    }
    if (s['pointer-events'] == 'none') return IgnorePointer(child: content);
    if (pseudo.isNotEmpty) return content;
    final click = el.localName == 'a' ||
        el.localName == 'button' ||
        runtime.wrap(el).events.containsKey('click');
    if (click) {
      void activate() {
        widget.handlers[el.attributes['onclick']]?.call('');
        if (el.localName == 'button' && el.attributes['type'] == 'submit') {
          formKey.currentState?.validate();
        } else {
          runtime.wrap(el).dispatch('click');
        }
      }

      content = FocusableActionDetector(
        onFocusChange: (focused) => setFocus(el, focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            activate();
            return null;
          })
        },
        child: Semantics(
          label: el.attributes['aria-label'],
          button: el.localName == 'button',
          link: el.localName == 'a',
          child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: activate,
              child: content),
        ),
      );
    } else if (['input', 'textarea'].contains(el.localName)) {
      content = Focus(
          canRequestFocus: false,
          onFocusChange: (focused) => setFocus(el, focused),
          child: content);
    }
    return MouseRegion(
        cursor: click ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) {
          el.attributes['data-htgc-hover'] = '';
          queue();
        },
        onExit: (_) {
          el.attributes.remove('data-htgc-hover');
          queue();
        },
        child: content);
  }

  void setFocus(dom.Element el, bool focused) {
    if (focused) {
      el.attributes['data-htgc-focus'] = '';
    } else {
      el.attributes.remove('data-htgc-focus');
    }
    queue();
  }

  Widget paintBackground(Map<String, String> style, Widget child) {
    final layers = cssSplit(style['background'] ?? '', ',')
        .where((layer) =>
            layer.startsWith('linear-gradient(') ||
            layer.startsWith('radial-gradient('))
        .toList();
    if (layers.isEmpty) return child;
    return CustomPaint(
        painter: NativeBackgroundPainter(css, layers), child: child);
  }

  (Offset, Offset) transformTranslation(String text, double w, double h) {
    double x = 0, y = 0, fx = 0, fy = 0;
    for (final m in RegExp(r'translate(X|Y)?\(([^)]+)\)').allMatches(text)) {
      final values = cssSplit(m[2]!, ',');
      void add(String v, bool horizontal) {
        if (v.trim().endsWith('%')) {
          final n = (double.tryParse(v.trim().replaceAll('%', '')) ?? 0) / 100;
          if (horizontal)
            fx += n;
          else
            fy += n;
        } else {
          final n = css.length(v) ?? 0;
          if (horizontal)
            x += n;
          else
            y += n;
        }
      }

      if (m[1] == 'X')
        add(values[0], true);
      else if (m[1] == 'Y')
        add(values[0], false);
      else {
        add(values[0], true);
        if (values.length > 1) add(values[1], false);
      }
    }
    return (Offset(x, y), Offset(fx, fy));
  }

  String interpolateTransform(String a, String b, double t) {
    final numbers = RegExp(r'-?[\d.]+');
    final end = numbers.allMatches(b).map((m) => double.parse(m[0]!)).toList();
    var i = 0;
    return a.replaceAllMapped(numbers, (m) {
      final n = double.parse(m[0]!);
      return '${n + ((i < end.length ? end[i++] : n) - n) * t}';
    });
  }
}

class NativeBackgroundPainter extends CustomPainter {
  final NativeCss css;
  final List<String> layers;
  NativeBackgroundPainter(this.css, this.layers);

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    for (final layer in layers.reversed) {
      final open = layer.indexOf('(');
      final terms = cssSplit(layer.substring(open + 1, layer.length - 1), ',');
      if (terms.length < 2) continue;
      final radial = layer.startsWith('radial-gradient');
      final prefix = terms.first;
      final hasPosition =
          radial ? prefix.contains(' at ') : prefix.startsWith('to ');
      final stops = terms.skip(hasPosition ? 1 : 0).toList();
      if (stops.length < 2) continue;
      final colors = <Color>[];
      final positions = <double>[];
      for (var index = 0; index < stops.length; index++) {
        final fields = cssSplit(stops[index]);
        final explicit = fields.length > 1 && fields.last.endsWith('%');
        colors.add(cssColor(explicit
            ? fields.sublist(0, fields.length - 1).join(' ')
            : fields.join(' ')));
        positions.add(explicit
            ? (css.length(fields.last, basis: 1) ?? 0).clamp(0, 1)
            : index / (stops.length - 1));
      }
      ui.Shader shader;
      if (radial) {
        final position = prefix.split(' at ');
        final radii = hasPosition ? cssSplit(position.first) : <String>[];
        final center = hasPosition ? cssSplit(position.last) : <String>[];
        final cx = css.length(center.isEmpty ? null : center.first,
                basis: size.width) ??
            size.width / 2;
        final cy = css.length(center.length < 2 ? null : center[1],
                basis: size.height) ??
            size.height / 2;
        final rx =
            css.length(radii.isEmpty ? null : radii.first, basis: size.width) ??
                size.width / 2;
        final ry = css.length(radii.length < 2 ? null : radii[1],
                basis: size.height) ??
            rx;
        if (rx <= 0 || ry <= 0) continue;
        final matrix = Matrix4.diagonal3Values(rx, ry, 1)
          ..setTranslationRaw(cx, cy, 0);
        shader = ui.Gradient.radial(
            Offset.zero, 1, colors, positions, TileMode.clamp, matrix.storage);
      } else {
        final (start, end) = switch (prefix) {
          'to right' => (bounds.centerLeft, bounds.centerRight),
          'to left' => (bounds.centerRight, bounds.centerLeft),
          'to top' => (bounds.bottomCenter, bounds.topCenter),
          _ => (bounds.topCenter, bounds.bottomCenter),
        };
        shader = ui.Gradient.linear(start, end, colors, positions);
      }
      canvas.drawRect(bounds, Paint()..shader = shader);
    }
  }

  @override
  bool shouldRepaint(NativeBackgroundPainter oldDelegate) =>
      oldDelegate.layers.join() != layers.join();
}

class NativeOutlinePainter extends CustomPainter {
  final BorderSide outline;
  final double radius;
  NativeOutlinePainter(this.outline, this.radius);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).inflate(outline.width / 2);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            rect, Radius.circular(radius + outline.width / 2)),
        outline.toPaint());
  }

  @override
  bool shouldRepaint(NativeOutlinePainter oldDelegate) =>
      oldDelegate.outline != outline || oldDelegate.radius != radius;
}

class NativeTinyClip extends CustomClipper<Rect> {
  @override
  Rect getClip(Size size) => const Rect.fromLTWH(0, 0, 0, 0);
  @override
  bool shouldReclip(NativeTinyClip old) => false;
}

class NativeCanvasPainter extends CustomPainter {
  final JCanvasContext? context;
  NativeCanvasPainter(this.context);
  @override
  void paint(Canvas canvas, Size size) {
    var path = Path();
    for (final command in context?.commands ?? <List<dynamic>>[]) {
      final props = command.last as Map<String, dynamic>;
      final fill = Paint()
        ..color = cssColor(jString(props['fillStyle']))
            .withValues(alpha: jNumber(props['globalAlpha']).toDouble());
      final stroke = Paint()
        ..color = cssColor(jString(props['strokeStyle']))
            .withValues(alpha: jNumber(props['globalAlpha']).toDouble())
        ..style = PaintingStyle.stroke;
      double n(int i) => jNumber(command[i]).toDouble();
      switch (command[0]) {
        case 'beginPath':
          path = Path();
          break;
        case 'arc':
          path.addArc(Rect.fromCircle(center: Offset(n(1), n(2)), radius: n(3)),
              n(4), n(5) - n(4));
          break;
        case 'moveTo':
          path.moveTo(n(1), n(2));
          break;
        case 'lineTo':
          path.lineTo(n(1), n(2));
          break;
        case 'fill':
          canvas.drawPath(path, fill);
          break;
        case 'stroke':
          canvas.drawPath(path, stroke);
          break;
      }
    }
  }

  @override
  bool shouldRepaint(NativeCanvasPainter old) => true;
}

class NativeGrid extends MultiChildRenderObjectWidget {
  final List<double> columns;
  final double gap;
  final String align;
  final List<bool> autoHeights;
  const NativeGrid(
      {super.key,
      required this.columns,
      required this.gap,
      required this.align,
      required this.autoHeights,
      required super.children});
  @override
  RenderNativeGrid createRenderObject(BuildContext context) =>
      RenderNativeGrid(columns, gap, align, autoHeights);
  @override
  void updateRenderObject(BuildContext context, RenderNativeGrid render) {
    render.columns = columns;
    render.gap = gap;
    render.align = align;
    render.autoHeights = autoHeights;
    render.markNeedsLayout();
  }
}

class NativeParentData extends ContainerBoxParentData<RenderBox> {}

class RenderNativeGrid extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, NativeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, NativeParentData> {
  List<double> columns;
  double gap;
  String align;
  List<bool> autoHeights;
  RenderNativeGrid(this.columns, this.gap, this.align, this.autoHeights);
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! NativeParentData)
      child.parentData = NativeParentData();
  }

  @override
  void performLayout() {
    var child = firstChild;
    var y = 0.0;
    var rowStart = 0;
    final count = math.max(1, columns.length);
    while (child != null) {
      final row = <RenderBox>[];
      var rowHeight = 0.0;
      for (var i = 0; i < count && child != null; i++) {
        child.layout(BoxConstraints(maxWidth: columns[i], minWidth: columns[i]),
            parentUsesSize: true);
        rowHeight = math.max(rowHeight, child.size.height);
        row.add(child);
        child = (child.parentData! as NativeParentData).nextSibling;
      }
      var x = 0.0;
      for (var i = 0; i < row.length; i++) {
        final item = row[i];
        if (align == 'stretch' &&
            autoHeights[rowStart + i] &&
            item.size.height < rowHeight) {
          item.layout(
              BoxConstraints.tightFor(width: columns[i], height: rowHeight),
              parentUsesSize: true);
        }
        final remaining = rowHeight - item.size.height;
        final offset = align == 'center'
            ? remaining / 2
            : align == 'end'
                ? remaining
                : 0.0;
        (item.parentData! as NativeParentData).offset = Offset(x, y + offset);
        x += columns[i] + gap;
      }
      rowStart += row.length;
      y += rowHeight + (child != null ? gap : 0);
    }
    size = constraints.constrain(
        Size(columns.fold<double>(0, (a, b) => a + b) + gap * (count - 1), y));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

class NativeFlex extends MultiChildRenderObjectWidget {
  final double gap;
  final String justify, align;
  const NativeFlex(
      {super.key,
      required this.gap,
      required this.justify,
      required this.align,
      required super.children});
  @override
  RenderNativeFlex createRenderObject(BuildContext context) =>
      RenderNativeFlex(gap, justify, align);
  @override
  void updateRenderObject(BuildContext context, RenderNativeFlex render) {
    render.gap = gap;
    render.justify = justify;
    render.align = align;
    render.markNeedsLayout();
  }
}

class RenderNativeFlex extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, NativeParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, NativeParentData> {
  double gap;
  String justify, align;
  RenderNativeFlex(this.gap, this.justify, this.align);
  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! NativeParentData)
      child.parentData = NativeParentData();
  }

  @override
  void performLayout() {
    final children = <RenderBox>[];
    var child = firstChild;
    var sum = 0.0, height = 0.0;
    while (child != null) {
      child.layout(BoxConstraints(maxWidth: constraints.maxWidth),
          parentUsesSize: true);
      children.add(child);
      sum += child.size.width;
      child = (child.parentData! as NativeParentData).nextSibling;
    }
    final gaps = gap * math.max(0, children.length - 1);
    final limit =
        constraints.maxWidth.isFinite ? constraints.maxWidth : sum + gaps;
    if (sum + gaps > limit && sum > 0) {
      for (final c in children) {
        c.layout(
            BoxConstraints(
                maxWidth: math.max(0, (limit - gaps) * c.size.width / sum)),
            parentUsesSize: true);
      }
    }
    sum = children.fold<double>(0, (n, c) => n + c.size.width);
    for (final c in children) {
      height = math.max(height, c.size.height);
    }
    final available = math.max(0.0, limit - sum - gaps);
    var x = justify == 'center'
        ? available / 2
        : justify == 'end' || justify == 'flex-end'
            ? available
            : 0.0;
    final spacing = justify == 'space-between' && children.length > 1
        ? gap + available / (children.length - 1)
        : gap;
    for (final c in children) {
      (c.parentData! as NativeParentData).offset = Offset(
          x,
          align == 'center'
              ? (height - c.size.height) / 2
              : align == 'end'
                  ? height - c.size.height
                  : 0);
      x += c.size.width + spacing;
    }
    size = constraints.constrain(Size(
        justify == 'space-between' ? limit : math.min(limit, sum + gaps),
        height));
  }

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
