import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/ui_bridge.dart';
import 'package:htgc_portfolio/htgc_handlers.dart' as handlers;

void main() {
  testWidgets('HTML disclosure and templates, author cascade and JavaScript',
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
    final state = key.currentState!;
    final first = state.document.querySelector('#first')!;
    final second = state.document.querySelector('#second')!;
    final fallback = state.document.querySelector('#fallback')!;
    final toggles = state.document.querySelector('#toggles')!;
    final firstSummary = find.text('▸ 最初の項目', findRichText: true);
    final firstBody = find.text('最初の本文', findRichText: true);
    final secondBody = find.text('次の本文', findRichText: true);

    final rule = state.css.get(state.document.querySelector('#rule-wins')!);
    expect(rule['color'], 'blue');
    expect(rule['padding-left'], '9px');
    expect(state.css.get(state.document.querySelector('#inline-wins')!)['color'],
        'red');
    expect(state.document.querySelector('#exception')!.text,
        '捕捉・終了・束縛なし・既定・次へ');
    final layer = state.css.get(state.document.querySelector('#layer-test')!);
    expect(layer['color'], 'blue');
    expect(layer['padding-left'], '2px');
    expect(layer['padding-right'], '10px');
    final moduleLog = state.document.querySelector('#module-log')!;
    expect(moduleLog.text, '1:2:2:2');
    expect(moduleLog.attributes['data-runs'], '1');
    final host = state.document.querySelector('#template-result')!;
    expect(host.attributes['data-inert'], 'true');
    expect(host.attributes['data-nested'], '入れ子');
    expect(host.querySelector('#template-content')!.text, 'テンプレートの本文');
    expect(state.document.querySelectorAll('#template-content'), hasLength(1));

    expect(firstBody, findsNothing);
    expect(secondBody, findsNothing);
    await tester.ensureVisible(firstSummary);
    await tester.tap(firstSummary);
    await tester.pumpAndSettle();
    expect(first.attributes.containsKey('open'), isTrue);
    expect(firstBody, findsOneWidget);
    expect(toggles.text, 'closed:open;');

    state.runtime.wrap(first.children.last).dispatch('click');
    expect(first.attributes.containsKey('open'), isTrue);
    state.runtime.wrap(second).set('open', true);
    await tester.pumpAndSettle();
    expect(firstBody, findsNothing);
    expect(secondBody, findsOneWidget);
    expect(state.runtime.wrap(second).get('open'), isTrue);
    expect(toggles.text, 'closed:open;open:closed;');

    state.runtime.wrap(first).set('open', true);
    state.runtime.wrap(first).set('open', false);
    expect(toggles.text, 'closed:open;open:closed;');
    await tester.pumpAndSettle();
    expect(toggles.text, 'closed:open;open:closed;closed:closed;');

    final defaultSummary = find.text('Details');
    await tester.ensureVisible(defaultSummary);
    await tester.tap(defaultSummary);
    await tester.pumpAndSettle();
    expect(fallback.attributes.containsKey('open'), isTrue);
    expect(find.text('既定の見出しの本文', findRichText: true), findsOneWidget);

    state.runtime.wrap(second).set('open', true);
    state.runtime.wrap(fallback).set('name', 'options');
    await tester.pumpAndSettle();
    expect(fallback.attributes.containsKey('open'), isFalse);
    expect(second.attributes.containsKey('open'), isTrue);
    expect(tester.takeException(), isNull);
  });

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
