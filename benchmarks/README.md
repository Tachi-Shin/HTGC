# Dart変換とECMAScriptのベンチマーク

## DartとHTMLのイベント連携

HTGCリポジトリのルートから実行します。`../portfolio-app` は下記の手順で依存パッケージを追加したFlutterプロジェクトです。

```sh
python3 HTGC -Dart benchmarks/ui_bridge/index.html -o ../portfolio-app/lib/ui_bridge.dart
cp benchmarks/ui_bridge/htgc_handlers.dart ../portfolio-app/lib/
cp benchmarks/ui_bridge_test.dart ../portfolio-app/test/
cd ../portfolio-app
flutter test test/ui_bridge_test.dart
```

このテストは、文字入力がDartへ渡り、非同期処理の結果が入力欄とダイアログに反映されることを確認します。元のページを離れた後に、古いハンドラーから別ページを書き換えられないことも検証します。

同じテストで、`details` の排他的な開閉、スタイルシートとインライン宣言の `!important`、例外の捕捉、`switch` のフォールスルーも検証します。

標準機能のケースでは、`template.content` が挿入前のDOM検索から除外されること、入れ子を含めて複製できること、`@layer` と `!important` の優先順位、静的モジュールの循環参照、エクスポート値の更新と二重評価の防止も確認します。

## WPTのカスケードレイヤー試験

HTGCのルートから実行します。`../portfolio-app` は上記と同じFlutterプロジェクトです。

```sh
curl -fL https://raw.githubusercontent.com/web-platform-tests/wpt/5e0f80519f244367a7a5dea3f0ea3f712cf8a124/css/css-cascade/layer-basic.html -o ../layer-basic.html
python3 benchmarks/wpt_layers.py ../layer-basic.html ../portfolio-app/lib/wpt_layers.dart
cp benchmarks/wpt_layers_test.dart ../portfolio-app/test/
cd ../portfolio-app
flutter test test/wpt_layers_test.dart
```

WPTの `layer-basic.html` からスタイル34件を取り出し、生成したFlutterアプリで各ケースの2要素の計算色が緑になることを確認します。WPTのブラウザ用ハーネスと動的にスタイルを挿入する処理は、同じ宣言を持つ生成ページとFlutterのアサーションに置き換えています。

## Test262 の例外処理・非同期・組み込みテスト

HTGCのルートから実行します。Python 3.10以上、Node.js/npm、Dart SDKが必要です。

```sh
npm --prefix javascript ci
git clone https://github.com/tc39/test262.git ../test262
git -C ../test262 checkout --detach 2e58f87d8350ad51224617a041c6e041d52f8444
python3 benchmarks/test262_dart.py ../test262
```

Test262の `test/language/statements/try/` から同期スクリプト6件、`test/language/expressions/await/` から非同期スクリプト8件、Map.prototype.getから8件、Object.definePropertiesから7件、BigIntから71件の100件に、Proxy.get 18件、GeneratorPrototype 59件、Date.toISOString 17件、RegExp.exec 13件、ArrayBuffer.resize 10件を追加し、さらにAtomics.waitAsync 20件、SharedArrayBuffer.grow 14件、RegExpのUnicode集合9件を加えた260件に、Math.sumPrecise 10件、Uint8Array.fromBase64 13件、JSON.rawJSON 10件を追加した293件に、Iteratorとリソース管理の96件、zip・zipKeyed・includes・joinの131件、宣言とループの束縛21件を加えた計541件を、元のテストソースを変更せずHTGCでDartへ変換して実行します。選定ファイルは `test262_dart.py` と `test262_extended.txt` に列挙しています。

BigIntの試験では、2〜36進数の文字列化、整数変換と構文エラー、`asIntN/asUintN` の算術・型変換・副作用の順序、プロトタイプと関数の記述子、呼び出し時の例外を検証します。BigIntの全試験ではなく、複数Realm、Functionの継承、スクリプトのグローバル `this`、Dateと組み合わせた変換などは対象外です。

ハーネスは選定ケースで必要な `Test262Error`、`assert`、`assert.sameValue/notSameValue`、`assert.compareArray`、`assert.throws`、`assert.throwsAsync`、`verifyProperty`、`isConstructor`、`asyncTest`、`$DONE` をDartで提供します。`verifyProperty` はプロパティ記述子を比較し、`isConstructor` は生成ランタイムの構築可能フラグを調べます。Test262のpropertyHelper全体やProxy/Reflect.constructを使うisConstructor.js自体の実行ではありません。Unicode集合の生成テストにはDartでtestExtendedCharacterClassを提供し、各入力のマッチ可否を検証します。非同期完了は5秒でタイムアウトします。モジュール形式のTest262、構文エラーを期待するテスト、strict/sloppyの両モードでの実行は対象外。runtime phaseのnegativeテストは想定される例外名を検証です。いずれかのケースが変換または実行に失敗した場合は終了コード1を返します。

## 非同期実行と条件付きCSSの回帰試験

