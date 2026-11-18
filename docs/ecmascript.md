# ECMA-262 実装監査

対象はネイティブDartを生成するHTGCと、[ECMA-262](https://tc39.es/ecma262/)です。ソースコードを仕様の章ごとに照合しました。表は機能群単位の差分です。Test262全件を実行してサブケースまで判定した一覧ではありません。

| 仕様の領域 | 未実装、または一部だけ実装している機能 |
| --- | --- |
| 実行コンテキスト、Realm、Agent | Realmごとのintrinsic・プロトタイプ・エラーの分離、グローバル宣言の競合やホスト仕様の残り、複数Agentとメモリモデル。globalThisとWindowの同一性、通常スクリプト間のvar・関数・字句束縛の共有、モジュールの字句束縛の分離は対応 |
| 宣言と関数 | スクリプトの非strictモード、非strictの引数オブジェクトと仮引数の連動、宣言の巻き上げ・TDZ・反復ごとの束縛の残り、実行時の任意文字列からのFunction/GeneratorFunction/AsyncFunction/AsyncGeneratorFunctionコンストラクターとevalの構文・意味の大部分。実行時evalは一部の式に対応 |
| クラス | 組み込み型全体のサブクラスとSpecies、派生クラスの初期化や異常終了の全条件。明示コンストラクター、super、new.target、公開・privateフィールド、privateメソッド・アクセサー、静的ブロックは対応 |
| 式と文 | with、細部の評価順と例外。using／await using、ラベル、for…in、タグ付きテンプレート、分割代入の代入形式は対応。debugger文は受理し、デバッガーを起動せず通過 |
| モジュール | ソースフェーズ、実行時の外部モジュール読み込み、ホストローダーとの連携と複数環境での評価。ローカルのモジュールグラフ、import.meta、JSONモジュールとtype属性は一部対応済み |
| オブジェクトと補助操作 | Arrayの特殊プロパティ記述子、厳密なプロトタイプ・Functionの組み込みメソッドとメタデータ、Proxyの配列転送、全組み込み型のnewTarget、内部例外の種類 |
| 基本オブジェクト・エラー | Function.prototypeと組み込み記述子の整合、Annex Bの残り。bind、関数の元ソース表示、Errorのcause、SuppressedError、Error.isErrorとURIグローバル関数は対応 |
| 数値、日時、文字列 | Number/Math/BigIntの境界とメタデータ、Dateの実装依存の旧式書式・時刻規則、ロケール依存の完全な照合・大小文字変換、Unicodeの網羅検証。Unicode 17.0のString.normalize、String.raw、コード単位・コードポイント、検索・抽出・パディング等は対応 |
| RegExp | 実行時に作るvパターン、重複する名前付きグループ、Speciesと汎用メソッド、最新Unicodeや全キャプチャ条件の差。vリテラルと静的なRegExp呼び出しを変換 |
| インデックス付きコレクション | 配列の継承、穴・length・Speciesの細部、TypedArrayの全変換順・記述子・全メソッドの派生型。Array.fromAsyncと不足していた配列メソッド、Uint8ArrayのBase64・16進変換は対応 |
| キー付き・弱参照コレクション | Map/Set/WeakMap/WeakSetの細部、弱参照のGCや後始末の時機、派生型の細部。WeakRefとFinalizationRegistryの基本APIに対応。Map・WeakMapのgetOrInsert/getOrInsertComputedは対応 |
| バイナリデータとメモリモデル | 複数Agentで共有するSharedArrayBuffer・ブロッキングAtomics.wait、ArrayBuffer新APIとSpecies、バッファ制限。単一Agent用のSharedArrayBufferとAtomicsは今回の変更で対応 |
| 非同期・反復 | AsyncIteratorの全仕様、Promiseの派生型・Species・ジョブ順の全ケース。同期Iteratorのzip、zipKeyed、map、filter、flatMap、take、drop、reduce、includes、joinなど、非同期IteratorのSymbol.asyncDispose、DisposableStackとAsyncDisposableStackは対応 |
| JSON、追加仕様 | 任意のホストフックとAnnex Bの残り。JSON.rawJSON/isRawJSONとreviverのcontext.sourceは対応。ECMA-402のIntlやHTMLのWorkerは各別仕様 |

実装の参照元は [V8のTypedArray構築とSpecies](https://github.com/v8/v8/blob/main/src/builtins/typed-array-createtypedarray.tq)、 [V8の文字クラス集合パーサー](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/lkgr/src/regexp/regexp-parser.cc)、[regexpu-core](https://github.com/mathiasbynens/regexpu-core)、[QuickJS](https://github.com/bellard/quickjs/blob/master/quickjs.c)、適合試験は [Test262](https://github.com/tc39/test262) です。regexpu-coreは変換機としてビルド時に使用します。

2026-11-17の追加実装は、引き続きJavaScriptからネイティブDartを生成します。変換時に固定の文字列で渡される直接evalと通常のFunction生成は一部対応しています。実行時に作られる文字列のevalは、限定した式に対応しています。タグ付きテンプレートの同一性は実行スコープごとに保存します。ロケール系のメソッドにはDartの文字変換や基本の文字列化を使うため、ECMA-402のIntlと同じ書式・照合・言語別処理は保証しません。配列の追加メソッドはDart上の既存の配列表現を使用するため、全配列メソッドのSpeciesや配列の記述子は引き続き未完です。

2026-11-17の追加分では、イテレーターの共通プロトタイプ、Iterator.from／concat、同期ヘルパー、using／await usingとDisposableStack系、ローカルJSONモジュール、import.meta、String.normalizeを追加しました。正規化データはUnicode 17.0.0のUCDに基づき、生成スクリプトは `tools/generate_normalization.py`、利用条件は `runtime/UNICODE-LICENSE.txt` にあります。

`import.meta.url` はHTGCの入力ルートを基準とした `htgc://local/` URLです。JSONモジュールは変換時に対象ファイルを収集します。動的importでは変換済みモジュールを利用し、`with: {type: 'json'}` を検証します。複数Realm、動的なコード評価の大部分、変換後に追加されたモジュールの読み込み、複数Agentの共有メモリなどは引き続き未実装です。Iterator・リソース管理の仕様全体に対する適合性検証も継続中です。

同期Iteratorの `zip`／`zipKeyed` は仕様ドラフトの `shortest`、`longest`、`strict` モードとpaddingに対応します。非同期ジェネレーターは `Symbol.asyncDispose` で終了できます。追加のTest262は同梱ハーネスで実行できるケースを選択しています。

ブロック・関数・switch内のlet／const／classの宣言前参照と、for・for…in・for…ofの束縛を拡充しました。for (let …) の初期化式・条件式・更新式・本体のクロージャーは対応する反復の束縛を保持します。未宣言識別子のtypeofも処理します。グローバル環境、非strictモード、全ての宣言競合や束縛の仕様は引き続き未完です。

固定文字列の `eval` は変換時に解析し、直接呼び出し元のスコープにアクセスするDartコードを生成します。固定文字列の `Function` は大域スコープを参照する通常関数として変換します。評価値が文字列でない `eval` は引数を返します。任意の実行時文字列、Functionへの動的な引数、評価完了値の全パターン、非strictなevalの変数環境は未実装です。AsyncFunction／GeneratorFunction／AsyncGeneratorFunctionは、コンストラクターを関数式から直接取得するか、変数に代入し、固定文字列を渡す場合に変換できます。

直接evalにおける空の文・ブロック、条件分岐、ループ、switch、try/finallyの評価完了値を拡充しました。スクリプトの全構文に対する完了値の適合性は未検証です。

通常のHTMLスクリプトでは、globalThisとwindowが同じオブジェクトを指します。globalThisへのプロパティ変更はグローバル識別子に反映され、varと関数宣言は後続スクリプトと共有されます。let・const・classはグローバルオブジェクトのプロパティを作らず、後続の通常スクリプトとモジュールから参照できます。組み込みプロトタイプのRealmごとの分離、全グローバル宣言の競合、非strictの仕様は未完です。

`WeakRef` と `FinalizationRegistry` はDartの弱参照とファイナライザーを使用します。参照対象の回収と後始末の実行時機はDartのGCとホストに依存し、ECMAScriptのジョブ境界やGCに関わる全条件は未検証です。

固定文字列の間接evalは `(0, eval)(...)`、`eval?.(...)`、`obj.eval(...)`、`const alias = eval` のような別名からの呼び出しに対応し、呼び出し元のローカル変数ではなくグローバル環境を参照します。実行時文字列の対応範囲は下記のとおりです。非strict evalのvar宣言の全動作は未対応です。

実行時文字列の `eval` は簡易パーサーで数値・基本的な文字列・真偽値・null・識別子・this、括弧、単項演算、算術・比較・論理演算、識別子への代入とセミコロン区切りの式を扱います。直接evalは呼び出し元のスコープ、間接evalはグローバルスコープを参照します。入力全体を解析してから評価し、未対応構文にはSyntaxErrorを返します。宣言を含む多くの構文や非strictの挙動は未実装であり、完全なECMAScriptパーサーではありません。

実行時evalはドット・角括弧のプロパティ参照と代入、関数・メソッド呼び出しに対応します。メソッドのthisと代入先の評価順を保持します。optional chaining、new、関数・クラス定義などは未対応です。

動的な通常のFunctionは、識別子だけの仮引数と、下記の対応範囲の本体から作成できます。グローバル環境、this、argumentsを参照します。デフォルト引数、分割代入、非同期・ジェネレーター形式の動的生成は未対応です。

実行時評価の式解析をAcorn（MIT）の構造に基づき拡充し、条件演算子、ビット演算、算術・ビット複合代入、論理代入に対応しました。参照元と利用条件はTHIRD_PARTY_NOTICES.mdに記載しています。

実行時evalのトップレベルにlet・constの単純識別子宣言を追加しました。解析完了後に束縛を予約し、TDZ・const代入・重複宣言を検証します。複数宣言と初期化式、評価値の維持に対応します。var、分割代入宣言、strict／非strictの全条件は未対応です。

実行時evalと通常の動的Functionは、ブロックの字句スコープ、if／else、throwに対応します。動的Functionではlet／constと複数の文を実行し、returnで終了できます。対応する改行位置ではセミコロンを補い、use strict指令を認識してthisと仮引数の一部の規則を適用します。var、仮引数の分割代入、strictと非strictの全規則などは未実装です。

実行時evalと通常の動的Functionでwhile、do／while、式を使うfor、ラベルなしのbreak・continue、try／catch／finally、前置・後置の++／--に対応します。ラベル、catchの分割代入は対象外です。

通常のforは単純識別子のlet／const宣言に対応します。for…in／ofでは単純識別子のlet／const、既存の変数、プロパティへの代入を扱います。for…ofではbreak、return、例外で反復を抜ける際にIteratorCloseを行います。var、分割代入、for await…ofは対象外です。
