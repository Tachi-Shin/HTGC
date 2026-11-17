#!/usr/bin/env python3
"""Compare global declaration and cross-script behavior against Node's vm."""
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from js_dart import compile_script, runtime_source

SCRIPTS = [
    'var shared=1; let lexical=2; function sum(){return shared+lexical}; console.log(this===globalThis);',
    'globalThis.shared=3; console.log(sum(), lexical, globalThis.lexical, globalThis.sum===sum);',
    'globalThis.external=4; external+=2; console.log(globalThis.external);',
    'console.log(Function("return lexical")());',
    'let lexical=9;',
    'var lexical=9;',
    'let undefined;',
    'let Array=7; console.log(Array, typeof globalThis.Array);',
    'console.log(sum(), globalThis.shared, lexical);',
]

def main():
    dart = sys.argv[1] if len(sys.argv) > 1 else 'dart'
    compiled = [compile_script(source, str(i), name=f'script{i}', source_type='script')
                for i, source in enumerate(SCRIPTS)]
    calls = '\n'.join(
        f'try {{ script{i}(scope); }} on JThrown catch (error) {{ print(jGet(error.value, "name")); }}'
        for i in range(len(SCRIPTS)))
    main_dart = f'''void main() {{
      final root = JScope();
      installJSBuiltins(root);
      final scope = JScope.script(root);
      {calls}
    }}'''
    node = 'const vm = require("node:vm"); const ctx=vm.createContext({console});\n'
    node += '\n'.join(
        f'try {{ vm.runInContext({json.dumps(source)}, ctx); }} catch (error) {{ console.log(error.name); }}'
        for source in SCRIPTS)
    with TemporaryDirectory(prefix='htgc-globals-') as directory:
        path = Path(directory) / 'globals.dart'
        path.write_text(runtime_source() + '\n' + '\n'.join(compiled) + main_dart)
        actual = subprocess.run([dart, str(path)], capture_output=True, text=True, timeout=30)
        reference = subprocess.run(['node'], input=node, capture_output=True, text=True, timeout=30)
        if actual.returncode or reference.returncode or actual.stdout != reference.stdout:
            print('FAIL global scripts\nDart:', actual.stdout, actual.stderr,
                  '\nNode:', reference.stdout, reference.stderr)
            return 1
        print('PASS global scripts')
    return 0

if __name__ == '__main__':
    sys.exit(main())
