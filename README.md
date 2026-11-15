# Hyper Text GUI Compiler (HTGC)

Dartのアプリ開発でGUI定義が面倒だったので自分用に作りました．
CのGUI定義ライブラリにも対応しています．

## 概要

HTMLとCSSで宣言した画面を、C11（IUP・GTK 4）またはDart（Flutter）のGUIソースに変換します。生成したアプリは対象のGUIライブラリで描画します。

## 使い方

CLIオプションの一覧は `python3 HTGC --help` で確認できます。

変換にはPython 3.10以上が必要です。下記の静的変換にはPythonの追加パッケージは不要です。macOS・Linuxでは、展開したディレクトリから実行します。

```sh
chmod +x HTGC
./HTGC -Clang example/main.html   # example/main.c
./HTGC -Gtk example/main.html     # example/main.gtk.c
./HTGC -Dart example/main.html    # example/main.dart
```

`HTGC` をPATHから起動できるようにすれば、`HTGC -Clang main.html` と呼び出せます。Windowsでは `py -3 HTGC -Clang example/main.html` と実行できます。 `-o` で出力先を指定できます。 `-Clang` はCを出力するためのオプション名です。

### C / IUP

IUPのヘッダーとライブラリを用意します。以下はコンパイラがヘッダーと共有ライブラリを検索できる環境での例です。別の場所に配置した場合は `-I` と `-L` を指定します。

```sh
cc -std=c11 example/main.c -o example/gui -liup
./example/gui
```

### C / GTK 4

GTK 4の開発パッケージと `pkg-config` を用意します。出力名はIUP版と並べて生成できるように `main.gtk.c` です。 `-o` で変更できます。

```sh
./HTGC -Gtk example/main.html
cc -std=c11 example/main.gtk.c -o example/gui-gtk $(pkg-config --cflags --libs gtk4)
./example/gui-gtk
```

生成コードは `GtkApplicationWindow`・`GtkBox`・`GtkLabel` を使います。HTML/CSSから得た色・余白・角丸・境界線などはGTK CSSに変換して埋め込むため、実行時に入力HTML/CSSを配布する必要はありません。

### Dart / Flutter

```sh
flutter create htgc_preview
./HTGC -Dart example/main.html -o htgc_preview/lib/main.dart
cd htgc_preview
flutter run
```

#### JITデバッグとホットリロード