```sh
python3 benchmarks/js_async_dart.py --dart /path/to/dart
python3 HTGC -Dart benchmarks/ui_bridge/index.html -o ../portfolio-app/lib/ui_bridge.dart
cp benchmarks/ui_bridge/htgc_handlers.dart ../portfolio-app/lib/
cp benchmarks/ui_bridge_test.dart benchmarks/css_conditions_test.dart ../portfolio-app/test/
cd ../portfolio-app
flutter test test/ui_bridge_test.dart test/css_conditions_test.dart
```

`js_async_dart.py` は22組のローカルフィクスチャをDartとNode.jsで実行し、終了状態と標準出力を比較します。Promiseの処理順序、thenableの多重呼び出し、getterの例外、`finally`、Promiseの合成、短絡評価、トップレベル `await` を含む循環・共有依存、動的インポートの評価回数と失敗の保持を確認します。Symbol・記述子・継承・列挙の副作用、Map/Setの反復中の変更、WeakMap/WeakSet、イテレーターの後始末、分割代入、JSONの190アサーションに加え、数値系の266アサーションを含みます。数値系ではBigInt、Numberの丸め・符号付きゼロ・NaN・比較・シフト、数値文字列の解析と整形、Math、ユーザー定義コンストラクターを検証します。ジェネレーター129、Proxy42、バイナリデータ68、Date63、RegExp70の計372アサーションを追加し、さらにAtomics、派生型・Species、RegExpのUnicode集合の試験を実行します。Node.jsは比較用で、生成アプリには使いません。`Promise.try`、`Promise.withResolvers`、Float16Array、RegExp.escape、RegExpのvフラグとAtomics.pauseに加え、Base64変換とMapのgetOrInsertに対応したNode.jsが必要です（26.13.1で検証）。

Flutterテストでは、トップレベル `await` の完了後と非同期クリック処理後に表示が更新されることも確認します。CSSテストは幅320・800・1000pxとテーマ・動きの設定を切り替えて、条件付きレイヤー順序とインポート、メディア範囲比較、`@supports` を検証します。

これらは選定したケースの回帰試験です。WPT全体・Test262全体の通過や、ブラウザとの完全な描画一致を示すものではありません。

## ジェネレーターと組み込みオブジェクトの検証

```sh
# 全フィクスチャをDartのAOT実行ファイルにしてNode.jsと比較
python3 benchmarks/js_async_dart.py --aot
# 不具合調査時には機能を限定できる
python3 benchmarks/js_async_dart.py --filter generators.js
python3 benchmarks/test262_dart.py ../test262 --filter '*GeneratorPrototype*'

# 同じ機能をHTMLからコンパイルし、Flutter画面への反映を確認
python3 HTGC benchmarks/ecmascript/index.html -o ../portfolio-app/lib/ecmascript.dart
cp benchmarks/ecmascript_test.dart ../portfolio-app/test/
cd ../portfolio-app
flutter test test/ecmascript_test.dart
```

追加したケースは、next/throw/returnとfinally、yield*、for await、非同期returnの拒否、Proxyの不変条件・失効・newTarget、バッファ共有・リサイズ・転送、整数変換・Float16の丸め、日時の境界・getter/setter、正規表現のlastIndex・Unicode・キャプチャ位置・置換を検証します。

Dart JITとLinux x64のAOTで18組の比較試験を通過しました。Flutterの7テストには、ポートフォリオ、UI連携、条件付きCSS、WPT由来のレイヤー試験、埋め込み文書、および上記の組み込み機能を使った画面更新が含まれます。macOS実機・Windows実機・PyInstallerの配布ビルドはこの変更では再検証していません。

## Dart専用CLIの検証

```sh
python3 benchmarks/dart_cli.py
```

出力形式の省略時にDartが生成されること、従来の `-Dart` との一致、廃止した `-Gtk/-Clang` の拒否、任意のDartハンドラー呼び出し、BigIntを使う入力の変換、外部画像のコピー、入力ファイルの上書き防止を確認します。

## ローカル埋め込み文書の検証

```sh
python3 benchmarks/embedded_inputs.py
python3 HTGC -Dart benchmarks/embedded_docs/index.html -o ../portfolio-app/lib/embedded_docs.dart
cp benchmarks/embedded_docs_test.dart ../portfolio-app/test/
cd ../portfolio-app
flutter test test/embedded_docs_test.dart
```

変換時の検証では、参照文書とそのCSS/JS・画像だけの収録、`srcdoc` の優先、相対参照の基準、未対応ポリシーの診断を確認します。Flutter上では親子のDOMとCSSの分離、埋め込み寸法とメディア条件、親から子への更新、子だけの遷移、循環参照の停止、objectの代替内容を確認します。元のHTMLを読み込めないディレクトリを実行時の画像ディレクトリに指定しています。

## ポートフォリオのFlutterビルド

