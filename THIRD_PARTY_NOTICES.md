# Third-party implementation references

Acorn 8.15.0: https://github.com/acornjs/acorn

License: MIT. Copyright (C) 2012-2022 by various contributors (see upstream AUTHORS).

HTGC's `runtime/js_runtime_eval.dart` uses Acorn's assignment, conditional and binary-expression parsing structure as an implementation reference. The Dart evaluation logic is HTGC-specific. The complete license is in `third_party/licenses/acorn-MIT.txt` and retained in generated Dart through the runtime source comment. Acorn itself is also used by the build-time JavaScript parser. This is not a claim that HTGC inherits Acorn's full syntax support or ECMAScript conformance.

## Runtime Unicode regular-expression sets

The runtime set operations follow ECMA-262's ClassSetExpression and CompileToCharSet algorithms. The code-point and string representation was informed by [regexpu-core](https://github.com/mathiasbynens/regexpu-core). The data generator reads its simple case-folding table and the emoji data from [regenerate-unicode-properties](https://github.com/mathiasbynens/regenerate-unicode-properties). Both packages carry the MIT license, copyright Mathias Bynens. See [the MIT notice](third_party/licenses/regexpu-MIT.txt) and [Unicode License v3](runtime/UNICODE-LICENSE.txt). Both notices are included in the generated Dart data. To regenerate it with the repository's pinned dependencies, run `npm --prefix javascript ci` followed by `node tools/generate_regexp_sets.cjs`.
