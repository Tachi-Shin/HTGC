# Hyper Text GUI Compiler (HTGC)

Dartのアプリ開発でGUI定義が面倒だったので自分用に作りました．
CのGUI定義ライブラリにも対応しています．

## 概要

HTMLとCSSで宣言した画面を、C11（IUP・GTK 4）またはDart（Flutter）のGUIソースに変換します。生成したアプリは対象のGUIライブラリで描画します。

JavaScriptやブラウザのレイアウト機能を使う既存サイトには、`-Web` でElectron/Chromiumを同梱したデスクトップアプリを生成できます。HTML・CSS・JavaScript・画像をそのまま取り込み、ブラウザエンジンで実行します。

| 出力 | 実行方式 | 対応範囲 |
| --- | --- | --- |
| `-Clang` / `-Gtk` / `-Dart` | IUP / GTK 4 / Flutterのウィジェット | 下記の静的HTML/CSSの部分集合 |
| `-Web` | Electron / Chromium | 同梱Chromiumが実行できるクライアント側HTML/CSS/JavaScript |

`-Web` はJavaScriptをCやDartへ変換する方式ではありません。外部サーバーの処理や、あらゆるWebサイト・Web APIの互換性まで自動的に再現するものではありません。

## 使い方

CLIオプションの一覧は `python3 HTGC --help` で確認できます。

変換にはPython 3.10以上が必要です。変換器の追加パッケージはありません。macOS・Linuxでは、展開したディレクトリから実行します。

```sh
chmod +x HTGC
./HTGC -Clang example/main.html   # example/main.c
./HTGC -Gtk example/main.html     # example/main.gtk.c
./HTGC -Dart example/main.html    # example/main.dart
```

`HTGC` をPATHから起動できるようにすれば、`HTGC -Clang main.html` と呼び出せます。Windowsでは `py -3 HTGC -Clang example/main.html` と実行できます。 `-o` で出力先を指定できます。 `-Clang` はCを出力するためのオプション名です。

### HTML / CSS / JavaScript → デスクトップアプリ

アプリのビルドには **Node.js 22.12以上とnpm** が必要です。Pythonでプロジェクトを生成するだけならNode.jsは不要です。

```sh
git clone https://github.com/Tachi-Shin/Tachi-Shin.github.io.git ../portfolio-site

python3 HTGC -Web ../portfolio-site/index.html \
  --root ../portfolio-site -o ../portfolio-app --build
```

`--build` は生成後に `npm install` と `npm run build` を実行します。初回はネットワークからElectronとパッケージを取得します。生成プロジェクトにはElectron 45.2.3とElectron Packager 20.3.0を指定しています。

Apple Silicon Macでは、完成後に次のコマンドで起動できます。

```sh
open ../portfolio-app/dist/HTGC-Web-darwin-arm64/HTGC-Web.app
```

ビルドしたOS・CPU向けのアプリが `dist/HTGC-Web-<platform>-<arch>/` に作られます。macOSでは `.app`、Windows・Linuxでは実行ファイルと同じフォルダのリソースをまとめて配布します。Chromiumを同梱するため、ネイティブ変換より配布サイズが大きくなります。アプリを使う側でPython・Node.jsをインストールする必要はありません。

生成後に開発用起動や再ビルドもできます。

```sh
cd ../portfolio-app
npm start
npm run build
```

