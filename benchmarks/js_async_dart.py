#!/usr/bin/env python3
"""Compile JavaScript runtime fixtures to Dart and compare with Node.js."""
import argparse
import fnmatch
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from js_dart import compile_script, runtime_source
from js_modules import DartModules

HARNESS = '''
Future<void> main() async {
  final scope = JScope();
  installJSBuiltins(scope);
  final done = Completer<void>();
  scope.define(r'$DONE', jNative((args) {
    if (done.isCompleted) throw StateError(r'$DONE called twice');
    final error = jArg(args, 0);
    if (identical(error, jUndefined)) { done.complete(); }
    else { done.completeError(JThrown(error)); }
    return jUndefined;
  }));
  htgcScript(scope);
  await done.future.timeout(const Duration(seconds: 5));
}
'''
NODE_HARNESS = '''
// Atomics.waitAsync timeouts do not keep the Node event loop alive.
const keepAlive = setTimeout(() => { throw new Error('Fixture did not finish'); }, 5000);
let done;
const finished = new Promise((resolve, reject) => { done = {resolve, reject}; });
globalThis.$DONE = error => error === undefined ? done.resolve() : done.reject(error);
'''

def run_generated(path, args):
    command = [args.dart, str(path)]
    if args.aot:
        executable = path.with_suffix('.exe')
        compiled = subprocess.run(
            [args.dart, 'compile', 'exe', str(path), '-o', str(executable)],
            text=True, capture_output=True, timeout=90)
        if compiled.returncode:
            return compiled
        command = [str(executable)]
    return subprocess.run(command, text=True, capture_output=True, timeout=15)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    parser.add_argument('--filter', default='*', help='fixture filename glob (or modules)')
    parser.add_argument('--aot', action='store_true', help='compile and run standalone executables')
    args = parser.parse_args()
    runtime = runtime_source()
    with TemporaryDirectory(prefix='htgc-async-') as directory:
        for path in sorted((ROOT / 'benchmarks/js_async').glob('*.js')):
            if not fnmatch.fnmatch(path.name, args.filter):
                continue
            source = path.read_text()
            generated = Path(directory) / (path.stem + '.dart')
            generated.write_text(runtime + '\n' + compile_script(source, path) + HARNESS)
            native = run_generated(generated, args)
            reference = subprocess.run(['node', '--input-type=module'],
                input=NODE_HARNESS + source + '\ntry { await finished; } finally { clearTimeout(keepAlive); }\n',
                text=True, capture_output=True, timeout=15)
            if native.returncode or reference.returncode or native.stdout != reference.stdout:
                print('FAIL', path.name)
                print('Dart:', native.stdout, native.stderr)
                print('Node:', reference.stdout, reference.stderr)
                return 1
            print('PASS', path.name, native.stdout.strip())
        if not fnmatch.fnmatch('modules', args.filter):
            return 0
        root = ROOT / 'benchmarks/js_async/modules'
        modules = DartModules()
        path = root / 'main.mjs'
        def local(specifier, owner):
            target = (root / specifier.lstrip('/') if specifier.startswith('/')
                      else owner.parent / specifier).resolve()
            if not target.is_relative_to(root):
                raise ValueError(f'Outside fixture root: {specifier}')
            return target
        modules.add(path.read_text(), 'main.mjs', path, root,
                    lambda p: p.read_text(), local)
        generated = Path(directory) / 'modules.dart'
        generated.write_text(runtime + modules.emit() + """
Future<void> main() async {
  final scope = JScope();
  installJSBuiltins(scope);
  await jAwait(scope.modules(htgcModules).evaluate('main.mjs'))
      .timeout(const Duration(seconds: 5));
}
""")
        native = run_generated(generated, args)
        reference = subprocess.run(['node', str(path)], text=True,
                                   capture_output=True, timeout=15)
        if native.returncode or reference.returncode or native.stdout != reference.stdout:
            print('FAIL modules')
            print('Dart:', native.stdout, native.stderr)
            print('Node:', reference.stdout, reference.stderr)
            return 1
        print('PASS modules', native.stdout.strip())
    return 0

if __name__ == '__main__':
    sys.exit(main())
