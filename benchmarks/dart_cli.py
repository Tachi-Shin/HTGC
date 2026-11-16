#!/usr/bin/env python3
"""Exercise the Dart-only public CLI, source protection and external assets."""
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]


def run(*args, success=True):
    result = subprocess.run([sys.executable, '-B', str(ROOT / 'HTGC'), *map(str, args)],
                            capture_output=True, text=True, timeout=30)
    assert (result.returncode == 0) == success, result.stderr
    return result


def main():
    help_text = run('--help').stdout
    assert '-Dart' in help_text and '-Gtk' not in help_text and '-Clang' not in help_text
    with TemporaryDirectory(prefix='htgc-cli-') as directory:
        root = Path(directory)
        entry = root / 'main.html'
        entry.write_text('<!doctype html><html><head><title>Test</title></head>'
                         '<body><p>Hello</p></body></html>')
        run(entry)
        output = entry.with_suffix('.dart')
        default = output.read_text()
        output.unlink()
        run('-Dart', entry)
        assert output.read_text() == default
        for flag in ('-Gtk', '-Clang'):
            destination = root / 'removed.c'
            run(flag, entry, '-o', destination, success=False)
            assert not destination.exists()
        image = root / 'picture.svg'
        image.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>')
        entry.write_text('''<!doctype html><html><head><title>Native</title></head><body>
<img src="picture.svg"><input oninput="saveValue(text)"><p id="answer"></p>
<script>document.getElementById('answer').textContent = String(2n ** 64n);</script>
</body></html>''')
        run(entry, '-o', output)
        source = output.read_text()
        assert "import 'htgc_handlers.dart' as handlers;" in source
        assert 'handlers.saveValue(text)' in source
        assert 'BigInt.parse("64")' in source
        assert (root / 'main.dart.assets' / image.name).read_bytes() == image.read_bytes()
        original = entry.read_bytes()
        run(entry, '-o', entry, success=False)
        assert entry.read_bytes() == original
    print('PASS Dart-only CLI: default/compatibility flags, retired targets, native handlers, external images, input protection')


if __name__ == '__main__':
    main()
