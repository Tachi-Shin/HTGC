# ポートフォリオのDart変換ベンチマーク

対象は [Tachi-Shin/Tachi-Shin.github.io](https://github.com/Tachi-Shin/Tachi-Shin.github.io) のコミット `c264c62fa8ceddac553cfd8e9873d2d659d524b4` です。

HTGCのルートで実行します。Python 3.10以上、Node.js/npm、Flutterと対象OSのFlutterデスクトップ開発環境を用意してください。Flutter 3.47.9 / Dart 3.13.7で検証しました。

```sh
python3 -m pip install -r requirements-native.txt
npm --prefix javascript ci
git clone https://github.com/Tachi-Shin/Tachi-Shin.github.io.git ../portfolio-site
git -C ../portfolio-site checkout c264c62fa8ceddac553cfd8e9873d2d659d524b4
flutter create --platforms=linux,macos,windows --project-name htgc_portfolio ../portfolio-app
python3 HTGC -Dart ../portfolio-site/index.html -o ../portfolio-app/lib/main.dart
cp benchmarks/portfolio_test.dart ../portfolio-app/test/portfolio_test.dart
cd ../portfolio-app
flutter pub add html:0.15.6 flutter_svg:2.2.1 url_launcher:6.3.2 shared_preferences:2.5.3
flutter test test/portfolio_test.dart
```

Linux x64でリリース版をビルドして起動します。

```sh
flutter build linux --release
./build/linux/x64/release/bundle/htgc_portfolio
```

Contactは元サイトのナビゲーションにリンクがありません。個別ページを入口として起動するには、実行ファイルの最初の引数にルートからの相対パスを指定します。

```sh
./build/linux/x64/release/bundle/htgc_portfolio contact.html
```

Apple Silicon Macでは `flutter build macos --release` でビルドし、`open build/macos/Build/Products/Release/htgc_portfolio.app` で起動します。macOSとWindowsの実行確認は未実施です。

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
