#!/usr/bin/env python3
"""Check embedded-document discovery, asset paths and explicit unsupported inputs."""
from pathlib import Path
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from frontend import CompileError
from native_dart import generate


def main():
    with TemporaryDirectory(prefix='htgc-embedded-') as directory:
        root = Path(directory)
        (root / 'nested').mkdir()
        files = {
            'index.html': '''<!doctype html><iframe src="nested/child.html"></iframe>
              <iframe src="absent.html" srcdoc="&lt;p&gt;inline&lt;/p&gt;&lt;img src='picture.svg'&gt;"></iframe>
              <object data="picture.svg"></object><embed src="picture.svg">''',
            'nested/child.html': '<link rel="stylesheet" href="child.css"><p>child</p><script src="child.js"></script><iframe src="../index.html"></iframe>',
            'nested/child.css': 'p { color: blue; }',
            'nested/child.js': "document.querySelector('p').textContent = 'compiled child';",
            'picture.svg': '<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"></svg>',
            'unreferenced.html': '<audio src="not-selected.mp3"></audio>',
        }
        for path, content in files.items():
            (root / path).write_text(content)
        generated, site = generate(root / 'index.html')
        assert site.inputs == {root / path for path in files if path != 'unreferenced.html'}
        assert set(site.assets) == {'picture.svg'}
        assert len(site.pages) == 4  # entry, child, srcdoc, about:blank
        assert len(site.scripts) == 1
        assert 'compiled child' in generated
        inline = [page for key, page in site.pages.items() if '#htgc-srcdoc-' in key]
        assert len(inline) == 1 and inline[0]['base'] == 'index.html'
        for source, message in (
            ('<iframe src="https://example.com/frame.html"></iframe>', 'ローカル入力'),
            ('<iframe sandbox src="nested/child.html"></iframe>', 'sandbox'),
            ('<iframe credentialless src="nested/child.html"></iframe>', 'credentialless'),
            ('<video src="clip.mp4"></video>', 'video'),
        ):
            (root / 'unsupported.html').write_text(source)
            try:
                generate(root / 'unsupported.html')
            except CompileError as error:
                assert message in str(error), str(error)
            else:
                raise AssertionError('Unsupported input silently accepted: ' + source)
    print('PASS embedded document discovery and diagnostics')


if __name__ == '__main__':
    main()