- `--root` は公開するサイトのルートです。省略時は入力HTMLのディレクトリを使います。サブディレクトリのページを入口にするときは、共有のCSS・画像が含まれるルートを指定してください。
- リンク解析でファイルを選別せず、ルート全体をコピーします。JavaScriptで組み立てるパス、リンクされていないHTML、動的importやfetch用のファイルも取り込めます。ビルドが必要なReact/Vue等のプロジェクトでは、先にWeb用のビルドを行い、その出力ディレクトリを指定してください。
- `.git`・`.hg`・`.svn`・`node_modules`・`__pycache__`・`.venv`・`venv`・`.DS_Store` は除外します。シンボリックリンクはエラーにします。ルートには配布するファイルを配置してください。
- `-o` は新規ディレクトリです。省略時は入力名の拡張子を `.web` にしたパスです。既存の出力先を上書きしません。ビルドだけが失敗した場合は生成済みプロジェクトを残すので、そこで `npm install` / `npm run build` を再実行できます。
- サイトは `htgc://app/` をルートとして読み込みます。相対パス、`/assets/...`、ディレクトリの `index.html`、クエリ、フラグメントに対応します。HTTP(S)等への外部リンクはシステムの既定ブラウザ等で開きます。
- 生成する `package.json` の `name` は入力パスから作るアプリ識別子です。異なる入口のアプリでは保存領域を分離します。ソースの配置を変えて再生成したときも保存データを引き継ぎたい場合は、以前の `name` を維持してください。
- JavaScriptのDOM操作、ES modules、Web Components、CSS Grid、メディアクエリ、アニメーション、Canvas、フォーム入力、localStorage等はChromiumが処理します。サイト内スクリプトからNode.js APIを使う設定にはしていません。
- PHP・Flask・API・認証サーバー・フォームの受信処理などは同梱しません。外部APIは引き続き通信先とCORS設定が必要です。同梱ファイルへのPOST等は405を返します。
- オリジンは元のHTTPSサイトと異なります。元サイトのCookie、ログイン状態、ドメイン限定APIやCSP等はそのまま引き継げません。HTGC独自の `<include>` 展開や `--strict` の警告検査は、以下のネイティブ変換用です。

実サイトのビルドと起動を検証する手順・結果は [benchmarks/README.md](benchmarks/README.md) にあります。

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

## ネイティブ変換：ファイルの読み込み

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

## ネイティブ変換：HTMLリンクでページを移動する

```html
<!-- main.html の body 内 -->
<a href="pages/settings.html">設定</a>

<!-- pages/settings.html の body 内 -->
<a href="../main.html">ホームに戻る</a>
```

リンク先のHTMLには `<body>` を指定します。最初のページだけをコンパイルすると、リンクからたどれるページも同じ出力に含まれます。各ページのCSSはそのページに適用されます。

リンクはIUP・GTK 4・Flutterで押せるコントロールになります。 `href` には記述元のHTMLからの相対ファイルパスを使います。外部URL、クエリ、`#section` のようなページ内リンクは未対応です。リンクのラベルはプレーンテキストで指定します。

## ネイティブ変換の対応範囲

- 静的なテキストとブロック、Flexの横・縦配置、子要素間の間隔。HTMLの終了タグは明示してください。テキストと要素が混在する箇所では、テキストを `<span>` などで囲みます。
- タグ・クラス・ID・全称・子孫セレクタとカンマ区切り。詳細度、記述順、インライン指定、文字スタイルの継承に対応します。
- 寸法、余白、背景色、文字色、文字サイズ、太さ、揃え、角丸と下境界線。寸法には非負の `px` を使います。単独の色を指定する `background` は `background-color` として扱います。
- CSS Grid、メディアクエリ、画像、フォーム、JavaScriptは未実装です。ブラウザの既定スタイルやレイアウトとは差があります。DartはFlutterの縦スクロールを使うため、縦の `flex-grow` は高さが有限の親内で使います。
- IUPでは `justify-content` の `start` 以外、角丸、下境界線、半透明、非対称な余白などに制約があります。変換時に近似・省略を警告します。
- GTK 4では幅・高さを最小寸法に変換します。 `justify-content` は `start` で配置し、異なる `flex-grow` の比率は伸びる子の間で均等配分します。これらの近似配置や `gap` の端数の丸めは警告します。
- `--strict` を付けると警告がある場合はファイルを出力しません。

## 構成

`frontend.py` がHTML・CSS・参照ファイルを読み、共通の `Program` と `View` を作ります。 `backend_iup.py`・`backend_gtk.py`・`backend_dart.py` が、それぞれのGUIライブラリ向けのソースを生成します。

`backend_web.py` は独立した出力経路です。サイトを改変せずにコピーし、Electronの起動コード・ローカルファイル用プロトコル・npmビルド設定を生成します。

```sh
python3 -m unittest discover -s tests -v
```

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
