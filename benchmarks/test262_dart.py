#!/usr/bin/env python3
"""Run a focused set of Test262 scripts after lowering them to Dart."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fnmatch
from pathlib import Path
import re
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from frontend import CompileError
from js_dart import JavaScriptSyntaxError, compile_script, parse, runtime_source


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

BUILTIN_TESTS = (
    *("Map/prototype/get/" + name for name in (
        "does-not-have-mapdata-internal-slot-set.js",
        "does-not-have-mapdata-internal-slot-weakmap.js",
        "does-not-have-mapdata-internal-slot.js", "get.js", "returns-undefined.js",
        "returns-value-different-key-types.js", "returns-value-normalized-zero-key.js",
        "this-not-object-throw.js",
    )),
    *("Object/defineProperties/property-description-must-be-an-object-not-" + kind + ".js"
      for kind in ("false", "null", "number", "string", "symbol", "true", "undefined")),
)

NUMERIC_TESTS = (
    "BigInt/asIntN/arithmetic.js",
    "BigInt/asIntN/asIntN.js",
    "BigInt/asIntN/bigint-tobigint-errors.js",
    "BigInt/asIntN/bigint-tobigint-toprimitive.js",
    "BigInt/asIntN/bigint-tobigint-wrapped-values.js",
    "BigInt/asIntN/bigint-tobigint.js",
    "BigInt/asIntN/bits-toindex-errors.js",
    "BigInt/asIntN/bits-toindex-toprimitive.js",
    "BigInt/asIntN/bits-toindex-wrapped-values.js",
    "BigInt/asIntN/bits-toindex.js",
    "BigInt/asIntN/length.js",
    "BigInt/asIntN/name.js",
    "BigInt/asIntN/not-a-constructor.js",
    "BigInt/asIntN/order-of-steps.js",
    "BigInt/asUintN/arithmetic.js",
    "BigInt/asUintN/asUintN.js",
    "BigInt/asUintN/bigint-tobigint-errors.js",
    "BigInt/asUintN/bigint-tobigint-toprimitive.js",
    "BigInt/asUintN/bigint-tobigint-wrapped-values.js",
    "BigInt/asUintN/bigint-tobigint.js",
    "BigInt/asUintN/bits-toindex-errors.js",
    "BigInt/asUintN/bits-toindex-toprimitive.js",
    "BigInt/asUintN/bits-toindex-wrapped-values.js",
    "BigInt/asUintN/bits-toindex.js",
    "BigInt/asUintN/length.js",
    "BigInt/asUintN/name.js",
    "BigInt/asUintN/not-a-constructor.js",
    "BigInt/asUintN/order-of-steps.js",
    "BigInt/call-value-of-when-to-string-present.js",
    "BigInt/constructor-coercion.js",
    "BigInt/constructor-empty-string.js",
    "BigInt/constructor-from-binary-string.js",
    "BigInt/constructor-from-decimal-string.js",
    "BigInt/constructor-from-hex-string.js",
    "BigInt/constructor-from-octal-string.js",
    "BigInt/constructor-from-string-syntax-errors.js",
    "BigInt/constructor-integer.js",
    "BigInt/constructor-trailing-leading-spaces.js",
    "BigInt/infinity-throws-rangeerror.js",
    "BigInt/is-a-constructor.js",
    "BigInt/length.js",
    "BigInt/name.js",
    "BigInt/nan-throws-rangeerror.js",
    "BigInt/negative-infinity-throws.rangeerror.js",
    "BigInt/non-integer-rangeerror.js",
    "BigInt/prototype/Symbol.toStringTag.js",
    "BigInt/prototype/constructor.js",
    "BigInt/prototype/prop-desc.js",
    "BigInt/prototype/proto.js",
    "BigInt/prototype/toString/a-z.js",
    "BigInt/prototype/toString/default-radix.js",
    "BigInt/prototype/toString/length.js",
    "BigInt/prototype/toString/name.js",
    "BigInt/prototype/toString/not-a-constructor.js",
    "BigInt/prototype/toString/prop-desc.js",
    "BigInt/prototype/toString/prototype-call.js",
    "BigInt/prototype/toString/radix-2-to-36.js",
    "BigInt/prototype/toString/radix-err.js",
    "BigInt/prototype/toString/radix-tointegerorinfinity-throws-symbol.js",
    "BigInt/prototype/toString/radix-tointegerorinfinity-throws-toprimitive-or-bigint.js",
    "BigInt/prototype/toString/string-is-code-units-of-decimal-digits-only.js",
    "BigInt/prototype/toString/thisbigintvalue-not-valid-throws.js",
    "BigInt/prototype/valueOf/length.js",
    "BigInt/prototype/valueOf/name.js",
    "BigInt/prototype/valueOf/not-a-constructor.js",
    "BigInt/prototype/valueOf/prop-desc.js",
    "BigInt/prototype/valueOf/return.js",
    "BigInt/prototype/valueOf/this-value-invalid-object-throws.js",
    "BigInt/prototype/valueOf/this-value-invalid-primitive-throws.js",
    "BigInt/tostring-throws.js",
    "BigInt/valueof-throws.js",
)

VERIFY_PROPERTY = """  scope.define('verifyProperty', jNative((a) {
    final target = a[0], key = jPropertyKey(a[1]);
    final expected = a[2] as JObject, actual = jDescriptor(target, key);
    if (actual is! JObject) throw StateError('Missing own property');
    for (final name in expected.properties.keys) {
      if (!same(jGet(actual, name), expected.get(name))) throw StateError('Descriptor mismatch: $name');
    }
    return jUndefined;
  }));
