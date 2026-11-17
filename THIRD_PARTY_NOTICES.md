# Third-party implementation references

Acorn 8.15.0: https://github.com/acornjs/acorn

License: MIT. Copyright (C) 2012-2022 by various contributors (see upstream AUTHORS).

HTGC's `runtime/js_runtime_eval.dart` uses Acorn's assignment, conditional and binary-expression parsing structure as an implementation reference. The Dart evaluation logic is HTGC-specific. The complete license is in `third_party/licenses/acorn-MIT.txt` and retained in generated Dart through the runtime source comment. Acorn itself is also used by the build-time JavaScript parser. This is not a claim that HTGC inherits Acorn's full syntax support or ECMAScript conformance.
