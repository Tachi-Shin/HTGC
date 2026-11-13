#!/usr/bin/env python3
"""Generate Flutter fixtures from the CSS cascade-layer Web Platform Test."""

import argparse
from pathlib import Path
import re
import sys
from tempfile import TemporaryDirectory

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from native_dart import generate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wpt", type=Path, help="path to layer-basic.html")
    parser.add_argument("output", type=Path, help="generated Dart file")
    args = parser.parse_args()
    source = args.wpt.read_text(encoding="utf-8")
    cases = re.findall(r"title:\s*'([^']+)',\s*style:\s*`([^`]*)`", source)
    if len(cases) != 34 or "rgb(0, 128, 0)" not in source:
        parser.error("unexpected WPT layer-basic.html fixture")
    with TemporaryDirectory(prefix="htgc-wpt-") as directory:
        root = Path(directory)
        links = []
        for i, (_, css) in enumerate(cases):
            filename = f"case-{i}.html"
            links.append(f'<a href="{filename}">{i}</a>')
            (root / filename).write_text(
                "<!doctype html><style>" + css + "</style>"
                '<target class="first"></target><target class="second"></target>',
                encoding="utf-8",
            )
        entry = root / "index.html"
        entry.write_text("<!doctype html>" + "".join(links), encoding="utf-8")
        dart, _ = generate(entry)
    args.output.write_text(dart, encoding="utf-8")


if __name__ == "__main__":
    main()
