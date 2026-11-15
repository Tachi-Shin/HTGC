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


# These synchronous scripts only need Test262Error from the harness.
TESTS = (
    "S12.14_A1.js",
    "S12.14_A2.js",
    "S12.14_A3.js",
    "S12.14_A5.js",
    "S12.14_A6.js",
    "S12.14_A8.js",
)

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
    tests = args.checkout / "test/language/statements/try"
    missing = [name for name in TESTS if not (tests / name).is_file()]
    if missing:
        parser.error(f"Test262 files missing in {tests}: {', '.join(missing)}")
    runtime = (ROOT / "runtime/js_core.dart").read_text(encoding="utf-8")
    counts = {"PASS": 0, "FAIL": 0, "UNSUPPORTED": 0}
    with TemporaryDirectory(prefix="htgc-test262-") as temporary:
        for name in TESTS:
            path = tests / name
            try:
                code = compile_script(path.read_text(encoding="utf-8"), path)
            except CompileError as error:
                status, details = "UNSUPPORTED", str(error)
            else:
                output = Path(temporary) / f"{path.stem}.dart"
                output.write_text(runtime + "\n" + code + HARNESS, encoding="utf-8")
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
    return int(counts["PASS"] != len(TESTS))


if __name__ == "__main__":
    sys.exit(main())
