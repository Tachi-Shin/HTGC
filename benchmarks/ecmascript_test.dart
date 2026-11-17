import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/ecmascript.dart';

void main() {
  testWidgets(
    'compiled generators, Proxy, binary data, Date and RegExp update UI',
    (tester) async {
      final key = GlobalKey<NativeSiteState>();
      await tester.pumpWidget(
        NativeSiteApp(
          key: key,
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
      expect(find.text('待機中', findRichText: true), findsOneWidget);
      await tester.tap(find.text('集計する', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('完了', findRichText: true), findsOneWidget);
      expect(
        find.text('合計 640 / 64,128,192,256', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.text('2026-11-16T00:00:00.000Z', findRichText: true),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
