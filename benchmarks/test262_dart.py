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
from js_dart import JavaScriptSyntaxError, compile_script, parse, quote, runtime_source
from js_modules import DartModules, ModuleResolutionError


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

TEST262_HOST = r"""  JObject hostFor(JScope globals) {
    final host = JObject({'global': globals.globalThisValue});
    host.properties['createRealm'] = jBuiltin((_) => JRealm().run(() {
      final root = JScope();
      installJSBuiltins(root);
      return hostFor(JScope.script(root));
    }));
    host.properties['detachArrayBuffer'] = jBuiltin((args) {
      final buffer = jArg(args, 0);
      if (buffer is! JArrayBuffer || buffer is JSharedArrayBuffer) {
        throw JThrown(JError('TypeError', 'ArrayBuffer required'));
      }
      buffer.detach();
      return jUndefined;
    });
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
"""

ASYNC_HARNESS = r"""
Future<void> main() => runZoned(runTest,
    zoneValues: {jPromiseRejectionHook: (dynamic reason) {}});
Future<void> runTest() async {
  final scope = JScope();
  installJSBuiltins(scope);
__TEST262_HOST__
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
    "__VERIFY_UNICODE_SETS__\n", VERIFY_UNICODE_SETS).replace(
    "__TEST262_HOST__\n", TEST262_HOST)

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


def compile_module(source, path, test_root):
    modules = DartModules()
    root = test_root.resolve()
    path = path.resolve()
    key = path.relative_to(root).as_posix()

    def resolve(specifier, owner):
        target = (root / specifier.lstrip("/") if specifier.startswith("/")
                  else owner.parent / specifier).resolve()
        if not target.is_relative_to(root):
            raise CompileError(f"Module outside Test262 test tree: {target}")
        return target

    def read(path):
        try:
            return path.read_text(encoding="utf-8")
        except OSError as error:
            raise CompileError(str(error)) from error

    modules.add(source, key, path, root, read, resolve)
    return modules.emit(), f"await jAwait(scope.modules(htgcModules).evaluate({quote(key)}))"


def metadata_list(metadata, name):
    field = re.search(r"^" + re.escape(name) + r":[ \t]*\[([^\]]*)\]", metadata, re.M)
    if field:
        return [value.strip() for value in field[1].split(",") if value.strip()]
    block = re.search(r"^" + re.escape(name) + r":[ \t]*\n((?:[ \t]+-[ \t]+[^\n]+\n)+)", metadata, re.M)
    return re.findall(r"^[ \t]+-[ \t]+([^\n]+)", block[1], re.M) if block else []


def source_metadata(source):
    return source.partition("/*---")[2].partition("---*/")[0]


def discovered_cases(root, pattern):
    for path in sorted(root.rglob("*.js")):
        name = path.relative_to(root).as_posix()
        if "_FIXTURE" in path.name or not fnmatch.fnmatch(name, pattern):
            continue
        flags = metadata_list(source_metadata(path.read_text(encoding="utf-8")), "flags")
        if "module" in flags:
            yield path, "module"
        elif "raw" in flags:
            yield path, "raw"
        else:
            if "onlyStrict" not in flags:
                yield path, "sloppy"
            if "noStrict" not in flags:
                yield path, "strict"


DISCOVERED_HARNESS = r"""
Future<void> main() => runZoned(runTest,
    zoneValues: {jPromiseRejectionHook: (dynamic reason) {}});