対象は [Tachi-Shin/Tachi-Shin.github.io](https://github.com/Tachi-Shin/Tachi-Shin.github.io) のコミット `c264c62fa8ceddac553cfd8e9873d2d659d524b4` です。

HTGCのルートで実行します。Python 3.10以上、Node.js/npm、Flutterと対象OSのFlutterデスクトップ開発環境を用意してください。Flutter 3.47.9 / Dart 3.13.7で検証しました。

```sh
python3 -m pip install -r requirements-native.txt
npm --prefix javascript ci
git clone https://github.com/Tachi-Shin/Tachi-Shin.github.io.git ../portfolio-site
git -C ../portfolio-site checkout c264c62fa8ceddac553cfd8e9873d2d659d524b4
flutter create --platforms=linux,macos,windows --project-name htgc_portfolio ../portfolio-app
python3 HTGC -Dart ../portfolio-site/index.html --include contact.html -o ../portfolio-app/lib/main.dart
cp benchmarks/portfolio_test.dart ../portfolio-app/test/portfolio_test.dart
cd ../portfolio-app
flutter pub add html:0.15.6 flutter_svg:2.2.1 url_launcher:6.3.2 shared_preferences:2.5.3
flutter test test/portfolio_test.dart
```

Linux x64でリリース版をビルドして起動します。

```sh
flutter build linux --release
cp -R lib/main.dart.assets build/linux/x64/release/bundle/
./build/linux/x64/release/bundle/htgc_portfolio
```

Contactは元サイトのナビゲーションにリンクがありません。個別ページを入口として起動するには、実行ファイルの最初の引数にルートからの相対パスを指定します。

```sh
./build/linux/x64/release/bundle/htgc_portfolio contact.html
```

Apple Silicon Macでは `flutter build macos --release` でビルドし、`lib/main.dart.assets/` を `build/macos/Build/Products/Release/htgc_portfolio.app/Contents/MacOS/` にコピーしてから、`open build/macos/Build/Products/Release/htgc_portfolio.app` で起動します。配布用の署名は画像をコピーしてから行います。macOSとWindowsの実行確認は未実施です。

| 確認項目 | 結果 |
| --- | --- |
| HTML / CSS / JavaScriptからDart生成 | 4ページ、3本のJavaScript、6個の画像ファイルを変換・収録 |
| Linux x64のFlutterリリースビルド | 完成した実行ファイルを起動して表示を確認 |
| Home | 画像12枚、ニュース9件、画像列のアニメーション |
| Projects / About | 制作物5件、タイムライン119件、メーター5個 |
| ページ移動 | ページ間リンクと `#web` のスクロール |
| テーマ切替 | ライトとダークへの切替、移動後の状態保持 |
| Contact | 3つの入力欄と必須・メール形式の検証 |
| レイアウト | 画像帯の高さ、ヒーロー中央揃え、Gridの列、幅390pxの表示 |

CSSボックスの細部、フォントと改行、フォーカス表示、フィルター、アニメーションにはブラウザとの差があります。JavaScriptの完全なジェネレーター互換性、Promiseのサブクラスや多くのブラウザAPIには未実装の範囲があります。

元サイトの粒子描画は、初期化を試みる時点で関数がまだ定義されていないため自動開始しません。Contactの送信には元サイトと同じく別途受信サービスが必要です。テストはフォームの検証まで行います。

## 元サイトとの照合

Chromiumは比較用の基準画像とDOMの取得に使います。HTGCの変換と生成アプリの動作には不要です。

```sh
npm install --prefix benchmarks --no-save --package-lock=false playwright@1.62.1
npm exec --prefix benchmarks -- playwright install chromium --only-shell
node benchmarks/reference.cjs ../portfolio-site ../portfolio-reference
```

画素比較では、ブラウザとFlutterのクライアント領域を1280×720、DPR 1、ダークテーマに設定します。Flutterは `--reduced-motion` を渡してアニメーションを止めます。Pillowをインストールしてから、同条件で撮ったPNGを比較します。

```sh
python3 benchmarks/compare_visual.py ../portfolio-reference/index.png ../actual/index.png \
  --diff ../index-diff.png
```

既定ではRGBが1画素でも異なると終了コード1を返します。平均RGB誤差は各色成分の絶対差を0〜255の値で平均したものです。

| ページ | Dart 平均RGB誤差 |
| --- | ---: |
| Home | 3.16 |
| Projects | 13.13 |
| About | 8.64 |
| Contact | 9.01 |

この条件では4ページすべてで画素差があります。完全一致の判定は全画素の差がゼロになった時点です。

### Unicode正規化とJSONモジュール

Unicode 17.0.0の `NormalizationTest.txt` を用意して、正規化4形式を公式データの全行で検証します。

```sh
dart benchmarks/normalization.dart /path/to/NormalizationTest.txt
```

`benchmarks/module_e2e/` をHTGCで `lib/module_e2e.dart` に変換し、`benchmarks/module_e2e_test.dart` をFlutterプロジェクトの `test/` に配置して実行すると、JSON importと非同期解放を含むスクリプトの画面更新を確認できます。

`benchmarks/iterator_zip/` のHTMLを `lib/iterator_zip.dart` に変換し、`benchmarks/iterator_zip_test.dart` をFlutterプロジェクトの `test/` に配置して実行すると、zip・zipKeyedと非同期イテレーターの後始末を確認できます。