Flutterのネイティブアプリをデバッグモードで起動すると、Dart VMがDartコードをJITコンパイルします。実行中のコードを差し替えるホットリロードでは、入力値や画面の状態が保持されます。プロファイルとリリースはAOTコンパイルを使います。[Flutterのビルドモード](https://docs.flutter.dev/testing/build-modes) · [ホットリロード](https://docs.flutter.dev/tools/hot-reload)

1. Flutterプロジェクトのルートで、入口HTMLを `lib/main.dart` に変換します。拡張変換の出力を使う場合は、最初に依存パッケージを追加します。

   ```sh
   flutter pub add html flutter_svg url_launcher shared_preferences
   HTGC -Dart path/to/index.html -o lib/main.dart
   ```

2. デバッグセッションを起動したままにします。macOSで画像を使う場合は、生成された画像フォルダを絶対パスで渡せます。`HTGC_ASSET_DIR` はデバッグモードでだけ参照されます。macOSの初回ビルドでターゲットの警告が出る場合は、次節の設定も確認してください。LinuxやWindowsで試す場合は `-d macos` を対象デバイスに変更します。

   ```sh
   flutter run -d macos --debug --dart-define="HTGC_ASSET_DIR=$PWD/lib/main.dart.assets"
   ```

3. 編集するファイルに応じて操作します。

   | 編集した箇所 | 実行中の `flutter run` での操作 |
   | --- | --- |
   | `lib/htgc_handlers.dart` の既存関数の本体 | 保存して小文字の `r` を押します。HTMLの再変換は不要です。 |
   | HTML・CSS・JS、イベント属性、画像 | 別の端末で上記の `HTGC -Dart … -o lib/main.dart` を再実行し、成功したら大文字の `R` を押します。 |
   | Dartのトップレベル変数の初期値や `main()` | 大文字の `R` を押します。 |
   | ネイティブのプラグインやXcodeの設定 | `q` で終了し、`flutter run` を再実行します。 |

拡張変換した画面データとイベントの対応表は、アプリの初期化時に読み込まれます。`R` のホットリスタートで初期化をやり直すため、編集途中の入力値などは初期状態に戻ります。プラグインやネイティブ設定を変更していない限り、毎回 `flutter build macos` を実行する必要はありません。HTML・CSS・JSの監視と再変換は、上記の手順では手動です。

#### macOSでビルドする場合

macOS向けのFlutterプロジェクトで、HTGCが生成したDartを `lib/main.dart` に配置します。拡張変換の出力を使う場合は、プロジェクトのルートで次の依存パッケージを追加します。

```sh
flutter pub add html flutter_svg url_launcher shared_preferences
```

Xcodeのビルドログにデプロイターゲット `10.15` がサポート範囲外で、下限が `12.0` と表示される場合は、次の設定を確認します。すでに `12.0` 以上の設定はその値を使います。

1. `macos/Runner.xcodeproj/project.pbxproj` の `MACOSX_DEPLOYMENT_TARGET = 10.15;` を `MACOSX_DEPLOYMENT_TARGET = 12.0;` に変更します。Debug・Profile・Releaseの各設定を確認してください。
2. CocoaPodsを使っていて `macos/Podfile` がある場合は、`platform :osx, '12.0'` を指定します。Pods個別にも `12.0` 未満の警告が出る場合は、既存の `post_install` を次の形に調整します。他の処理を追加している場合はその処理も残してください。

   ```ruby
   post_install do |installer|
     minimum = Gem::Version.new('12.0')
     installer.pods_project.targets.each do |target|
       flutter_additional_macos_build_settings(target)
       target.build_configurations.each do |config|
         version = config.build_settings['MACOSX_DEPLOYMENT_TARGET'].to_s
         if version.match?(/\A\d+(?:\.\d+)*\z/) && Gem::Version.new(version) < minimum
           config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = minimum.to_s
         end
       end
     end
   end
   ```

ホットリロードを使う場合は、前節の `flutter run` で起動します。

拡張変換で `lib/main.dart.assets/` が生成された場合は、ビルドした `.app` の `Contents/MacOS/` に画像ディレクトリをコピーしてから起動します。次はプロジェクト名が `htgc_preview` の例です。実際のアプリ名に置き換えてください。

```sh
flutter build macos --debug
app_bundle=build/macos/Build/Products/Debug/htgc_preview.app
ditto lib/main.dart.assets "$app_bundle/Contents/MacOS/main.dart.assets"
open "$app_bundle"
```

すでに `flutter run -d macos` で `.app` が生成されている場合は、画像のコピーと起動から実行できます。画像のパスで `PathNotFoundException` が出た場合は、エラーに表示された `.app` の位置と、コピー先を照合してください。

### HTMLのイベントからC・Dart関数を呼び出す

`-Gtk` と `-Dart` の拡張変換では、ボタンやリンクの `onclick` と、入力欄の `oninput` からアプリ側の関数を呼べます。

```html
<button type="button" onclick="openMessage('確認', 3, true)">ここをクリック</button>
<input type="text" oninput="saveDraft('title', text, 42)">
```

関数名と引数の個数はHTMLで指定します。引数には文字列、数値、真偽値、`null`、アプリ側の変数や関数の戻り値を渡せます。`input` と `textarea` の `oninput` では、`text`、`this.value`、`event.target.value` が変更後の文字列全体を表します。関数の型はCまたはDartのコンパイラが検査します。変換時は拡張変換のPython依存とNode.js・Acornが必要です。

Flutterでは、生成したDartと同じディレクトリの `htgc_handlers.dart` に実装します。

```dart
void openMessage(String title, int count, bool enabled) {
  print('$title: $count ($enabled)');
}

void saveDraft(String field, String value, int id) {
  print('$id: $field = $value');
}
```

#### Dartの処理から画面を更新する

イベント属性の引数に `event.ui` を加えると、そのページを操作する `HtgcUi` がDartに渡ります。文字入力の `text` と一緒に指定できます。

```html
<article>
  <textarea id="memo">下書き</textarea>
  <button id="save" type="button" onclick="saveMemo(event.ui)">保存</button>
  <p id="status" hidden></p>
</article>
<dialog id="saved-dialog">
  <p>保存しました</p>
  <button type="button" onclick="dismissSaved(event.ui)">閉じる</button>
</dialog>
```

```dart
import 'dart:io';

import 'main.dart' show HtgcUi;

Future<void> saveMemo(HtgcUi ui) async {
  final memo = ui.getValue('memo');
  if (memo == null) return;
  ui.setDisabled('save', true);
  ui.setText('status', '保存中…');
  ui.setVisible('status', true);
  try {
    await File('memo.txt').writeAsString(memo);
  } on FileSystemException {
    ui.setText('status', '保存できませんでした');
    return;
  } finally {
    ui.setDisabled('save', false);
  }
  ui.setText('status', '保存しました');
  await ui.showModal('saved-dialog');
}

void dismissSaved(HtgcUi ui) {
  ui.closeModal('saved-dialog');
}
```

`main.dart` は実際の生成ファイル名に置き換えてください。各操作はHTMLの `id` で対象を指定します。`setText` は子要素も含めてテキストに置き換えるため、記事の構造を保ちたいときは見出しや本文の `id` を指定します。`setValue` は入力欄の表示と値を更新し、`oninput` は発火させません。`setVisible` は `hidden` 属性を操作し、`setDisabled` はボタンとテキスト入力欄の操作を制御します。

`showModal` は閉じている `dialog` をFlutterのモーダルとして表示し、閉じると完了します。1画面につき同時に1つ開けます。`await` 中に別ページへ移動した場合、元の `ui` での操作は失敗を返します。`getValue` は対象がなければ `null`、その他の操作は `false` を返します。

GTK 4では、生成Cと同じディレクトリに `htgc_handlers.h` を置き、次のようにアプリ側の型を宣言します。定義を置いた `handlers.c` を生成Cと一緒にリンクします。入力文字列はUTF-8です。呼び出し後も保持する場合はコピーしてください。

```c
#include <stdbool.h>

void openMessage(const char *title, int count, bool enabled);
void saveDraft(const char *field, const char *value, int id);
```

```sh
HTGC -Gtk index.html -o app.gtk.c
cc -std=c11 app.gtk.c handlers.c -o app $(pkg-config --cflags --libs gtk4 libxml-2.0) -lm
./app
```

### JavaScriptを含むサイトの変換

静的変換の対象外となるHTML/CSS/JavaScriptを `-Dart` または `-Gtk` に渡すと、拡張変換を使います。HTMLを要素ツリー、CSSをスタイル規則、JavaScriptをDartまたはC11の関数や制御構造へ変換します。生成したアプリはFlutterまたはGTK 4で描画します。Electron、WebView、実行時のJavaScriptエンジンは不要です。

入口のHTMLから、リンク先のローカルHTML、参照されるCSS・JavaScript・画像をたどります。JavaScriptが実行時に作るリンクや画像参照には、入口HTMLのディレクトリを基準に `--include ファイル` を指定できます。複数ある場合はファイルごとに繰り返します。Node.jsとAcornは変換時のJavaScript構文解析に使います。

画像がある場合、HTGCは画像を生成ソースの隣の `<出力ファイル名>.assets/` にコピーします。元の相対パスは維持されます。アプリを配布するときは、このディレクトリを実行ファイルと同じ場所に置いてください。たとえば `portfolio.gtk.c` の画像は `portfolio.gtk.c.assets/` に入ります。

```sh
python3 -m pip install -r requirements-native.txt
npm --prefix javascript ci
flutter create --platforms=linux,macos,windows --project-name htgc_portfolio ../htgc_portfolio
python3 HTGC -Dart ../Tachi-Shin.github.io/index.html --include contact.html -o ../htgc_portfolio/lib/main.dart
cd ../htgc_portfolio
flutter pub add html:0.15.6 flutter_svg:2.2.1 url_launcher:6.3.2 shared_preferences:2.5.3
flutter build linux --release
cp -R lib/main.dart.assets build/linux/x64/release/bundle/
./build/linux/x64/release/bundle/htgc_portfolio
```

GTK 4版の拡張変換にはGTK 4とlibxml2の開発パッケージが必要です。Pythonとnpmの依存を上記と同様に準備してから実行します。

```sh
python3 HTGC -Gtk ../Tachi-Shin.github.io/index.html --include contact.html -o portfolio.gtk.c
cc -std=c11 portfolio.gtk.c -o portfolio-gtk $(pkg-config --cflags --libs gtk4 libxml-2.0) -lm
./portfolio-gtk dark
```

GTK 4の拡張変換はCSS描画とCanvasに未対応の箇所があるため警告を出します。`--strict` を指定すると出力を中止します。IUPの `-Clang` は静的変換に対応しています。拡張変換の手順ではリポジトリの `python3 HTGC` を使用します。ビルドと照合手順は [ベンチマーク](benchmarks/README.md) を参照してください。

## 静的変換のファイルの読み込み

```html
<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <title>サンプル</title>
  <link rel="stylesheet" href="styles/main.css">
</head>
<body>
  <main>
    <include src="parts/status.html"></include>
  </main>
</body>
</html>
```

- エントリーHTMLには明示的な `<body>` が必要です。 `<title>` は生成アプリのタイトルになります。
- CSSは `<link rel="stylesheet" href="…">`、`<style>`、`style` 属性で指定できます。
- `<include>` はHTGC独自の構文です。HTML断片はそのまま、完全なHTMLは `<body>` の中身をその位置に展開します。読み込んだファイルのCSSも共通のカスケードに入り、画面全体に適用されます。
- ネストした参照は記述元のファイルからの相対パスで解決します。循環参照、欠落ファイル、リモートURLはエラーになります。入力はUTF-8です。

## 静的変換のHTMLリンクでページを移動する

```html
<!-- main.html の body 内 -->
<a href="pages/settings.html">設定</a>

<!-- pages/settings.html の body 内 -->
<a href="../main.html">ホームに戻る</a>
```

リンク先のHTMLには `<body>` を指定します。最初のページだけをコンパイルすると、リンクからたどれるページも同じ出力に含まれます。各ページのCSSはそのページに適用されます。

リンクはIUP・GTK 4・Flutterで押せるコントロールになります。 `href` には記述元のHTMLからの相対ファイルパスを使います。外部URL、クエリ、`#section` のようなページ内リンクは未対応です。リンクのラベルはプレーンテキストで指定します。

## Web標準の対応範囲

| 仕様 | 現在の対応と未検証の範囲 |
| --- | --- |
| [WHATWG HTML](https://html.spec.whatwg.org/) | Flutterではフォームの一部、`dialog`、`details` のほか、`template.content` から断片を複製して挿入できます。ローカルの `iframe/srcdoc` と `object/embed` の文書・画像を扱います。テンプレートのShadow DOM構文、メディア要素、リモート埋め込み、sandboxポリシー、Workerは未対応です。 |
| [W3C CSS仕様一覧](https://www.w3.org/Style/CSS/specs.en.html) | Flutterの拡張変換は、名前付き・匿名・入れ子の `@layer`、レイヤー順序の宣言、ローカル `@import … layer()`、著者スタイルの `!important` と `revert-layer` に対応します。画面幅・高さ、カラーテーマ、動きを減らす設定などに応じたレイヤー順序と条件付きインポートにも対応します。ページ媒体、詳細な組版、全CSSプロパティの値文法は未対応です。 |
| [ECMA-262](https://tc39.es/ecma262/) | Acornで構文解析し、対応する式・文をDartまたはCに変換します。Flutterでは `<script type="module">` からローカルファイルを静的に `import/export` できます。名前付き・既定・名前空間のインポート、再エクスポート、循環参照とライブバインディングに対応します。ローカルの動的 `import()`、トップレベル `await`、`async/await` とPromiseの基本操作にも対応します。Symbol、通常オブジェクトの記述子・プロトタイプ操作、Map/Set/WeakMap/WeakSet、反復と分割代入、JSONの基本操作にも対応します。import map、ジェネレーター、非同期イテレーター、Proxy、TypedArrayや組み込みオブジェクトの完全な互換性は未実装です。 |

Flutterモジュールの指定子には `./logic.js`、`../shared.js`、`/shared.js` のようにパスを記述します。`/` は入口HTMLのディレクトリを表します。依存モジュールは変換時に収録され、同じ文書内では各モジュールを1回評価します。

全仕様への準拠は未達です。[ベンチマーク手順](benchmarks/README.md) に、[Web Platform Tests](https://web-platform-tests.org/) のレイヤー試験と、[Test262](https://github.com/tc39/test262) の例外処理・非同期実行・組み込みオブジェクトから選んだケースの実行方法を記載しています。

### Flutterの非同期JavaScriptとモジュール

```html
<p id="status">準備中</p>
<button id="save" type="button">保存</button>
<script type="module">
  const memo = await import('./memo.js');
  const status = document.getElementById('status');
  status.textContent = memo.ready;
  document.getElementById('save').addEventListener('click', async () => {
    try {
      status.textContent = await memo.save('メモの本文');
    } catch (error) {
      status.textContent = '保存に失敗しました';
    }
  });
</script>
```

`memo.js` の例です。ここでは非同期処理と画面更新の動作を確認するため、文字列を返します。

```js
export const ready = await Promise.resolve('準備完了');
export async function save(text) {
  const result = await Promise.resolve(text);
  return result + 'を受け取りました';
}
```

指定方法は `HTGC -Dart main.html -o test/lib/main.dart` のままです。JavaScriptは変換時にDartへ収録され、生成アプリの起動時に `.js` を読みません。

- 文字列リテラルで参照したローカルの `import('./memo.js')` は依存ファイルとして収録され、呼び出す時まで評価を遅延します。変数を使う `import(path)` は、同じ生成物に収録済みのモジュールを選択できます。未収録のファイルはPromiseを拒否します。通信で新しいJavaScriptを取得して実行する機能やimport attributesには対応していません。
- 依存先のトップレベル `await` を待ってから利用側を評価します。循環参照、共有依存、同時インポート、失敗したモジュールの再インポートでも、同じ文書の評価結果を共有します。
- `Promise` の生成、`resolve/reject`、`then/catch/finally`、`all/allSettled/race/any`、`withResolvers/try` を実装しています。引数には配列など現在対応する反復可能値を使います。Promiseのサブクラス、`Symbol.species`、汎用コンストラクターへの組み込みメソッド転用は未対応です。
- `await` はPromise、thenable、通常値を受け取ります。例外と `finally`、右辺に `await` を含む代入・短絡評価にも対応します。捕捉されなかった拒否はDartのZoneへエラーを通知します。HTMLの `unhandledrejection` / `rejectionhandled` イベントは未実装です。

### Flutterの埋め込み文書

```html
<iframe id="preview" src="parts/preview.html" width="480" height="240"></iframe>
<iframe srcdoc="&lt;p&gt;この文書も変換時に収録されます&lt;/p&gt;"></iframe>
<object data="parts/details.html" width="480" height="240"></object>
<embed src="assets/diagram.svg" width="320" height="180">
<script>
  const preview = document.getElementById('preview');
  preview.addEventListener('load', () => {
    preview.contentDocument.getElementById('status').textContent = '親から更新';
  });
</script>
```

参照するHTML・CSS・JavaScriptは変換時にたどり、同じDartソースに収録します。生成アプリはHTMLファイルを実行時に読みません。`srcdoc` は `src` より優先し、その相対参照は親文書の位置を基準に解決します。画像は従来どおり生成物の `.assets` ディレクトリへコピーします。

子文書は自身のDOM・CSS計算・スクリプトスコープ・スクロール位置を持ち、メディア条件には埋め込み領域の寸法を使います。子のリンクを押しても親文書は遷移しません。`contentDocument`、`contentWindow.document` と子文書の読み込み後の `load` 通知を実装しています。自分自身・祖先への循環埋め込みは空文書にします。

現在の対象は入力ルート内のHTMLと画像です。外部サイト、sandbox/credentialless、Permissions Policy、完全なWindowProxy/Realm分離、親文書との `postMessage`、実行中に新しい `srcdoc` をコンパイルする機能は未実装です。外部サイトとsandbox/credentiallessの指定は変換エラーにします。GTK/IUPの埋め込み文書には対応していません。

### FlutterのJavaScript組み込みオブジェクト

- `Symbol()`、`Symbol.for/keyFor`、Symbolキーのプロパティ、`Symbol.iterator`・`Symbol.toPrimitive`・`Symbol.toStringTag` を扱います。
- 通常オブジェクトのgetter/setterと継承、`Object.defineProperty/defineProperties`、属性取得、列挙順序、`assign/fromEntries/groupBy`、`create/getPrototypeOf/setPrototypeOf`、`freeze/seal/preventExtensions` と関連する判定を実装しています。Reflectからの通常オブジェクト操作にも対応します。
- `Map`・`Set` は挿入順とSameValueZero比較を使い、反復中の追加・削除・clearを扱います。Setの集合演算と包含判定、`Map.groupBy`、弱参照キーを持つ `WeakMap/WeakSet` も実装しています。
- `for...of`、spread、`Array.from`、配列の分割代入は `Symbol.iterator` を使います。break・return・例外・分割代入の終了時には、必要に応じてイテレーターの `return()` を呼びます。既定値・rest・computedキーを持つ分割代入の宣言にも対応します。
- `JSON.parse` のreviver、`JSON.stringify` のreplacer・インデント・`toJSON`・循環参照エラーを実装しています。

これらは組み込みオブジェクト全体の準拠を意味しません。配列の特殊なプロパティ記述子やfreeze/seal、完全な組み込みプロトタイプと関数メタデータ、サブクラス・Species、Proxy、TypedArray、Date/RegExpの全操作、JSONの数値精度とreviverのsource context、非同期イテレーターなどは残っています。対応する通常オブジェクト向けの操作を配列にもそのまま適用できるとは限りません。

### 条件付きCSSレイヤー

`@media` / `@supports` の中の `@layer`、および `@import "theme.css" layer(theme) supports(display: flex) screen and (min-width: 600px)` を扱います。ウィンドウのサイズや設定が変わると、条件に一致するレイヤーの最初の出現順から優先順位を計算し直します。

メディア条件は `screen/all/print`、`not/only/and/or` とカンマ区切り、幅・高さの `min/max` と範囲比較、`orientation`、`prefers-color-scheme`、`prefers-reduced-motion` に対応します。寸法は `px/em/rem` と単位なしの0を使えます。画面アプリなので `print` は一致しません。

`@supports` は `not/and/or` と宣言条件を評価します。現時点で認識するのはカスタムプロパティ、`display`、`flex-direction`、`flex-wrap`、`text-align`、`font-style`、`object-fit`、`box-sizing`、単純な寸法と `opacity` です。未実装の機能・値文法は不一致として扱います。`selector()`、コンテナの成立判定、全メディア機能は未対応です。

## 静的変換の対応範囲

- 静的なテキストとブロック、Flexの横・縦配置、子要素間の間隔。HTMLの終了タグは明示してください。テキストと要素が混在する箇所では、テキストを `<span>` などで囲みます。
- タグ・クラス・ID・全称・子孫セレクタとカンマ区切り。詳細度、記述順、インライン指定、文字スタイルの継承に対応します。
- 寸法、余白、背景色、文字色、文字サイズ、太さ、揃え、角丸と下境界線。寸法には非負の `px` を使います。単独の色を指定する `background` は `background-color` として扱います。
- CSS Grid、メディアクエリ、画像、フォーム、JavaScriptは未実装です。ブラウザの既定スタイルやレイアウトとは差があります。DartはFlutterの縦スクロールを使うため、縦の `flex-grow` は高さが有限の親内で使います。
- IUPでは `justify-content` の `start` 以外、角丸、下境界線、半透明、非対称な余白などに制約があります。変換時に近似・省略を警告します。
- GTK 4では幅・高さを最小寸法に変換します。 `justify-content` は `start` で配置し、異なる `flex-grow` の比率は伸びる子の間で均等配分します。これらの近似配置や `gap` の端数の丸めは警告します。
- `--strict` を付けると警告がある場合はファイルを出力しません。

## 構成

`frontend.py` がHTML・CSS・参照ファイルを読み、共通の `Program` と `View` を作ります。 `backend_iup.py`・`backend_gtk.py`・`backend_dart.py` が、それぞれのGUIライブラリ向けのソースを生成します。

拡張変換は `native_frontend.py` でHTML/CSSを読み、`js_dart.py` または `js_c.py` でJavaScriptの構文木から対象言語を生成します。`native_dart.py` と `native_c.py` はそれぞれの結果を `runtime/` のDOM操作、CSSカスケード、描画のコードと合わせて出力します。

## 単体実行ファイルを作る

PyInstallerで、Pythonランタイムを同梱したHTGCの単体実行ファイルを作れます。ビルドにはPython 3.10以上が必要です。完成したファイルを使う側は、Pythonを別途インストールする必要がありません。

配布先と同じOSで、リポジトリのルートから以下を実行してください。Macでは、配布先に合わせてApple Silicon用またはIntel用のPythonを使います。

### macOS・Linux

```sh
python3 -m venv .venv
.venv/bin/python -m pip install pyinstaller

mkdir -p build
cp HTGC build/htgc_entry.py

.venv/bin/python -m PyInstaller --onefile --name HTGC --paths "$PWD" \
  --specpath build --workpath build/pyinstaller --distpath dist \
  build/htgc_entry.py

./dist/HTGC -Gtk example/main.html
```

### Windows（PowerShell）

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install pyinstaller

New-Item -ItemType Directory -Force build | Out-Null
Copy-Item HTGC build/htgc_entry.py

.\.venv\Scripts\python.exe -m PyInstaller --onefile --name HTGC --paths (Get-Location).Path `
  --specpath build --workpath build/pyinstaller --distpath dist `
  build/htgc_entry.py

.\dist\HTGC.exe -Gtk example/main.html
```

配布するファイルは、macOS・Linuxでは `dist/HTGC`、Windowsでは `dist/HTGC.exe` です。生成されたCやDartをアプリとしてビルドするには、出力先に対応するGUIライブラリとビルド環境が別途必要です。


### 生成GTKアプリの配布

拡張GTK変換では、ルートHTMLを変換時に一度だけ読み込みます。実行時のアプリは埋め込み済みの全ページ、CSS、JavaScript変換結果を使い、HTML・CSS・JavaScriptを開きません。

```sh
HTGC -Gtk path/to/index.html -o build/portfolio.gtk.c
cc -std=c11 -Wall -Wextra build/portfolio.gtk.c -o build/portfolio-gtk \
  $(pkg-config --cflags --libs gtk4 libxml-2.0) -lm
cd build
./portfolio-gtk dark
```

配布ディレクトリには生成された実行ファイルと画像ファイルだけを置きます。起動時の引数はテーマ指定だけです。
