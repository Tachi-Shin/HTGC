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

### HTMLのイベントからC・Dart関数を呼び出す

`-Gtk` と `-Dart` の拡張変換では、ボタンやリンクの `onclick` と、入力欄の `oninput` からアプリ側の関数を呼べます。

```html
<button type="button" onclick="ShowAlert()">ここをクリック</button>
<input type="text" oninput="input(text)">
```

クリックでは引数なしで呼び出し、`input(text)` には変更後の文字列全体を渡します。`textarea` でも使えます。文字列引数は `this.value` や `event.target.value` とも書けます。呼び出し先には通常の関数名を指定し、同じ名前の引数の個数は揃えます。

Flutterでは、生成したDartと同じディレクトリの `htgc_handlers.dart` に実装します。

```dart
void ShowAlert() => print('クリックされました');
void input(String text) => print(text);
```

GTK 4では、別のCソースに `void ShowAlert(void)` と `void input(const char *text)` を定義して、生成したCと一緒にリンクします。文字列はUTF-8です。呼び出し後も保持する場合はコピーしてください。

```sh
HTGC -Gtk index.html -o app.gtk.c
cc -std=c11 app.gtk.c handlers.c -o app $(pkg-config --cflags --libs gtk4 libxml-2.0) -lm
./app
```

### JavaScriptを含むサイトの変換

静的変換の対象外となるHTML/CSS/JavaScriptを `-Dart` または `-Gtk` に渡すと、拡張変換を使います。HTMLを要素ツリー、CSSをスタイル規則、JavaScriptをDartまたはC11の関数や制御構造へ変換します。生成したアプリはFlutterまたはGTK 4で描画します。Electron、WebView、実行時のJavaScriptエンジンは不要です。

入力HTMLと同じディレクトリ以下のHTMLページと画像を取り込みます。CSSとJavaScriptはローカル参照をたどります。Node.jsとAcornは変換時のJavaScript構文解析に使います。

```sh
python3 -m pip install -r requirements-native.txt
npm --prefix javascript ci
flutter create --platforms=linux,macos,windows --project-name htgc_portfolio ../htgc_portfolio
python3 HTGC -Dart ../Tachi-Shin.github.io/index.html -o ../htgc_portfolio/lib/main.dart
cd ../htgc_portfolio
flutter pub add html:0.15.6 flutter_svg:2.2.1 url_launcher:6.3.2 shared_preferences:2.5.3
flutter run
```

GTK 4版の拡張変換にはGTK 4とlibxml2の開発パッケージが必要です。Pythonとnpmの依存を上記と同様に準備してから実行します。

```sh
python3 HTGC -Gtk ../Tachi-Shin.github.io/index.html -o portfolio.gtk.c
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
