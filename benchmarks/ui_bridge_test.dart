import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/ui_bridge.dart';
import 'package:htgc_portfolio/htgc_handlers.dart' as handlers;

void main() {
  testWidgets('HTML events update the rendered Flutter page', (tester) async {
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
    final state = key.currentState!;
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('待機中', findRichText: true), findsNothing);
    expect(find.text('1回実行', findRichText: true), findsOneWidget);
    expect(
      state.css.get(state.document.querySelector('article')!)['color'],
      '#24304a',
    );

    final memo = find.byType(TextFormField);
    await tester.enterText(memo, '日本語の本文');
    await tester.pumpAndSettle();
    expect(handlers.lastInput, '日本語の本文');
    expect(handlers.inputEvents, 1);

    await tester.tap(find.text('保存', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('保存中', findRichText: true), findsOneWidget);
    expect(tester.widget<TextFormField>(memo).enabled, isFalse);
    await tester.tap(find.text('保存', findRichText: true));
    expect(handlers.saveCalls, 1);

    handlers.saveCompleted.complete();
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('日本語の本文を保存', findRichText: true), findsOneWidget);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      '',
    );
    expect(handlers.inputEvents, 1);
    await tester.tap(find.text('閉じる', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(tester.widget<TextFormField>(memo).enabled, isTrue);

    state.navigate('next.html');
    await tester.pumpAndSettle();
    expect(handlers.previousPage!.active, isFalse);
    expect(handlers.previousPage!.setText('status', '古いページ'), isFalse);
    expect(find.text('次のページ', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
