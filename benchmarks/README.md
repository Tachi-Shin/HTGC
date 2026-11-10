# 実サイトのビルド検証

対象は [Tachi-Shin/Tachi-Shin.github.io](https://github.com/Tachi-Shin/Tachi-Shin.github.io) の
`c264c62fa8ceddac553cfd8e9873d2d659d524b4` です。
サイトのHTML・CSS・JavaScriptには変更を加えません。

## 再現手順

Python 3.10以上、Node.js 22.12以上、npm、Gitを用意し、HTGCのルートで実行します。
出力先には未使用のディレクトリ名を指定してください。

```sh
git clone https://github.com/Tachi-Shin/Tachi-Shin.github.io.git ../portfolio-site
git -C ../portfolio-site checkout c264c62fa8ceddac553cfd8e9873d2d659d524b4
python3 HTGC -Web ../portfolio-site/index.html --root ../portfolio-site \
  -o ../portfolio-app --build
cd benchmarks
npm ci
```

Apple Silicon Mac:

```sh
npm run portfolio -- ../../portfolio-app/dist/HTGC-Web-darwin-arm64/HTGC-Web.app/Contents/MacOS/HTGC-Web
node assets.cjs ../../portfolio-site ../../portfolio-app \
  ../../portfolio-app/dist/HTGC-Web-darwin-arm64/HTGC-Web.app/Contents/Resources/app.asar
```

Linux x64:

```sh
npm run portfolio -- ../../portfolio-app/dist/HTGC-Web-linux-x64/HTGC-Web
node assets.cjs ../../portfolio-site ../../portfolio-app \
  ../../portfolio-app/dist/HTGC-Web-linux-x64/resources/app.asar
```

Windowsでは `HTGC-Web-win32-x64/HTGC-Web.exe` と、その隣の `resources/app.asar` を指定します。
Linuxの自動実行にはディスプレイ環境が必要です。CI等ではXvfb等の仮想ディスプレイを使います。

`portfolio.cjs` は **ビルド済みのアプリ実行ファイル** をPlaywrightで起動します。
一時的なユーザーデータディレクトリを使うため、既存のテーマ設定などには影響しません。
外部リンクのクリックやフォーム送信は行いません。

ローカルプロトコルの回帰テストもあります。これは一時的なHTML一式を生成して、開発用Electronで
Unicodeパス、dynamic import、fetch、ディレクトリの末尾スラッシュへのリダイレクト等を検証します。
依存関係をインストール済みの生成プロジェクトを指定します。必要に応じて開発用Electronを取得します。

```sh
node runtime.cjs ../../portfolio-app
```

## 検証結果（2026-11-10）

Linux x64、Node.js 24.22.1、Electron 45.2.3 / Chromium 156.0.8078.80で確認しました。
macOS・Windows向けの実行ファイルはこの環境では検証していません。
Linuxの隔離されたテスト環境では仮想Xディスプレイと `--no-sandbox --disable-gpu` を実行時だけ使っています。
生成するアプリの設定ではsandboxを有効にしています。

| 検証項目 | 結果 |
| --- | --- |
| Electronアプリのパッケージ化・実行ファイルからの起動 | 成功 |
| 元リポジトリの全17ファイルと `app.asar` 内のバイト比較 | 一致 |
| Home / Projects / About / Contact | 全4ページを読み込み |
| ES modules / Web Components | ヘッダー・フッターを生成 |
| Homeの画像 / ニュース | 12枚 / 9件 |
| Projectsのカード / Aboutのタイムライン | 5件 / 119件 |
| CSS Grid / CSSアニメーション / IntersectionObserver | 動作 |
| テーマ切替・localStorage・移動後と再読み込み後の保持 | 動作 |
| HTMLリンク・ページ内フラグメント | 動作 |
| フォームの必須・メール形式検証 | 動作（送信なし） |
| 幅390pxでのコンテナ幅 | ウィンドウ幅内 |
| JavaScript例外・失敗したローカルリソース | なし |

### 元サイトにある制約

- `main.js` が粒子の初期化を試みた時点で、後続の `particles.js` の関数がまだ定義されていません。
  元ファイルをHTTP配信してChromiumで開いた場合も、Canvasは300×150の未描画状態になります。
  ベンチマークは自動開始の有無を `particlesAutoStarted` に記録し、その後に元の
  `window.initParticles('bg-canvas')` を明示的に呼び出して実際の描画ピクセルを検証します。
  粒子が自動開始するようにサイトを書き換えたという意味ではありません。
- Contactのフォームはサーバー側の受信サービスを必要とします。ローカルアプリのビルドだけでは送信先は作られません。

このベンチマークは上記の静的サイトを一式収録して実行できることを検証します。
任意のサーバーアプリ、全Web API、全OSでの完全互換性を保証する試験ではありません。
