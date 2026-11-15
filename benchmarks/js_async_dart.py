#!/usr/bin/env python3
"""Compile JavaScript runtime fixtures to Dart and compare with Node.js."""
import argparse
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from js_dart import compile_script
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
let done;
const finished = new Promise((resolve, reject) => { done = {resolve, reject}; });
globalThis.$DONE = error => error === undefined ? done.resolve() : done.reject(error);
'''

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    args = parser.parse_args()
    runtime = (ROOT / 'runtime/js_core.dart').read_text()
    with TemporaryDirectory(prefix='htgc-async-') as directory:
        for path in sorted((ROOT / 'benchmarks/js_async').glob('*.js')):
            source = path.read_text()
            generated = Path(directory) / (path.stem + '.dart')
            generated.write_text(runtime + '\n' + compile_script(source, path) + HARNESS)
            native = subprocess.run([args.dart, str(generated)], text=True, capture_output=True, timeout=15)
            reference = subprocess.run(['node', '--input-type=module'],
                input=NODE_HARNESS + source + '\nawait finished;\n',
                text=True, capture_output=True, timeout=15)
            if native.returncode or reference.returncode or native.stdout != reference.stdout:
                print('FAIL', path.name)
                print('Dart:', native.stdout, native.stderr)
                print('Node:', reference.stdout, reference.stderr)
                return 1
            print('PASS', path.name, native.stdout.strip())
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
        native = subprocess.run([args.dart, str(generated)], text=True,
                                capture_output=True, timeout=15)
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
