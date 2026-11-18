# ECMA-262 実装監査

対象はネイティブDartを生成するHTGCと、[ECMA-262](https://tc39.es/ecma262/)です。ソースコードを仕様の章ごとに照合しました。表は機能群単位の差分です。Test262全件を実行してサブケースまで判定した一覧ではありません。

| 仕様の領域 | 未実装、または一部だけ実装している機能 |
| --- | --- |
| 実行コンテキスト、Realm、Agent | 文書ごとにグローバル環境と組み込みを分離。Realm間の全呼び出し・ジョブの検証、グローバル宣言の競合、複数Agentとメモリモデルが残る。globalThisとWindowの同一性、通常スクリプト間のvar・関数・字句束縛の共有、モジュールの字句束縛の分離は対応 |
| 宣言と関数 | 非strictスクリプトの残りの規則、宣言の巻き上げ・TDZ・反復ごとの束縛の残り、実行時の任意文字列からのFunction/GeneratorFunction/AsyncFunction/AsyncGeneratorFunctionコンストラクターとevalの構文・意味の大部分。実行時評価の対応範囲を下記に記載 |
| クラス | 組み込み型全体のサブクラスとSpecies、派生クラスの初期化や異常終了の全条件。明示コンストラクター、super、new.target、公開・privateフィールド、privateメソッド・アクセサー、静的ブロック、extends式と計算プロパティ名でのawait・yieldに対応 |
| 式と文 | 細部の評価順と例外。非strictのwith、Symbol.unscopables、オブジェクト環境に束縛された関数のthisに対応。using／await using、ラベル、for…in、タグ付きテンプレート、分割代入の代入形式は対応。debugger文は受理し、デバッガーを起動せず通過 |
| モジュール | ソースフェーズ、実行時の外部モジュール読み込み、ホストローダーとの連携と複数環境での評価。ローカルのモジュールグラフ、import.meta、JSONモジュールとtype属性は一部対応済み |
| オブジェクトと補助操作 | 厳密なプロトタイプ・Functionの組み込みメソッドとメタデータ、全組み込み型のnewTargetと内部例外の種類。配列の添字・lengthの記述子とProxyを経由した拡張制御に対応 |
| 基本オブジェクト・エラー | Function.prototypeと組み込み記述子の整合、Annex Bの残り。bind、関数の元ソース表示、Errorのcause、SuppressedError、Error.isErrorとURIグローバル関数は対応 |
| 数値、日時、文字列 | Number/Math/BigIntの境界とメタデータ、Dateの実装依存の旧式書式・時刻規則、ロケール依存の完全な照合・大小文字変換、Unicodeの網羅検証。Unicode 17.0のString.normalize、String.raw、コード単位・コードポイント、検索・抽出・パディング等は対応 |
| RegExp | Dart SDKのUnicodeデータや全キャプチャ条件の差。選択肢ごとに重複する名前付きグループとindices、split・matchAllのSpecies、vリテラルと動的パターンの集合演算に対応 |
| インデックス付きコレクション | TypedArrayの全変換順・記述子・全メソッドの派生型。配列の継承、穴・length、Symbol.species、Array.from／of／fromAsync、Uint8ArrayのBase64・16進変換に対応 |
| キー付き・弱参照コレクション | Map/Set/WeakMap/WeakSetの例外・副作用順序の全条件、弱参照のGCや後始末の時機。各コレクションの構築時に派生プロトタイプを使用し、上書きしたset・addを初期値にも適用。WeakRefとFinalizationRegistryの基本APIに対応。Map・WeakMapのgetOrInsert/getOrInsertComputedは対応 |
| バイナリデータとメモリモデル | 複数Agentで共有するSharedArrayBuffer・ブロッキングAtomics.wait、ArrayBuffer新APIとSpecies、バッファ制限。単一Agent用のSharedArrayBufferとAtomicsは今回の変更で対応 |
| 非同期・反復 | AsyncIteratorの全仕様、Promiseのジョブ順・Realm境界を含む全条件の検証。Promiseの派生クラス、then・finallyでのSpecies選択、静的メソッドの汎用呼び出しに対応。同期Iteratorのzip、zipKeyed、map、filter、flatMap、take、drop、reduce、includes、joinなど、非同期IteratorのSymbol.asyncDispose、DisposableStackとAsyncDisposableStackは対応 |
| JSON、追加仕様 | 任意のホストフックとAnnex Bの残り。JSON.rawJSON/isRawJSONとreviverのcontext.sourceは対応。ECMA-402のIntlやHTMLのWorkerは各別仕様 |

実装の参照元は [V8のTypedArray構築とSpecies](https://github.com/v8/v8/blob/main/src/builtins/typed-array-createtypedarray.tq)、 [V8の文字クラス集合パーサー](https://chromium.googlesource.com/v8/v8.git/+/refs/heads/lkgr/src/regexp/regexp-parser.cc)、[regexpu-core](https://github.com/mathiasbynens/regexpu-core)、[QuickJS](https://github.com/bellard/quickjs/blob/master/quickjs.c)、適合試験は [Test262](https://github.com/tc39/test262) です。regexpu-coreは変換機としてビルド時に使用します。

2026-11-17の追加実装は、引き続きJavaScriptからネイティブDartを生成します。変換時に固定の文字列で渡される直接evalと通常のFunction生成は一部対応しています。実行時文字列にはDartのパーサーを使用します。タグ付きテンプレートの同一性は実行スコープごとに保存します。ロケール系のメソッドにはDartの文字変換や基本の文字列化を使うため、ECMA-402のIntlと同じ書式・照合・言語別処理は保証しません。配列の継承・記述子・Speciesの選択を試験し、実装範囲はREADMEに記載しています。

2026-11-17の追加分では、イテレーターの共通プロトタイプ、Iterator.from／concat、同期ヘルパー、using／await usingとDisposableStack系、ローカルJSONモジュール、import.meta、String.normalizeを追加しました。正規化データはUnicode 17.0.0のUCDに基づき、生成スクリプトは `tools/generate_normalization.py`、利用条件は `runtime/UNICODE-LICENSE.txt` にあります。

`import.meta.url` はHTGCの入力ルートを基準とした `htgc://local/` URLです。JSONモジュールは変換時に対象ファイルを収集します。動的importでは変換済みモジュールを利用し、`with: {type: 'json'}` を検証します。Realmをまたぐ全操作の適合性確認、実行時パーサーの未対応構文、変換後に追加されたモジュールの読み込み、複数Agentの共有メモリなどは引き続き未実装です。Iterator・リソース管理の仕様全体に対する適合性検証も継続中です。

同期Iteratorの `zip`／`zipKeyed` は仕様ドラフトの `shortest`、`longest`、`strict` モードとpaddingに対応します。非同期ジェネレーターは `Symbol.asyncDispose` で終了できます。追加のTest262は同梱ハーネスで実行できるケースを選択しています。

ブロック・関数・switch内のlet／const／classの宣言前参照と、for・for…in・for…ofの束縛を拡充しました。for (let …) の初期化式・条件式・更新式・本体のクロージャーは対応する反復の束縛を保持します。未宣言識別子のtypeofも処理します。グローバル環境、非strictモード、全ての宣言競合や束縛の仕様は引き続き未完です。

固定文字列の `eval` は変換時に解析し、直接呼び出し元のスコープにアクセスするDartコードを生成します。固定文字列の `Function` は大域スコープを参照する通常関数として変換します。評価値が文字列でない `eval` は引数を返します。動的な引数・ソースで扱う構文は下記を参照してください。AsyncFunction／GeneratorFunction／AsyncGeneratorFunctionは、コンストラクターを関数式から直接取得するか、変数に代入し、固定文字列を渡す場合に変換できます。

直接evalにおける空の文・ブロック、条件分岐、ループ、switch、try/finallyの評価完了値を拡充しました。スクリプトの全構文に対する完了値の適合性は未検証です。

通常のHTMLスクリプトでは、globalThisとwindowが同じオブジェクトを指します。globalThisへのプロパティ変更はグローバル識別子に反映され、varと関数宣言は後続スクリプトと共有されます。let・const・classはグローバルオブジェクトのプロパティを作らず、後続の通常スクリプトとモジュールから参照できます。ページを読み込むたびに新しいRealmを作ります。同一文書のスクリプトは組み込みを共有し、iframeには個別のObject・Function・Promise・エラーなどを用意します。親から子の関数を呼んだ場合も関数を生成したRealmを使います。well-known SymbolとSymbol.forのレジストリは同一Agentで共有します。

`WeakRef` と `FinalizationRegistry` はDartの弱参照とファイナライザーを使用します。参照対象の回収と後始末の実行時機はDartのGCとホストに依存し、ECMAScriptのジョブ境界やGCに関わる全条件は未検証です。

## 実行時に渡すJavaScript

直接 `eval` は呼び出し元の字句環境・厳格モード・`this`・`new.target` を引き継ぎます。メソッド内の `super.prop` ではメソッドを定義したオブジェクトからプロトタイプを取得します。別名や `eval?.(...)` を経由する間接呼び出しと、文字列から作る通常の `Function` はグローバル環境を使用します。

- 通常の関数宣言・関数式、アロー関数、オブジェクトのメソッド・getter・setterを評価できます。関数宣言の巻き上げ、名前付き関数式の自己参照、デフォルト引数と残余引数、ループの各反復を捕捉するクロージャーに対応します。
- `let`・`const`・`var`、配列・オブジェクトの分割束縛と代入、計算プロパティ名、スプレッドを扱います。非strictなevalのvar・関数宣言は外側の変数環境を使用し、外側のlet等との衝突を実行前に検査します。strictなevalではこれらの宣言がeval内に留まります。
- 非strictの単純な仮引数リストでは、`arguments[0]` 等と対応する仮引数の値を同期します。添字の削除、アクセサー化、書き込み不可への変更で連動を解除します。
- `new`、`new.target`、`in`、`instanceof`、オプショナルチェーン、条件・代入・カンマ演算を扱います。`switch` のフォールスルー、ラベル付きループのbreak・continue、try/catch/finallyにも対応します。非strictの `with` では、プロパティ・外側の束縛・`Symbol.unscopables` を解決します。
- 実行時パーサーにはクラス宣言、非同期・ジェネレーター関数の生成、テンプレートリテラルなどが残っています。正規表現リテラルは式やreturnなどで扱い、スラッシュの字句解析はすべての文脈で検証していません。変換時にAcornで解析できる構文と、実行時の文字列で使える構文には差があります。

## 実行時のRegExp Unicode集合

変数に入ったパターンとフラグから `new RegExp(pattern, flags)` を生成できます。`v` の入れ子の文字クラス、積集合・差集合、`\q{...}`、絵文字列プロパティ、`iv` の補集合、長い文字列を優先する選択をDartで処理します。元のパターンが `.source` に残ります。文字プロパティ照合はDartの正規表現エンジンに依存します。文字列プロパティと単純ケースフォールディングのデータはロックファイルの版に固定し、再生成手順とライセンスを `THIRD_PARTY_NOTICES.md` に記載しました。
