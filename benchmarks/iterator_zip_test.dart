import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/iterator_zip.dart';

void main() {
  testWidgets('zip, zipKeyed and async iterator disposal update native UI', (
    tester,
  ) async {
    await tester.pumpWidget(
      NativeSiteApp(
        entry: htgcSiteData['entry'],
        pages: Map<String, dynamic>.from(htgcSiteData['pages']),
        assets: Set<String>.from(htgcSiteData['assets']),
        assetDirectory: Directory('lib/$htgcAssetDirectory'),
        scripts: htgcScripts,
        storage: {},
        pageHandlers: htgcHandlers,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('[[1,"a"],[2,"-"]] [{"left":1,"right":2}]', findRichText: true),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
