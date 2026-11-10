import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import backend_web
from frontend import CompileError


class WebPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        self.entry = self.root / "index.html"
        self.entry.write_text('<script type="module" src="app.js"></script>', encoding="utf-8")
        (self.root / "app.js").write_text('document.body.textContent = "動いた";', encoding="utf-8")

    def test_copy_whole_root_without_changing_source_bytes(self):
        (self.root / "assets").mkdir()
        (self.root / "assets" / "日本語 image.bin").write_bytes(bytes(range(256)))
        (self.root / "unlinked.html").write_text("<h1>Unlinked page</h1>")
        (self.root / ".htgc-user-file").write_text("a real asset")
        for name in backend_web.EXCLUDED:
            (self.root / name).mkdir()
            (self.root / name / "ignored").write_text("do not ship")
        expected = {p.relative_to(self.root): p.read_bytes()
                    for p in self.root.rglob("*") if p.is_file()
                    and not any(part in backend_web.EXCLUDED for part in p.relative_to(self.root).parts)}
        # Default output can live inside the source root; staging must not copy itself.
        output = backend_web.generate(self.entry, self.root / "index.web")
        actual = {p.relative_to(output / "site"): p.read_bytes()
                  for p in (output / "site").rglob("*") if p.is_file()}
        self.assertEqual(expected, actual)
        for name, data in expected.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        self.assertEqual(json.loads((output / "htgc.json").read_text()), {"entry": "index.html"})

    def test_nested_entry_and_explicit_root(self):
        (self.root / "pages").mkdir()
        entry = self.root / "pages" / "日本語 page.html"
        entry.write_text('<script src="/app.js"></script>')
        output = backend_web.generate(entry, self.base / "app", self.root)
        self.assertEqual(json.loads((output / "htgc.json").read_text())["entry"], "pages/日本語 page.html")
        self.assertTrue((output / "site" / "app.js").is_file())

    def test_app_identity_is_stable_and_separates_entry_points(self):
        first = backend_web.generate(self.entry, self.base / "first")
        rebuilt = backend_web.generate(self.entry, self.base / "rebuilt")
        other = self.root / "other.html"
        other.write_text("<h1>Other app</h1>")
        separate = backend_web.generate(other, self.base / "separate")
        names = [json.loads((p / "package.json").read_text())["name"] for p in (first, rebuilt, separate)]
        self.assertEqual(names[0], names[1])
        self.assertNotEqual(names[0], names[2])

    def test_reject_entry_outside_root(self):
        other = self.base / "other"
        other.mkdir()
        with self.assertRaises(CompileError):
            backend_web.generate(self.entry, self.base / "app", other)
        self.assertFalse((self.base / "app").exists())

    def test_never_overwrite_existing_output(self):
        output = self.base / "app"
        output.mkdir()
        sentinel = output / "keep.txt"
        sentinel.write_text("keep")
        with self.assertRaises(CompileError):
            backend_web.generate(self.entry, output)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_reject_symlink_without_partial_output(self):
        secret = self.base / "outside.txt"
        secret.write_text("outside")
        try:
            (self.root / "link.txt").symlink_to(secret)
        except OSError:
            self.skipTest("Symlinks unavailable")
        with self.assertRaises(CompileError):
            backend_web.generate(self.entry, self.base / "app")
        self.assertFalse((self.base / "app").exists())
        self.assertEqual(list(self.base.glob(".htgc-*")), [])

    def test_build_failure_keeps_project_for_retry(self):
        with patch.object(backend_web.shutil, "which", return_value="npm"), \
                patch.object(backend_web.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run:
            with self.assertRaisesRegex(CompileError, "終了コード 1"):
                backend_web.generate(self.entry, self.base / "app", build=True)
            self.assertEqual(run.call_count, 1)
        self.assertTrue((self.base / "app" / "main.cjs").is_file())

    def test_missing_npm_fails_before_generation(self):
        with patch.object(backend_web.shutil, "which", return_value=None):
            with self.assertRaisesRegex(CompileError, "npm"):
                backend_web.generate(self.entry, self.base / "app", build=True)
        self.assertFalse((self.base / "app").exists())

    def test_cli_rejects_web_options_for_native_target(self):
        cli = Path(__file__).resolve().parents[1] / "HTGC"
        result = subprocess.run([sys.executable, str(cli), "-Gtk", str(self.entry), "--build"], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.entry.with_suffix(".gtk.c").exists())


if __name__ == "__main__":
    unittest.main()
