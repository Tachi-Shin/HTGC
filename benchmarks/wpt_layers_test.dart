import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/wpt_layers.dart';

void main() {
  testWidgets('WPT layer-basic styling cases', (tester) async {
    final pages = Map<String, dynamic>.from(htgcSiteData['pages']);
    expect(pages.length, 35);
    final key = GlobalKey<NativeSiteState>();
    await tester.pumpWidget(NativeSiteApp(
      key: key,
      entry: htgcSiteData['entry'],
      pages: pages,
      assets: const {},
      assetDirectory: Directory('.'),
      scripts: htgcScripts,
      storage: {},
    ));
    final state = key.currentState!;
    for (final page in pages.keys.where((path) => path != htgcSiteData['entry'])) {
      state.navigate(page);
      await tester.pumpAndSettle();
      final targets = state.document.querySelectorAll('target');
      expect(targets.length, 2, reason: page);
      for (final target in targets) {
        expect(cssColor(state.css.get(target)['color']), const Color(0xff008000),
            reason: '$page ${target.className}');
      }
    }
  });
}
