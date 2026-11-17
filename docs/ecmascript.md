# ECMA-262 実装監査

対象はネイティブDartを生成するHTGCと、[ECMA-262](https://tc39.es/ecma262/)です。ソースコードを仕様の章ごとに照合しました。表は機能群単位の差分です。Test262全件を実行してサブケースまで判定した一覧ではありません。

| 仕様の領域 | 未実装、または一部だけ実装している機能 |
| --- | --- |
| 実行コンテキスト、Realm、Agent | Realmごとのintrinsic・プロトタイプ・エラーとグローバル環境の分離、スクリプトとモジュールで異なるグローバル束縛、複数Agentとメモリモデル |
| 宣言と関数 | スクリプトの非strictモード、引数オブジェクトと仮引数の連動、名前付き関数式の内側だけの束縛、宣言の巻き上げ・TDZ・反復ごとの束縛、Function/GeneratorFunction/AsyncFunctionコンストラクター、eval |
| クラス | 明示コンストラクター・super・new.target、フィールド・private名・staticブロック、組み込み型全体のサブクラスとSpecies。既定コンストラクターのクラスとクラス式、Date・RegExp・バッファやビューの派生型は対応 |
| 式と文 | ラベル付き制御、for…in、with、debugger、タグ付きテンプレート、分割代入の代入形式、明示的なリソース管理、細部の評価順と例外 |
| モジュール | import.meta、import属性、ソースフェーズ、ホストローダーとの連携と複数環境での評価。ローカルで解決できるグラフは一部対応済み |
| オブジェクトと補助操作 | Arrayの特殊プロパティ記述子、厳密なプロトタイプ・Functionの組み込みメソッドとメタデータ、Proxyの配列転送、全組み込み型のnewTarget、内部例外の種類 |
| 基本オブジェクト・エラー | 関数のbindとFunction.prototype互換性、Errorのcause、SuppressedError、組み込み記述子の整合、URIグローバル関数とAnnex B |
| 数値、日時、文字列 | Number/Math/BigIntの境界とメタデータ、Dateの実装依存の旧式書式・時刻規則、Stringの未実装メソッド・normalize・String.raw、Unicodeと正規化の網羅検証 |
| RegExp | 実行時に作るvパターン、重複する名前付きグループ、Speciesと汎用メソッド、最新Unicodeや全キャプチャ条件の差。vリテラルと静的なRegExp呼び出しを変換 |
| インデックス付きコレクション | Arrayメソッドと配列の継承、穴・length・Speciesの細部、TypedArrayの全変換順・記述子・全メソッドの派生型・新しいバイナリ変換API。map/filter/slice/subarrayとfrom/ofは派生型に対応 |
| キー付き・弱参照コレクション | Map/Set/WeakMap/WeakSetの細部、弱参照のGC保証とWeakRef/FinalizationRegistry、派生型 |
| バイナリデータとメモリモデル | 複数Agentで共有するSharedArrayBuffer・ブロッキングAtomics.wait、ArrayBuffer新APIとSpecies、バッファ制限。単一Agent用のSharedArrayBufferとAtomicsは今回の変更で対応 |
| 非同期・反復 | Iteratorヘルパー、AsyncIteratorの全仕様、DisposableStack系、Promiseの派生型・Species・ジョブ順の全ケース |
| JSON、追加仕様 | reviverのsource context、JSON.rawJSON/isRawJSON、任意のホストフック、Annex B。ECMA-402のIntlやHTMLのWorkerは各別仕様 |

実装の参照元は [V8のTypedArray構築とSpecies](https://github.com/v8/v8/blob/main/src/builtins/typed-array-createtypedarray.tq)、 [V8の文字クラス集合パーサー](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/lkgr/src/regexp/regexp-parser.cc)、[regexpu-core](https://github.com/mathiasbynens/regexpu-core)、[QuickJS](https://github.com/bellard/quickjs/blob/master/quickjs.c)、適合試験は [Test262](https://github.com/tc39/test262) です。regexpu-coreは変換機としてビルド時に使用します。
