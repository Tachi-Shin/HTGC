import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/main.dart';

void main() {
  testWidgets('portfolio compiles to interactive native widgets',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<NativeSiteState>();
    final storage = <String, String>{};
    final external = <Uri>[];
    await tester.pumpWidget(NativeSiteApp(
      key: key,
      entry: htgcSiteData['entry'],
      pages: Map<String, dynamic>.from(htgcSiteData['pages']),
      assets: Map<String, dynamic>.from(htgcSiteData['assets']),
      scripts: htgcScripts,
      storage: storage,
      externalLink: external.add,
    ));
    final state = key.currentState!;
    Future<void> render() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }

    Finder element(String selector) {
      final node = state.document.querySelector(selector);
      expect(node, isNotNull, reason: selector);
      return find.byKey(state.nodeKeys[node]!);
    }

    await render();
    expect(state.current, 'index.html');
    expect(state.document.querySelectorAll('#news-list li'), hasLength(9));
    expect(find.byType(Image), findsNWidgets(12));
    final hero = tester.getRect(element('.hero'));
    expect(tester.getRect(element('.hero__inner')).center.dx,
        closeTo(hero.center.dx, 1));
    expect(tester.getSize(element('.bg-band--top')).height,
        closeTo(hero.height * .38, 1));
    expect(tester.getSize(element('.affiliation .qcard')).width,
        greaterThan(tester.getSize(element('.affiliation')).width * .9));
    final track = find.descendant(
        of: element('.bg-track--left'),
        matching: find.byType(FractionalTranslation));
    final previous = tester.widget<FractionalTranslation>(track).translation;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<FractionalTranslation>(track).translation,
        isNot(previous));
    expect(state.document.querySelector('.hero__inner')!.classes,
        contains('is-visible'));
    expect(storage['theme'], 'auto');
    await tester.tap(element('#themeToggle'));
    await render();
    expect(storage['theme'], 'light');
    await tester.tap(element('#themeToggle'));
    await render();
    expect(storage['theme'], 'dark');
    await tester.tap(element('.hero__cta a[href="projects.html"]'));
    await render();
    expect(state.current, 'projects.html');
    expect(state.document.querySelectorAll('article.card'), hasLength(5));
    expect(state.document.documentElement!.attributes['data-theme'], 'dark');
    await tester.tap(element('.nav__links a[href="about.html"]'));
    await render();
    expect(state.current, 'about.html');
    expect(
        state.document.querySelectorAll('#timeline .tl-item'), hasLength(119));
    expect(find.byType(LinearProgressIndicator), findsNWidgets(5));
    await tester.tap(element('.nav__links a[href="index.html"]'));
    await render();
    expect(state.current, 'index.html');
    tester.view.physicalSize = const Size(1200, 450);
    await render();
    final fragmentLink = element('a[href="projects.html#web"]');
    await tester.ensureVisible(fragmentLink);
    await render();
    await tester.tap(fragmentLink);
    await render();
    expect(state.current, 'projects.html');
    expect(state.scroll.offset, greaterThan(0));
    // Contact is present in the original site but has no incoming nav link.
    state.navigate('contact.html');
    await render();
    expect(find.byType(TextFormField), findsNWidgets(3));
    expect(state.formKey.currentState!.validate(), isFalse);
    await tester.enterText(find.byType(TextFormField).at(0), 'HTGC');
    await tester.enterText(
        find.byType(TextFormField).at(1), 'htgc@example.invalid');
    await tester.enterText(find.byType(TextFormField).at(2), 'テスト');
    expect(state.formKey.currentState!.validate(), isTrue);
    await render();
    tester.view.physicalSize = const Size(390, 844);
    await render();
    expect(tester.getSize(element('main')).width, lessThanOrEqualTo(390));
    expect(external, isEmpty);
  });
}
