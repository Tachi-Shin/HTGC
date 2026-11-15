#!/usr/bin/env python3
"""Run a focused set of Test262 scripts after lowering them to Dart."""

import argparse
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from frontend import CompileError
from js_dart import compile_script


# Selected synchronous exception scripts and asynchronous await scripts.
TESTS = (
    "S12.14_A1.js",
    "S12.14_A2.js",
    "S12.14_A3.js",
    "S12.14_A5.js",
    "S12.14_A6.js",
    "S12.14_A8.js",
)

ASYNC_TESTS = (
    "async-await-interleaved.js", "await-awaits-thenable-not-callable.js",
    "await-awaits-thenables-that-throw.js", "await-awaits-thenables.js",
    "await-monkey-patched-promise.js", "await-non-promise-thenable.js",
    "await-non-promise.js", "await-throws-rejections.js",
)

ASYNC_HARNESS = r"""
Future<void> main() async {
  final scope = JScope();
  installJSBuiltins(scope);
  final done = Completer<void>();
  final assertFn = jNative((a) {
    if (!jTruthy(jArg(a, 0))) throw StateError('assert: ${jString(jArg(a, 1))}');
    return jUndefined;
  });
  bool same(dynamic a, dynamic b) {
    if (a is num && b is num) {
      if (a.isNaN && b.isNaN) return true;
      if (a == 0 && b == 0) return 1 / a == 1 / b;
    }
    return jBinary('===', a, b) == true;
  }
  assertFn.properties['sameValue'] = jNative((a) {
    if (!same(a[0], a[1])) throw StateError('${jString(a[0])} != ${jString(a[1])}');
    return jUndefined;
  });
  assertFn.properties['compareArray'] = jNative((a) {
    final left = a[0] as List, right = a[1] as List;
    if (left.length != right.length ||
        List.generate(left.length, (i) => same(left[i], right[i])).contains(false)) {
      throw StateError('${jString(left)} != ${jString(right)}');
    }
    return jUndefined;
  });
  scope.define('assert', assertFn);
  scope.define('Test262Error', jNative((args) => StateError(jString(jArg(args, 0)))));
  final finish = jNative((args) {
    if (done.isCompleted) throw StateError(r'$DONE called twice');
    if (identical(jArg(args, 0), jUndefined)) { done.complete(); }
    else { done.completeError(JThrown(args[0])); }
    return jUndefined;
  });
  scope.define(r'$DONE', finish);
  scope.define('asyncTest', jNative((a) {
    try { jPromiseResolve(jCall(a[0], [])).then(finish, finish); }
    catch (error) { jCall(finish, [jExceptionValue(error)]); }
    return jUndefined;
  }));
  htgcScript(scope);
  await done.future.timeout(const Duration(seconds: 5));
}
"""

HARNESS = """
void main() {
  final scope = JScope();
  installJSBuiltins(scope);
  scope.define('Test262Error', jNative((args) => StateError(jString(jArg(args, 0)))));
  htgcScript(scope);
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path, help="path to a Test262 checkout")
    parser.add_argument("--dart", default="dart", help="Dart SDK executable")
    args = parser.parse_args()
    tests = [(args.checkout / "test/language/statements/try" / name, HARNESS) for name in TESTS]
    tests += [(args.checkout / "test/language/expressions/await" / name, ASYNC_HARNESS)
              for name in ASYNC_TESTS]
    missing = [str(path) for path, _ in tests if not path.is_file()]
    if missing:
        parser.error(f"Test262 files missing: {', '.join(missing)}")
    runtime = (ROOT / "runtime/js_core.dart").read_text(encoding="utf-8")
    counts = {"PASS": 0, "FAIL": 0, "UNSUPPORTED": 0}
    with TemporaryDirectory(prefix="htgc-test262-") as temporary:
        for path, harness in tests:
            name = path.name
            try:
                code = compile_script(path.read_text(encoding="utf-8"), path)
            except CompileError as error:
                status, details = "UNSUPPORTED", str(error)
            else:
                output = Path(temporary) / f"{path.stem}.dart"
                output.write_text(runtime + "\n" + code + harness, encoding="utf-8")
                try:
                    result = subprocess.run(
                        [args.dart, str(output)], capture_output=True,
                        encoding="utf-8", timeout=30,
                    )
                    status = "PASS" if result.returncode == 0 else "FAIL"
                    details = result.stderr.strip()
                except subprocess.TimeoutExpired:
                    status, details = "FAIL", "Dart execution timed out"
                except OSError as error:
                    parser.exit(2, f"Dart: {error}\n")
            counts[status] += 1
            print(f"{status} {name}")
            if details:
                print(details)
    print(", ".join(f"{count} {status}" for status, count in counts.items()))
    return int(counts["PASS"] != len(tests))


if __name__ == "__main__":
    sys.exit(main())