Future<void> runTest() async {
  final root = JScope();
  installJSBuiltins(root);
  final scope = JScope.script(root);
__TEST262_HOST__
  final done = Completer<void>();
  root.defineGlobal('print', jBuiltin((args) {
    final output = jString(jArg(args, 0));
    if (output == 'Test262:AsyncTestComplete') {
      done.complete();
    } else if (output.startsWith('Test262:AsyncTestFailure:')) {
      done.completeError(StateError(output));
    } else {
      print(output);
    }
    return jUndefined;
  }));
  __SETUP__
  __EXECUTE__
  __DONE__
}
""".replace("__TEST262_HOST__\n", TEST262_HOST)


def compile_discovered(case, checkout):
    path, mode = case
    source = path.read_text(encoding="utf-8")
    metadata = source_metadata(source)
    if mode == "strict":
        source = '"use strict";\n' + source
    if not metadata:
        raise CompileError("Missing Test262 metadata")
    negative = re.search(r"^negative:[ \t]*\n((?:[ \t]+[^\n]+(?:\n|$))+)", metadata, re.M)
    expected = dict(re.findall(r"^[ \t]+(phase|type):[ \t]*(\w+)", negative[1], re.M)) if negative else {}
    phase, error_name = expected.get("phase", ""), expected.get("type", "")
    if negative and (phase not in ("parse", "early", "resolution", "runtime") or not error_name):
        raise CompileError("Unsupported Test262 negative metadata")
    source_type = "module" if mode == "module" else "script"
    if phase in ("parse", "early"):
        try:
            parse(source, path, source_type=source_type, syntax_only=True)
        except JavaScriptSyntaxError:
            if error_name == "SyntaxError":
                return None, ""
            raise
        return None, f"Parser accepted input expecting {error_name}"

    try:
        if mode == "module":
            code, call = compile_module(source, path, checkout / "test")
        else:
            code = compile_script(source, path, source_type="script")
            call = "htgcScript(scope)"
    except ModuleResolutionError:
        if phase == "resolution" and error_name == "SyntaxError":
            return None, ""
        raise
    if phase == "resolution":
        return None, f"Module resolved despite expecting {error_name}"

    flags = metadata_list(metadata, "flags")
    asynchronous = "async" in flags
    helper_code = []
    setup = []
    if mode != "raw":
        helpers = ["sta.js", "assert.js", *metadata_list(metadata, "includes")]
        if asynchronous:
            helpers.insert(2, "doneprintHandle.js")
        for index, name in enumerate(dict.fromkeys(helpers)):
            helper = checkout / "harness" / name
            function = f"htgcTestSetup{index}"
            helper_code.append(compile_script(helper.read_text(encoding="utf-8"), helper, function, source_type="script"))
            setup.append(f"{function}(scope);")
    if phase == "runtime":
        execute = (
            f"try {{ {call}; throw StateError('Expected {error_name}'); }}"
            f" on JThrown catch (error) {{ if (!identical(jGet(error.value, 'constructor'),"
            f" scope.get({quote(error_name)}))) rethrow; }}"
        )
    else:
        execute = f"{call};"
    result = DISCOVERED_HARNESS.replace("__SETUP__", "\n  ".join(setup)).replace(
        "__EXECUTE__", execute
    ).replace(
        "__DONE__", "await done.future.timeout(const Duration(seconds: 5));" if asynchronous else ""
    )
    return "\n".join([*helper_code, code, result]), ""


def execute_dart(dart, runtime, code, output, parser):
    output.write_text(runtime + "\n" + code, encoding="utf-8")
    try:
        result = subprocess.run(
            [dart, str(output)], capture_output=True, encoding="utf-8", timeout=30,
        )
    except subprocess.TimeoutExpired:
        return "FAIL", "Dart execution timed out"
    except OSError as error:
        parser.exit(2, f"Dart: {error}\n")
    return ("PASS" if result.returncode == 0 else "FAIL"), result.stderr.strip()


def report_results(cases, jobs, run_case):
    counts = {"PASS": 0, "FAIL": 0, "UNSUPPORTED": 0}
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        for status, label, details in executor.map(run_case, enumerate(cases)):
            counts[status] += 1
            print(f"{status} {label}")
            if details:
                print(details)
    print(", ".join(f"{count} {status}" for status, count in counts.items()))
    return int(counts["PASS"] != len(cases))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path, help="path to a Test262 checkout")
    parser.add_argument("--dart", default="dart", help="Dart SDK executable")
    parser.add_argument("--filter", default="*", help="test path glob")
    parser.add_argument("--jobs", type=int, default=1, help="number of concurrent Dart processes")
    parser.add_argument("--discover", action="store_true", help="discover official tests and run their declared modes")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    if args.discover:
        return run_discovered(args, parser)
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
                module_test = bool(re.search(r"^flags:\s*\[[^\]]*\bmodule\b", metadata, re.M))
                source_type = "script" if global_script and not module_test else "module"
                if re.search(r"^negative:\s*\n\s*phase:\s*parse\s*\n\s*type:\s*SyntaxError", metadata, re.M):
                    try:
                        parse(source, path, source_type=source_type)
                    except JavaScriptSyntaxError:
                        status = "PASS"
                    else:
                        status = "FAIL"
                    return status, name + " (parse phase)", ""
                if module_test:
                    code, execute = compile_module(source, path, args.checkout / "test")
                    harness = harness.replace("htgcScript(scope)", execute)
                else:
                    code = compile_script(source, path, source_type=source_type)
            except CompileError as error:
                status, details = "UNSUPPORTED", str(error)
            else:
                output = Path(temporary) / f"{index}-{path.stem}.dart"
                status, details = execute_dart(args.dart, runtime, code + harness, output, parser)
            return status, name, details

        return report_results(tests, args.jobs, run_case)


def run_discovered(args, parser):
    cases = list(discovered_cases(args.checkout / "test", args.filter))
    if not cases:
        parser.error("No Test262 cases match the requested filter")
    runtime = runtime_source()
    with TemporaryDirectory(prefix="htgc-test262-") as temporary:
        def run_case(entry):
            index, case = entry
            path, mode = case
            label = f"{path.relative_to(args.checkout / 'test').as_posix()} [{mode}]"
            try:
                code, details = compile_discovered(case, args.checkout)
            except (CompileError, OSError) as error:
                return "UNSUPPORTED", label, str(error)
            if code is None:
                return ("FAIL" if details else "PASS"), label, details
            output = Path(temporary) / f"{index}-{path.stem}.dart"
            status, details = execute_dart(args.dart, runtime, code, output, parser)
            return status, label, details

        return report_results(cases, args.jobs, run_case)


if __name__ == "__main__":
    sys.exit(main())
