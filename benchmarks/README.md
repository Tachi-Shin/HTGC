# ポートフォリオのC・Dart変換ベンチマーク

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

## Test262 の例外処理テスト

HTGCのルートから実行します。Python 3.10以上、Node.js/npm、Dart SDKが必要です。

```sh
npm --prefix javascript ci
git clone https://github.com/tc39/test262.git ../test262
git -C ../test262 checkout --detach 2e58f87d8350ad51224617a041c6e041d52f8444
python3 benchmarks/test262_dart.py ../test262
```

Test262の `test/language/statements/try/` から同期スクリプト6件を選び、HTGCで生成したDartを実行します。ハーネスは選定ケースで使う `Test262Error` を提供します。モジュール、非同期テスト、構文エラーを期待するテスト、strict/sloppyの両モードでの実行は対象外です。いずれかのケースが変換または実行に失敗した場合は終了コード1を返します。

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

拡張変換はこのベンチマークが使う構文とDOM操作を対象に実装しています。CSSボックスの細部、フォントと改行、フォーカス表示、フィルター、アニメーションにはブラウザとの差があります。JavaScriptのモジュール間のimport/export、async/generator、インラインイベント属性、任意のブラウザAPIは未対応です。

元サイトの粒子描画は、初期化を試みる時点で関数がまだ定義されていないため自動開始しません。Contactの送信には元サイトと同じく別途受信サービスが必要です。テストはフォームの検証まで行います。

## C11 / GTK 4のビルド

HTGCのルートで実行します。上記のPython・npm依存に加え、Cコンパイラ、GTK 4とlibxml2の開発パッケージ、`pkg-config` が必要です。

```sh
python3 HTGC -Gtk ../portfolio-site/index.html --include contact.html -o ../portfolio.gtk.c
cc -std=c11 -Wall -Wextra -Werror ../portfolio.gtk.c -o ../portfolio-gtk \
  $(pkg-config --cflags --libs gtk4 libxml-2.0) -lm
../portfolio-gtk index.html dark
```

Linux x64のGTK 4.18.6で4ページの起動を確認しました。C版には、CSSの疑似要素、フィルター、タイポグラフィ、位置指定などに未対応・近似の箇所があります。Canvas、ResizeObserverの通知、requestAnimationFrameの実行、プロセスをまたぐテーマ保持は未対応です。IUP版の拡張変換も未実装です。

## 元サイトとの照合

Chromiumは比較用の基準画像とDOMの取得に使います。HTGCの変換と生成アプリの動作には不要です。

```sh
npm install --prefix benchmarks --no-save --package-lock=false playwright@1.62.1
npm exec --prefix benchmarks -- playwright install chromium --only-shell
node benchmarks/reference.cjs ../portfolio-site ../portfolio-reference
python3 benchmarks/check_c_dom.py ../portfolio-site ../portfolio-reference/reference.json
```

Linux x64で、Chromium 150.0.7871.181の基準と、Cが生成した全4ページのナビゲーションとフッター、ニュース9件、タイムライン119件のテキストを照合しました。テーマ切替はC側でdark → auto → light → darkを確認しました。

画素比較では、両アプリのクライアント領域を1280×720、DPR 1、ダークテーマに設定します。Flutterは `--reduced-motion` を渡し、GTK 4は設定の `gtk-enable-animations` を無効にして、アニメーションを止めます。Pillowをインストールしてから、同条件で撮ったPNGを比較します。

```sh
python3 benchmarks/compare_visual.py ../portfolio-reference/index.png ../actual/index.png \
  --diff ../index-diff.png
```

既定ではRGBが1画素でも異なると終了コード1を返します。平均RGB誤差は各色成分の絶対差を0〜255の値で平均したものです。

| ページ | Dart 平均RGB誤差 | C / GTK 4 平均RGB誤差 |
| --- | ---: | ---: |
| Home | 3.16 | 6.51 |
| Projects | 13.13 | 19.48 |
| About | 8.64 | 9.85 |
| Contact | 9.01 | 13.17 |

この条件では4ページすべてで画素差があります。完全一致の判定は全画素の差がゼロになった時点です。
