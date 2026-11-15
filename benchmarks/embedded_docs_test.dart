import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:htgc_portfolio/embedded_docs.dart';

void main() {
  testWidgets(
    'compiled embedded documents isolate state and navigate locally',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey<NativeSiteState>();
      await tester.pumpWidget(
        NativeSiteApp(
          key: key,
          entry: htgcSiteData['entry'],
          pages: Map<String, dynamic>.from(htgcSiteData['pages']),
          assets: Set<String>.from(htgcSiteData['assets']),
          assetDirectory: Directory('not-an-html-input-directory'),
          scripts: htgcScripts,
          storage: {},
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final state = key.currentState!;
      final child = state.document.getElementById('child')!;
      final inline = state.document.getElementById('inline')!;
      final childRuntime = state.runtime.embeddedDocuments[child]!;
      expect(state.document.getElementById('status')!.text, '文書接続OK');
      expect(
        childRuntime.document.getElementById('message')!.text,
        '子で実行済み・親から更新',
      );
      expect(state.document.getElementById('message'), isNull);
      expect(childRuntime.viewportWidth, 320);
      expect(childRuntime.viewportHeight, 180);
      final childState = tester
          .stateList<NativeSiteState>(find.byType(NativeSiteApp))
          .firstWhere((s) => identical(s.runtime, childRuntime));
      expect(
        tester.getSize(find.byWidget(childState.widget)),
        const Size(320, 180),
      );
      expect(
        childState.css.get(
          childRuntime.document.getElementById('message')!,
        )['color'],
        'blue',
      );
      expect(
        childState.css.get(
          childRuntime.document.getElementById('message')!,
        )['font-size'],
        '20.0px',
      );
      expect(
        state.css.get(state.document.getElementById('status')!)['color'],
        'green',
      );
      expect(
        state.runtime.embeddedDocuments[inline]!.document
            .getElementById('message')!
            .text,
        'srcdocの本文',
      );
      expect(
        state
            .runtime
            .embeddedDocuments[state.document.getElementById('loop')]!
            .document
            .body!
            .text,
        '',
      );
      expect(find.text('オブジェクト代替内容', findRichText: true), findsOneWidget);
      expect(find.text('代替内容', findRichText: true), findsNothing);
      expect(state.runtime.embeddedDocuments, hasLength(5));
      childRuntime
          .wrap(childRuntime.document.getElementById('next')!)
          .dispatch('click');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(state.current, 'index.html');
      expect(
        state.runtime.embeddedDocuments[child]!.document
            .getElementById('message')!
            .text,
        '次の文書・親から更新',
      );
      final inlineRuntime = state.runtime.embeddedDocuments[inline]!;
      inlineRuntime
          .wrap(inlineRuntime.document.querySelector('a')!)
          .dispatch('click');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        state.runtime.embeddedDocuments[inline]!.document
            .getElementById('message')!
            .text,
        '次の文書',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
