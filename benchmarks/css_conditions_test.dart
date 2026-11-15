import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' show parse;
import 'package:htgc_portfolio/ui_bridge.dart';

void main() {
  test('conditional layers follow the active document conditions', () {
    final document = parse('''<!doctype html><html><body>
      <p id="conditional-layer"></p><p id="conditional-body"></p>
      <p id="conditional-import"></p><p id="conditional-supports"></p>
      <p id="conditional-media"></p><p id="conditional-motion"></p>
      <p id="conditional-theme"></p>
    </body></html>''');
    final runtime = JDomRuntime(document);
    final rules = List<dynamic>.from(
      htgcSiteData['pages']['index.html']['styles'],
    );
    for (final width in [320.0, 800.0, 1000.0, 320.0]) {
      runtime.viewportWidth = width;
      runtime.viewportHeight = 600;
      runtime.dark = false;
      runtime.reducedMotion = false;
      final css = NativeCss(runtime, rules);
      String? value(String id, String property) =>
          css.get(document.getElementById(id)!)[property];
      expect(
        value('conditional-layer', 'color'),
        width >= 600 ? 'red' : 'green',
      );
      expect(
        value('conditional-body', 'opacity'),
        width >= 600 ? '0.5' : isNull,
      );
      expect(
        value('conditional-import', 'opacity'),
        width >= 600 ? '0.4' : isNull,
      );
      expect(value('conditional-supports', 'color'), 'green');
      expect(
        value('conditional-media', 'opacity'),
        width >= 400 && width < 900 ? '0.7' : isNull,
      );
      expect(value('conditional-motion', 'opacity'), '0.8');
      expect(value('conditional-theme', 'color'), 'black');
      expect(css.media('not print'), isTrue);
      expect(css.media('only screen'), isTrue);
      expect(css.media('(unknown-feature: yes)'), isFalse);
      expect(css.media('print, screen and (min-width: 20em)'), isTrue);
      expect(css.media('(height = 600px)'), isTrue);
      expect(css.media('(orientation: landscape)'), width > 600);
      expect(css.supports('(display: flex) or (display: unknown)'), isTrue);
      expect(css.supports('not (display: unknown)'), isTrue);
    }
    runtime.dark = true;
    runtime.reducedMotion = true;
    final css = NativeCss(runtime, rules);
    expect(
      css.get(document.getElementById('conditional-theme')!)['color'],
      'white',
    );
    expect(
      css.get(document.getElementById('conditional-motion')!)['opacity'],
      '0.2',
    );
  });
}
