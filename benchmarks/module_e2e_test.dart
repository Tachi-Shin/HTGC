import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/module_e2e.dart';

void main() {
  testWidgets(
    'JSON module, async disposal and Unicode normalization update the UI',
    (tester) async {
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
      expect(find.text('é:3', findRichText: true), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
