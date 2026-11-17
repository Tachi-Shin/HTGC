# ECMA-262 実装監査

対象はネイティブDartを生成するHTGCと、[ECMA-262](https://tc39.es/ecma262/)です。ソースコードを仕様の章ごとに照合しました。表は機能群単位の差分です。Test262全件を実行してサブケースまで判定した一覧ではありません。

| 仕様の領域 | 未実装、または一部だけ実装している機能 |
| --- | --- |
| 実行コンテキスト、Realm、Agent | Realmごとのintrinsic・プロトタイプ・エラーとグローバル環境の分離、スクリプトとモジュールで異なるグローバル束縛、複数Agentとメモリモデル |
| 宣言と関数 | スクリプトの非strictモード、非strictの引数オブジェクトと仮引数の連動、宣言の巻き上げ・TDZ・反復ごとの束縛の残り、Function/GeneratorFunction/AsyncFunctionコンストラクター、eval |
| クラス | 組み込み型全体のサブクラスとSpecies、派生クラスの初期化や異常終了の全条件。明示コンストラクター、super、new.target、公開・privateフィールド、privateメソッド・アクセサー、静的ブロックは対応 |
| 式と文 | with、細部の評価順と例外。using／await using、ラベル、for…in、タグ付きテンプレート、分割代入の代入形式は対応。debugger文は受理し、デバッガーを起動せず通過 |
| モジュール | ソースフェーズ、実行時の外部モジュール読み込み、ホストローダーとの連携と複数環境での評価。ローカルのモジュールグラフ、import.meta、JSONモジュールとtype属性は一部対応済み |
| オブジェクトと補助操作 | Arrayの特殊プロパティ記述子、厳密なプロトタイプ・Functionの組み込みメソッドとメタデータ、Proxyの配列転送、全組み込み型のnewTarget、内部例外の種類 |
| 基本オブジェクト・エラー | Function.prototypeと組み込み記述子の整合、Annex Bの残り。bind、関数の元ソース表示、Errorのcause、SuppressedError、Error.isErrorとURIグローバル関数は対応 |
| 数値、日時、文字列 | Number/Math/BigIntの境界とメタデータ、Dateの実装依存の旧式書式・時刻規則、ロケール依存の完全な照合・大小文字変換、Unicodeの網羅検証。Unicode 17.0のString.normalize、String.raw、コード単位・コードポイント、検索・抽出・パディング等は対応 |
| RegExp | 実行時に作るvパターン、重複する名前付きグループ、Speciesと汎用メソッド、最新Unicodeや全キャプチャ条件の差。vリテラルと静的なRegExp呼び出しを変換 |
| インデックス付きコレクション | 配列の継承、穴・length・Speciesの細部、TypedArrayの全変換順・記述子・全メソッドの派生型。Array.fromAsyncと不足していた配列メソッド、Uint8ArrayのBase64・16進変換は対応 |
| キー付き・弱参照コレクション | Map/Set/WeakMap/WeakSetの細部、弱参照のGC保証とWeakRef/FinalizationRegistry、派生型。Map・WeakMapのgetOrInsert/getOrInsertComputedは対応 |
| バイナリデータとメモリモデル | 複数Agentで共有するSharedArrayBuffer・ブロッキングAtomics.wait、ArrayBuffer新APIとSpecies、バッファ制限。単一Agent用のSharedArrayBufferとAtomicsは今回の変更で対応 |
| 非同期・反復 | AsyncIteratorの全仕様、Promiseの派生型・Species・ジョブ順の全ケース。同期Iteratorのzip、zipKeyed、map、filter、flatMap、take、drop、reduce、includes、joinなど、非同期IteratorのSymbol.asyncDispose、DisposableStackとAsyncDisposableStackは対応 |
| JSON、追加仕様 | 任意のホストフックとAnnex Bの残り。JSON.rawJSON/isRawJSONとreviverのcontext.sourceは対応。ECMA-402のIntlやHTMLのWorkerは各別仕様 |

実装の参照元は [V8のTypedArray構築とSpecies](https://github.com/v8/v8/blob/main/src/builtins/typed-array-createtypedarray.tq)、 [V8の文字クラス集合パーサー](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/lkgr/src/regexp/regexp-parser.cc)、[regexpu-core](https://github.com/mathiasbynens/regexpu-core)、[QuickJS](https://github.com/bellard/quickjs/blob/master/quickjs.c)、適合試験は [Test262](https://github.com/tc39/test262) です。regexpu-coreは変換機としてビルド時に使用します。

2026-11-17の追加実装は、引き続きJavaScriptからネイティブDartを生成します。文字列からのevalやFunction生成は未実装です。タグ付きテンプレートの同一性は実行スコープごとに保存します。ロケール系のメソッドにはDartの文字変換や基本の文字列化を使うため、ECMA-402のIntlと同じ書式・照合・言語別処理は保証しません。配列の追加メソッドはDart上の既存の配列表現を使用するため、全配列メソッドのSpeciesや配列の記述子は引き続き未完です。

2026-11-17の追加分では、イテレーターの共通プロトタイプ、Iterator.from／concat、同期ヘルパー、using／await usingとDisposableStack系、ローカルJSONモジュール、import.meta、String.normalizeを追加しました。正規化データはUnicode 17.0.0のUCDに基づき、生成スクリプトは `tools/generate_normalization.py`、利用条件は `runtime/UNICODE-LICENSE.txt` にあります。

`import.meta.url` はHTGCの入力ルートを基準とした `htgc://local/` URLです。JSONモジュールは変換時に対象ファイルを収集します。動的importでは変換済みモジュールを利用し、`with: {type: 'json'}` を検証します。複数Realm、動的なコード評価、変換後に追加されたモジュールの読み込み、複数Agentの共有メモリなどは引き続き未実装です。Iterator・リソース管理の仕様全体に対する適合性検証も継続中です。

同期Iteratorの `zip`／`zipKeyed` は仕様ドラフトの `shortest`、`longest`、`strict` モードとpaddingに対応します。非同期ジェネレーターは `Symbol.asyncDispose` で終了できます。追加のTest262は同梱ハーネスで実行できるケースを選択しています。

ブロック・関数・switch内のlet／const／classの宣言前参照と、for・for…in・for…ofの束縛を拡充しました。for (let …) の初期化式・条件式・更新式・本体のクロージャーは対応する反復の束縛を保持します。未宣言識別子のtypeofも処理します。グローバル環境、非strictモード、全ての宣言競合や束縛の仕様は引き続き未完です。
