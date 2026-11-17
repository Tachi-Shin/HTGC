# Hyper Text GUI Compiler (HTGC)

Dartのアプリ開発でGUI定義が面倒だったので自分用に作りました．
HTML・CSS・JavaScriptからFlutterのネイティブUIを生成します．

## 概要

HTML・CSS・JavaScriptからDart（Flutter）のGUIソースを生成するコンパイラです。出力先はDartに統一しました。C・GTK・IUPのコード生成は提供しません。

## 使い方

CLIオプションの一覧は `python3 HTGC --help` で確認できます。

変換にはPython 3.10以上が必要です。下記の静的変換にはPythonの追加パッケージは不要です。macOS・Linuxでは、展開したディレクトリから実行します。

```sh
chmod +x HTGC
./HTGC example/main.html                     # example/main.dart
./HTGC -Dart example/main.html -o main.dart  # 従来の指定も使用可能
```

`HTGC` をPATHから起動できるようにすれば、`HTGC main.html -o main.dart` と呼び出せます。Windowsでは `py -3 HTGC main.html -o main.dart` と実行できます。`-Gtk` と `-Clang` は廃止し、指定するとエラーになります。

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

### HTMLのイベントからDart関数を呼び出す

拡張変換では、ボタンやリンクの `onclick` と、入力欄の `oninput` からアプリ側の関数を呼べます。

```html
<button type="button" onclick="openMessage('確認', 3, true)">ここをクリック</button>
<input type="text" oninput="saveDraft('title', text, 42)">
```

関数名と引数の個数はHTMLで指定します。引数には文字列、数値、真偽値、`null`、アプリ側の変数や関数の戻り値を渡せます。`input` と `textarea` の `oninput` では、`text`、`this.value`、`event.target.value` が変更後の文字列全体を表します。関数の型はDartのコンパイラが検査します。変換時は拡張変換のPython依存とNode.js・Acornが必要です。

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

### JavaScriptを含むサイトの変換

静的変換の対象外となるHTML/CSS/JavaScriptを HTGCに渡すと、拡張変換を使います。HTMLを要素ツリー、CSSをスタイル規則、JavaScriptをDartの関数や制御構造へ変換します。生成したアプリはFlutterで描画します。Electron、WebView、実行時のJavaScriptエンジンは不要です。

入口のHTMLから、リンク先のローカルHTML、参照されるCSS・JavaScript・画像をたどります。JavaScriptが実行時に作るリンクや画像参照には、入口HTMLのディレクトリを基準に `--include ファイル` を指定できます。複数ある場合はファイルごとに繰り返します。Node.jsとAcornは変換時のJavaScript構文解析に使います。

画像がある場合、HTGCは画像を生成ソースの隣の `<出力ファイル名>.assets/` にコピーします。元の相対パスは維持されます。アプリを配布するときは、このディレクトリを実行ファイルと同じ場所に置いてください。たとえば `main.dart` の画像は `main.dart.assets/` に入ります。

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

ビルドと照合手順は [ベンチマーク](benchmarks/README.md) を参照してください。

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

リンクはFlutterで押せるコントロールになります。 `href` には記述元のHTMLからの相対ファイルパスを使います。外部URL、クエリ、`#section` のようなページ内リンクは未対応です。リンクのラベルはプレーンテキストで指定します。

## Web標準の対応範囲

