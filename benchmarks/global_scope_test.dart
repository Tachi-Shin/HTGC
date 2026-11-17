import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/global_scope.dart';

void main() {
  testWidgets('classic scripts share global bindings and the window object', (
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
    expect(find.text('17:true:9:undefined:true', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