"""

VERIFY_UNICODE_SETS = r"""  scope.define('testExtendedCharacterClass', jBuiltin((a) {
    final config = a[0], literal = jGet(config, 'regExp');
    final reconstructed = jNew(scope.get('RegExp'), [jGet(literal, 'source'), jGet(literal, 'flags')]);
    for (final regex in [literal, reconstructed]) {
      for (final key in ['matchStrings', 'nonMatchStrings']) {
        final inputs = jGet(config, key);
        if (key == 'nonMatchStrings' && identical(inputs, jUndefined)) continue;
        for (final value in jIterable(inputs)) {
          final matches = jInvoke(regex, 'test', [value]);
          if (matches != (key == 'matchStrings')) {
            throw StateError('Unexpected match for ${jString(value)} using ${jGet(config, 'expression')}');
          }
        }
      }
    }
    return jUndefined;
  }));
  scope.define('testPropertyOfStrings', scope.get('testExtendedCharacterClass'));
"""

ASYNC_HARNESS = r"""
Future<void> main() => runZoned(runTest,
    zoneValues: {jPromiseRejectionHook: (dynamic reason) {}});
Future<void> runTest() async {
  final scope = JScope();
  installJSBuiltins(scope);
  JObject hostFor(JScope globals) {
    final host = JObject({'global': globals.globalThisValue});
    host.properties['createRealm'] = jBuiltin((_) => JRealm().run(() {
      final root = JScope();
      installJSBuiltins(root);
      return hostFor(JScope.script(root));
    }));
    host.properties['evalScript'] = jBuiltin((args) {
      final scriptScope = globals.scriptGlobalScope;
      final parser = _RuntimeEvalParser(jString(jArg(args, 0)), scriptScope, globals.globalThisValue);
      final statements = parser.parse();
      parser.instantiate();
      return _runRuntimeStatements(statements);
    });
    globals.root.defineGlobal(r'$262', host);
    globals.root.defineGlobal('print', jGet(globals.get('console'), 'log'));
    return host;
  }
  hostFor(scope);
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
  assertFn.properties['notSameValue'] = jNative((a) {
    if (same(a[0], a[1])) throw StateError('Unexpected same value: ${jString(a[0])}');
    return jUndefined;
  });
  assertFn.properties['compareArray'] = jNative((a) {
    final left = a[0], right = a[1], length = jLength(jGet(a[0],'length'));
    if (length != jLength(jGet(right,'length')) ||
        List.generate(length, (i) => same(jGet(left,i), jGet(right,i))).contains(false)) {
      throw StateError('${jString(left)} != ${jString(right)}');
    }
    return jUndefined;
  });
  assertFn.properties['throws'] = jNative((a) {
    try { jCall(a[1], []); }
    catch (error) {
      final value = jExceptionValue(error);
      if (value is! JObject || !identical(value.get('constructor'), a[0])) {
        throw StateError('Unexpected exception: $error');
      }
      return jUndefined;
    }
    throw StateError('Expected an exception');
  });
  assertFn.properties['throwsAsync'] = jNative((a) => jAsync((promise) async {
    try {
      await jAwait(jCall(a[1], []));
      promise.reject('Expected an exception');
    } catch (error) {
      final value = jExceptionValue(error);
      if (value is JObject && identical(value.get('constructor'), a[0])) {
        promise.resolve(jUndefined);
      } else {
        promise.reject('Unexpected exception: $error');
      }
    }
  }));
__VERIFY_PROPERTY__
__VERIFY_UNICODE_SETS__
  scope.define('assert', assertFn);
  late final JFunction testError;
  testError = jNative((args) => JError('Test262Error', jString(jArg(args, 0)))..properties['constructor'] = testError);
  testError.properties['thrower'] = jBuiltin((args) => throw JThrown(jCall(testError, args)));
  scope.define('Test262Error', testError);
  // Inspect our [[Construct]] flag; this does not execute Test262's
  // Proxy/Reflect.construct-based isConstructor.js implementation.
  scope.define('isConstructor', jNative((args) => jArg(args, 0) is JFunction && (args[0] as JFunction).constructible));
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
""".replace("__VERIFY_PROPERTY__\n", VERIFY_PROPERTY).replace(
    "__VERIFY_UNICODE_SETS__\n", VERIFY_UNICODE_SETS)

BUILTIN_HARNESS = ASYNC_HARNESS.replace(
    '  await done.future.timeout(const Duration(seconds: 5));', '')

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
    parser.add_argument("--filter", default="*", help="test path glob")
    parser.add_argument("--jobs", type=int, default=1, help="number of concurrent Dart processes")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    tests = [(args.checkout / "test/language/statements/try" / name, HARNESS) for name in TESTS]
    tests += [(args.checkout / "test/language/expressions/await" / name, ASYNC_HARNESS)
              for name in ASYNC_TESTS]
    tests += [(args.checkout / "test/built-ins" / name, BUILTIN_HARNESS)
              for name in (*BUILTIN_TESTS, *NUMERIC_TESTS)]
    tests += [(args.checkout / "test" / name, BUILTIN_HARNESS)
              for name in (ROOT / 'benchmarks/test262_extended.txt').read_text().splitlines()
              if name and not name.startswith('#')]
    tests.extend((path, BUILTIN_HARNESS) for path in sorted(
        (args.checkout / "test/built-ins/RegExp/unicodeSets/generated").glob("*.js")))
    tests.extend((path, BUILTIN_HARNESS) for path in sorted(
        (args.checkout / "test/language/statements/with").glob("*.js")))
    tests = [(path, harness) for path, harness in tests
             if fnmatch.fnmatch(str(path.relative_to(args.checkout / 'test')), args.filter)]
    if not tests:
        parser.error("No Test262 cases match the requested filter")
    missing = [str(path) for path, _ in tests if not path.is_file()]
    if missing:
        parser.error(f"Test262 files missing: {', '.join(missing)}")
    runtime = runtime_source()
    counts = {"PASS": 0, "FAIL": 0, "UNSUPPORTED": 0}
    with TemporaryDirectory(prefix="htgc-test262-") as temporary:
        def run_case(entry):
            index, (path, harness) = entry
            name = str(path.relative_to(args.checkout / 'test'))
            try:
                source = path.read_text(encoding="utf-8")
                metadata = source.partition("/*---")[2].partition("---*/")[0]
                selected_helpers = set()
                helpers = ["promiseHelper.js", "proxyTrapsHelper.js", "compareIterator.js"]
                if not name.startswith("built-ins/RegExp/unicodeSets/generated/"):
                    helpers.append("regExpUtils.js")
                if name.startswith(("built-ins/Array/", "built-ins/Symbol/", "built-ins/Object/prototype/__")):
                    helpers.extend(("propertyHelper.js", "temporalHelpers.js"))
                for helper in helpers:
                    if re.search(r"^includes:.*\b" + re.escape(helper) + r"\b", metadata, re.M):
                        source = (args.checkout / "harness" / helper).read_text(encoding="utf-8") + "\n" + source
                        selected_helpers.add(helper)
                negative = re.search(r"^negative:\s*\n\s*phase:\s*runtime\s*\n\s*type:\s*(\w+)", metadata, re.M)
                if negative:
                    expected = negative.group(1)
                    harness = harness.replace(
                        '  htgcScript(scope);',
                        '  try { htgcScript(scope); throw StateError("Expected exception"); } '
                        'on JThrown catch (error) { '
                        f'if (jGet(error.value, "name") != "{expected}") rethrow; }}',
                    )
                if harness == BUILTIN_HARNESS and re.search(r"^flags:\s*\[[^\]]*\basync\b", metadata, re.M):
                    harness = ASYNC_HARNESS
                global_script = name.startswith((
                    "language/global-code/decl-", "built-ins/global/", "language/eval-code/",
                    "language/arguments-object/", "language/statements/with/", "built-ins/Array/", "built-ins/Symbol/",
                )) or name in ("built-ins/WeakRef/prop-desc.js", "built-ins/FinalizationRegistry/prop-desc.js")
                global_script |= bool(re.search(r"^flags:\s*\[[^\]]*\bnoStrict\b", metadata, re.M))
                if global_script:
                    harness = harness.replace(
                        '  final scope = JScope();\n  installJSBuiltins(scope);',
                        '  final root = JScope();\n  installJSBuiltins(root);\n  final scope = JScope.script(root);',
                    )
                if global_script and re.search(r"^flags:\s*\[[^\]]*\bonlyStrict\b", metadata, re.M):
                    source = '"use strict";\n' + source
                if "propertyHelper.js" in selected_helpers:
                    harness = harness.replace(VERIFY_PROPERTY, "")
                if "regExpUtils.js" in selected_helpers:
                    harness = harness.replace(VERIFY_UNICODE_SETS, "")
                source_type = "script" if global_script else "module"
                if re.search(r"^negative:\s*\n\s*phase:\s*parse\s*\n\s*type:\s*SyntaxError", metadata, re.M):
                    try:
                        parse(source, path, source_type=source_type)
                    except JavaScriptSyntaxError:
                        status = "PASS"
                    else:
                        status = "FAIL"
                    return status, name + " (parse phase)", ""
                code = compile_script(source, path, source_type=source_type)
            except CompileError as error:
                status, details = "UNSUPPORTED", str(error)
            else:
                output = Path(temporary) / f"{index}-{path.stem}.dart"
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
            return status, name, details

        with ThreadPoolExecutor(max_workers=args.jobs) as executor:
            for status, name, details in executor.map(run_case, enumerate(tests)):
                counts[status] += 1
                print(f"{status} {name}")
                if details:
                    print(details)
    print(", ".join(f"{count} {status}" for status, count in counts.items()))
    return int(counts["PASS"] != len(tests))


if __name__ == "__main__":
    sys.exit(main())