| 仕様 | 現在の対応と未検証の範囲 |
| --- | --- |
| [WHATWG HTML](https://html.spec.whatwg.org/) | Flutterではフォームの一部、`dialog`、`details` のほか、`template.content` から断片を複製して挿入できます。ローカルの `iframe/srcdoc` と `object/embed` の文書・画像を扱います。テンプレートのShadow DOM構文、メディア要素、リモート埋め込み、sandboxポリシー、Workerは未対応です。 |
| [W3C CSS仕様一覧](https://www.w3.org/Style/CSS/specs.en.html) | Flutterの拡張変換は、名前付き・匿名・入れ子の `@layer`、レイヤー順序の宣言、ローカル `@import … layer()`、著者スタイルの `!important` と `revert-layer` に対応します。画面幅・高さ、カラーテーマ、動きを減らす設定などに応じたレイヤー順序と条件付きインポートにも対応します。ページ媒体、詳細な組版、全CSSプロパティの値文法は未対応です。 |
| [ECMA-262](https://tc39.es/ecma262/) | Acornで構文解析し、対応する式・文をDartに変換します。Flutterでは `<script type="module">` からローカルファイルを静的に `import/export` できます。名前付き・既定・名前空間のインポート、再エクスポート、循環参照とライブバインディングに対応します。ローカルの動的 `import()`、トップレベル `await`、`async/await` とPromiseの基本操作にも対応します。BigIntとNumberの数値変換・演算、Symbol、通常オブジェクトの記述子・プロトタイプ操作、Map/Set/WeakMap/WeakSet、反復と分割代入、JSONの基本操作にも対応します。ジェネレーターと非同期反復、Proxy、ArrayBuffer/DataView/TypedArray、Date、RegExpも下記の範囲で扱います。未実装・部分実装の内訳は[ECMA-262実装監査](docs/ecmascript.md)に記載しています。 |

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

### ECMAScriptの数値・BigInt

JavaScriptのNumberはDartの `double`、BigIntはDartの `BigInt` を使って生成します。Numberの整数リテラルもIEEE 754のbinary64へ丸め、32ビットのビット演算とシフト回数のマスクを適用します。`>>>`、符号付きゼロ、NaN、Infinity、NumberとBigIntの比較、文字列・真偽値・オブジェクトの数値変換を扱います。

```html
<p id="total"></p>
<script>
  const total = 9007199254740993n + 10n;
  document.getElementById('total').textContent = total.toString();
</script>
```

- BigIntの整数リテラル、`BigInt()`、四則演算・剰余・べき乗・ビット演算・符号付きシフト、`++/--`、`asIntN/asUintN`、`toString/valueOf` に対応します。Numberとの算術混在、ゼロ除算、不正な文字列などはJavaScriptの例外として捕捉できます。
- `Number` の定数、`isNaN/isFinite/isInteger/isSafeInteger`、`parseInt/parseFloat`、`toString/toFixed/toExponential/toPrecision/valueOf` を実装しています。小数点以下・有効桁数の指定は各メソッドの0〜100または1〜100の範囲で扱います。
- `Math` の丸め・符号・32ビット演算、単精度への丸め、基本的な三角関数・指数・対数、`pow`、`hypot` を実装しています。`hypot` は値をスケーリングして途中のオーバーフロー・アンダーフローを避けます。
- 通常のユーザー定義関数を `new` で呼ぶと、`prototype` を参照したインスタンスを作り、`this` を渡します。アロー関数への `new` は例外になります。関数・クラス・サブクラス全体の完全互換性を示すものではありません。

BigIntのべき乗・左シフト・幅指定には、巨大なメモリ確保を避けるため1,000万ビットの実装上限を設けています。必要な結果が上限を超える場合は `RangeError` になります。10以外の基数でのNumberの文字列化は、ECMA-262で実装依存とされる丸めを含み、すべての入力でV8と同じ文字列になることは保証しません。Intlによるロケール整形や、全組み込みオブジェクトの完全な互換性は未達です。

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

現在の対象は入力ルート内のHTMLと画像です。外部サイト、sandbox/credentialless、Permissions Policy、完全なWindowProxy/Realm分離、親文書との `postMessage`、実行中に新しい `srcdoc` をコンパイルする機能は未実装です。外部サイトとsandbox/credentiallessの指定は変換エラーにします。

### FlutterのJavaScript組み込みオブジェクト

- `Symbol()`、`Symbol.for/keyFor`、Symbolキーのプロパティ、`Symbol.iterator`・`Symbol.toPrimitive`・`Symbol.toStringTag` を扱います。
- 通常オブジェクトのgetter/setterと継承、`Object.defineProperty/defineProperties`、属性取得、列挙順序、`assign/fromEntries/groupBy`、`create/getPrototypeOf/setPrototypeOf`、`freeze/seal/preventExtensions` と関連する判定を実装しています。Reflectからの通常オブジェクト操作にも対応します。
- `Map`・`Set` は挿入順とSameValueZero比較を使い、反復中の追加・削除・clearを扱います。Setの集合演算と包含判定、`Map.groupBy`、弱参照キーを持つ `WeakMap/WeakSet` も実装しています。
- `for...of`、spread、`Array.from`、配列の分割代入は `Symbol.iterator` を使います。break・return・例外・分割代入の終了時には、必要に応じてイテレーターの `return()` を呼びます。既定値・rest・computedキーを持つ分割代入の宣言にも対応します。
- `JSON.parse` のreviver、`JSON.stringify` のreplacer・インデント・`toJSON`・循環参照エラーを実装しています。

これらは組み込みオブジェクト全体の準拠を意味しません。配列の特殊なプロパティ記述子やfreeze/seal、完全な組み込みプロトタイプと関数メタデータ、サブクラス・Species、JSONのreviverのsource contextなどは残っています。Proxy・TypedArray・Date・RegExp・非同期反復の対応範囲は次の表を参照してください。対応する通常オブジェクト向けの操作を配列にもそのまま適用できるとは限りません。

### ジェネレーター・Proxy・バイナリデータ・日時・正規表現

生成されるDartソースには、次の実行時処理も含まれます。ジェネレーターの中断位置とローカル変数はDartの `sync*` の継続で保持し、JavaScriptのASTを実行時に解釈しません。ランタイムの分割ファイルは生成時にインライン化されるため、配布するDartソースは引き続き1ファイルです。

| 機能 | 実装した操作 |
| --- | --- |
| ジェネレーター | `function*`、`yield`、`yield*`、`next(value)`、`throw(value)`、`return(value)`、再入の拒否、catch/finally内の中断、条件式・ループ・分割代入の初期値の中断 |
| 非同期反復 | `async function*`、await、Promise値のyield、要求のキュー処理、同期／非同期イテレーターへの委譲、`for await...of`、break/return/throw時の後始末 |
| Proxy | 13種類のトラップ、通常オブジェクト・関数への転送、固定プロパティと拡張不可状態に対する不変条件、`Proxy.revocable`、通常のユーザー定義コンストラクターに対する `Reflect.construct` とnewTarget |
| ArrayBuffer / DataView | バッファ共有、resize、slice、transfer、transferToFixedLength、デタッチ判定、エンディアンを指定した整数・浮動小数点・BigIntの読み書き |
| TypedArray | 符号付き／符号なし整数、Uint8Clamped、Float16/32/64、BigInt64/BigUint64、インデックス操作、from/of、反復、set/subarray/slice、検索・集計・map/filter、安定ソート、変更せずコピーを返す操作、可変長バッファ上のビュー |
| Date | 時刻値、TimeClip、ISO形式と生成したUTC／ローカル形式の解析、UTC／ローカルのget/set、ISO・UTC文字列、JSON変換、無効日時、年0〜99の変換 |
| RegExp | `d/g/i/m/s/u/y`、lastIndex、名前付きキャプチャとindices、exec/test、検索・置換・分割・matchAllとSymbol経由の呼び出し、RegExp.escape、compile。`v` はリテラルとパターン・フラグを文字列リテラルで渡す直接の `RegExp(...)` / `new RegExp(...)` を変換。 |
| SharedArrayBufferとAtomics | 単一のFlutter isolate内でのバッファ共有、grow、slice、整数・BigIntの原子的な読み書き、waitAsyncのタイムアウトとnotify。FlutterのUIエージェントは同期waitを拒否。 |
| 組み込み型の派生クラス | 既定コンストラクターのクラス宣言・クラス式。Date、RegExp、ArrayBuffer、SharedArrayBuffer、DataView、TypedArray各型の内部データと派生プロトタイプを保持。`slice` などのバッファ・TypedArray操作でSymbol.speciesを参照。 |

5機能を組み合わせて、HTMLのボタンから非同期にバイナリデータを集計するサンプルは [benchmarks/ecmascript/index.html](benchmarks/ecmascript/index.html) にあります。

```sh
HTGC benchmarks/ecmascript/index.html -o ../portfolio-app/lib/main.dart
```

通常の関数・ジェネレーター関数・アロー関数に `name` と `length` を付け、ジェネレーターを `new` で呼んだ場合はTypeErrorにします。Date/RegExpを含む通常のprototypeチェーンと、カスタム `Symbol.hasInstance` による `instanceof` 判定を扱います。

これらはECMAScript全仕様の実装完了を意味しません。特に次の制限があります。

- 完全な関数・クラス・Realm・厳密モードの差、ラベル付き制御構文、タグ付きテンプレート、動的Function/eval、ループの束縛や非同期ジョブの全ケースは未対応または未検証です。
- Proxyで配列を包んだときの特殊な記述子・拡張禁止など、通常オブジェクトと異なる内部操作は未完です。上表の型では独自newTargetを渡すReflect.constructも扱います。その他の組み込みコンストラクターは未対応です。
- 明示的なクラスコンストラクター、super、未対応の組み込み派生型、複数エージェント間の共有メモリ、すべての副作用順序・メタデータの互換性は未完です。1個のArrayBufferは最大256 MiBとし、上限を超える指定はRangeErrorにします。
- 実行時に組み立てた文字列からの `v` パターンは未対応です。変換対象の `v` はregexpu-coreでDartのRegExpが扱える形に書き換えます。正規表現のマッチングにはDartのRegExpを使うため、Unicodeデータ・重複する名前付きグループなど最新仕様との差が残ります。`d` の位置取得には追加キャプチャを使い、長い入力で追加の処理コストが発生します。
- Dateのタイムゾーン規則は実行環境に依存します。実装依存の旧式日付文字列すべての受理や、Intlによるロケール整形は保証しません。

検証範囲と再実行手順は [benchmarks/README.md](benchmarks/README.md) に記載しています。Test262全体の合格を示すものではありません。

### 条件付きCSSレイヤー

`@media` / `@supports` の中の `@layer`、および `@import "theme.css" layer(theme) supports(display: flex) screen and (min-width: 600px)` を扱います。ウィンドウのサイズや設定が変わると、条件に一致するレイヤーの最初の出現順から優先順位を計算し直します。

メディア条件は `screen/all/print`、`not/only/and/or` とカンマ区切り、幅・高さの `min/max` と範囲比較、`orientation`、`prefers-color-scheme`、`prefers-reduced-motion` に対応します。寸法は `px/em/rem` と単位なしの0を使えます。画面アプリなので `print` は一致しません。

`@supports` は `not/and/or` と宣言条件を評価します。現時点で認識するのはカスタムプロパティ、`display`、`flex-direction`、`flex-wrap`、`text-align`、`font-style`、`object-fit`、`box-sizing`、単純な寸法と `opacity` です。未実装の機能・値文法は不一致として扱います。`selector()`、コンテナの成立判定、全メディア機能は未対応です。

## 静的変換の対応範囲

- 静的なテキストとブロック、Flexの横・縦配置、子要素間の間隔。HTMLの終了タグは明示してください。テキストと要素が混在する箇所では、テキストを `<span>` などで囲みます。
- タグ・クラス・ID・全称・子孫セレクタとカンマ区切り。詳細度、記述順、インライン指定、文字スタイルの継承に対応します。
- 寸法、余白、背景色、文字色、文字サイズ、太さ、揃え、角丸と下境界線。寸法には非負の `px` を使います。単独の色を指定する `background` は `background-color` として扱います。
- CSS Grid、メディアクエリ、画像、フォーム、JavaScriptは未実装です。ブラウザの既定スタイルやレイアウトとは差があります。DartはFlutterの縦スクロールを使うため、縦の `flex-grow` は高さが有限の親内で使います。

## 構成

`frontend.py` がHTML・CSS・参照ファイルを読み、共通の `Program` と `View` を作ります。 `backend_dart.py` が静的なFlutterウィジェットを生成します。

拡張変換は `native_frontend.py` でHTML/CSSを読み、`js_dart.py` でJavaScriptの構文木からDartを生成します。`native_dart.py` はその結果を `runtime/` のDOM操作、CSSカスケード、描画のコードと合わせて出力します。

## 単体実行ファイルを作る

PyInstallerで、Pythonランタイムを同梱したHTGCの単体実行ファイルを作れます。ビルドにはPython 3.10以上が必要です。完成したファイルを使う側は、Pythonを別途インストールする必要がありません。

配布先と同じOSで、リポジトリのルートから以下を実行してください。Macでは、配布先に合わせてApple Silicon用またはIntel用のPythonを使います。

### macOS・Linux

```sh
python3 -m venv .venv
.venv/bin/python -m pip install pyinstaller -r requirements-native.txt
npm --prefix javascript ci

mkdir -p build
cp HTGC build/htgc_entry.py

.venv/bin/python -m PyInstaller --onefile --name HTGC --paths "$PWD" \
  --specpath build --workpath build/pyinstaller --distpath dist \
  --add-data "$PWD/runtime:runtime" --add-data "$PWD/javascript:javascript" \
  build/htgc_entry.py

./dist/HTGC -Dart example/main.html
```

### Windows（PowerShell）

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install pyinstaller -r requirements-native.txt
npm --prefix javascript ci

New-Item -ItemType Directory -Force build | Out-Null
Copy-Item HTGC build/htgc_entry.py
$project_root = (Get-Location).Path

.\.venv\Scripts\python.exe -m PyInstaller --onefile --name HTGC --paths $project_root `
  --specpath build --workpath build/pyinstaller --distpath dist `
  --add-data "$project_root\runtime;runtime" --add-data "$project_root\javascript;javascript" `
  build/htgc_entry.py

.\dist\HTGC.exe -Dart example/main.html
```

配布するファイルは、macOS・Linuxでは `dist/HTGC`、Windowsでは `dist/HTGC.exe` です。上記では描画ランタイムとAcorn・regexpu-coreを含むJavaScript変換用ファイルも同梱します。JavaScriptを含む入力の変換時には、実行するPCのPATHにNode.jsが必要です。Node.jsは生成アプリの実行時には使いません。生成されたDartをアプリとしてビルドするには、Flutter SDKと対象OSのビルド環境が必要です。
