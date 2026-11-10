"""Package a static web root with Chromium using Electron."""

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from frontend import CompileError

ELECTRON_VERSION = "45.2.3"
PACKAGER_VERSION = "20.3.0"
EXCLUDED = {".git", ".hg", ".svn", "node_modules", "__pycache__", ".venv", "venv", ".DS_Store"}

RUNTIME = r"""
const { app, BrowserWindow, protocol, net, shell } = require('electron');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const config = require('./htgc.json');

protocol.registerSchemesAsPrivileged([{
  scheme: 'htgc',
  privileges: { standard: true, secure: true, supportFetchAPI: true,
                corsEnabled: true, stream: true, allowServiceWorkers: true },
}]);

const origin = 'htgc://app';
const root = path.join(__dirname, 'site');
const entry = origin + '/' + config.entry.split('/').map(encodeURIComponent).join('/');

function localURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'htgc:' && url.host === 'app';
  } catch {
    return false;
  }
}

function openExternal(value) {
  if (['https:', 'http:', 'mailto:', 'tel:'].includes(new URL(value).protocol)) {
    shell.openExternal(value).catch(console.error);
  }
}

function createWindow(url = entry) {
  const window = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: { nodeIntegration: false, contextIsolation: true, sandbox: true },
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (localURL(url)) createWindow(url);
    else openExternal(url);
    return { action: 'deny' };
  });
  window.webContents.on('will-navigate', (event, url) => {
    if (!localURL(url)) {
      event.preventDefault();
      openExternal(url);
    }
  });
  window.loadURL(url).catch(console.error);
  return window;
}

app.whenReady().then(() => {
  protocol.handle('htgc', async (request) => {
    const url = new URL(request.url);
    if (!localURL(request.url)) return new Response('Not found', { status: 404 });
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response('This bundled site has no server-side request handler.', { status: 405 });
    }
    try {
      const pathname = decodeURIComponent(url.pathname);
      if (pathname.includes('\\') || pathname.includes('\0')) {
        return new Response('Invalid path', { status: 400 });
      }
      let file = path.resolve(root, '.' + pathname);
      if (file !== root && !file.startsWith(root + path.sep)) {
        return new Response('Not found', { status: 404 });
      }
      if ((await fs.stat(file)).isDirectory()) {
        if (!url.pathname.endsWith('/')) {
          url.pathname += '/';
          return Response.redirect(url.href, 301);
        }
        file = path.join(file, 'index.html');
      }
      return await net.fetch(pathToFileURL(file).href, { method: request.method });
    } catch {
      return new Response('Not found', { status: 404 });
    }
  });
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
}).catch((error) => {
  console.error(error);
  app.exit(1);
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
""".lstrip()


def generate(entry, output, root=None, build=False):
    entry = entry.resolve(strict=True)
    root = (root or entry.parent).resolve(strict=True)
    output = output.resolve()
    if not entry.is_file() or not root.is_dir() or not entry.is_relative_to(root):
        raise CompileError("入力HTMLは --root で指定したディレクトリ内に置いてください")
    if output.exists():
        raise CompileError(f"{output}: 出力先が既にあります。別の空いているパスを指定してください")
    if root.is_relative_to(output):
        raise CompileError("出力先には入力ルートやその親ディレクトリを指定できません")
    output.parent.mkdir(parents=True, exist_ok=True)
    npm = shutil.which("npm")
    if build and npm is None:
        raise CompileError("--build には Node.js と npm が必要です")

    with tempfile.TemporaryDirectory(prefix=".htgc-", dir=output.parent) as temporary:
        staging = Path(temporary)

        def ignore(directory, names):
            skipped = []
            for name in names:
                item = Path(directory) / name
                if name in EXCLUDED or item in (staging, output):
                    skipped.append(name)
                elif item.is_symlink():
                    raise CompileError(f"{item}: 配布するファイルはシンボリックリンクを実体化してください")
            return skipped

        shutil.copytree(root, staging / "site", ignore=ignore)
        relative_entry = entry.relative_to(root).as_posix()
        if not (staging / "site" / relative_entry).is_file():
            raise CompileError("入力HTMLが配布対象から除外されています")
        package = {
            # Electron uses the package name for its persistent user-data directory.
            # Give different entry points separate cookies/localStorage by default.
            "name": "htgc-" + hashlib.sha256(str(entry).encode("utf-8")).hexdigest()[:20],
            "version": "1.0.0",
            "private": True,
            "engines": {"node": ">=22.12.0"},
            "main": "main.cjs",
            "scripts": {
                "start": "electron .",
                "build": "electron-packager . HTGC-Web --out=dist --asar --overwrite",
            },
            "devDependencies": {
                "electron": ELECTRON_VERSION,
                "@electron/packager": PACKAGER_VERSION,
            },
        }
        (staging / "package.json").write_text(json.dumps(package, indent=2) + "\n", encoding="utf-8")
        (staging / "htgc.json").write_text(json.dumps({"entry": relative_entry}) + "\n", encoding="utf-8")
        (staging / "main.cjs").write_text(RUNTIME, encoding="utf-8")
        staging.rename(output)

    if build:
        for arguments in (["install"], ["run", "build"]):
            result = subprocess.run([npm, *arguments], cwd=output, check=False)
            if result.returncode:
                raise CompileError(f"npm {' '.join(arguments)} が終了コード {result.returncode} で失敗しました。生成済みプロジェクト: {output}")
    return output
