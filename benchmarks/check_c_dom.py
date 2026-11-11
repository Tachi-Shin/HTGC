"""Compile and execute the benchmark's generated C DOM and compare its text."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

import cssselect2
import html5lib

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from native_c import generate


def document(executable, page, theme, clicks=0):
    markup = subprocess.check_output(
        [str(executable), page, theme, str(clicks)], encoding="utf-8"
    )
    root = html5lib.parse(markup, namespaceHTMLElements=False)
    return cssselect2.ElementWrapper.from_html_root(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site", type=Path)
    parser.add_argument("reference", type=Path)
    args = parser.parse_args()
    reference = json.loads(args.reference.read_text(encoding="utf-8"))
    code, site = generate(
        args.site / "index.html", graphics=False, includes=("contact.html",)
    )
    harness = Path(__file__).with_name("c_dom_probe.inc").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "portfolio.c"
        executable = source.with_suffix("")
        source.write_text(code + harness, encoding="utf-8")
        flags = subprocess.check_output(
            ["pkg-config", "--cflags", "--libs", "glib-2.0", "libxml-2.0"], text=True
        )
        command = shlex.split(os.environ.get("CC", "cc"))
        subprocess.run(
            [
                *command,
                "-std=c11",
                "-Wall",
                "-Wextra",
                "-Werror",
                str(source),
                "-o",
                str(executable),
                *shlex.split(flags),
                "-lm",
            ],
            check=True,
        )
        if set(site.pages) != set(reference["content"]):
            raise AssertionError("Generated page list differs from the reference")
        for page, contents in reference["content"].items():
            root = document(executable, page, reference["theme"])
            for selector, expected in contents.items():
                actual = [
                    " ".join("".join(item.etree_element.itertext()).split())
                    for item in root.query_all(selector)
                ]
                if actual != expected:
                    raise AssertionError(f"{page}: content differs at {selector}")
            print(f"{page}: generated C content matches")
        for clicks, mode in enumerate(("dark", "auto", "light", "dark")):
            root = document(executable, "index.html", "dark", clicks)
            if root.etree_element.get("data-theme") != mode:
                raise AssertionError(f"Theme after {clicks} clicks differs")
        print("Generated C theme cycle matches")


if __name__ == "__main__":
    main()
