// Exercise the generated protocol with paths not present in the portfolio fixture.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron } = require('playwright');

async function main() {
  const builtProject = process.argv[2];
  if (!builtProject) throw new Error('Usage: node runtime.cjs <generated project with npm dependencies> [Electron flags]');
  const executablePath = require(path.resolve(builtProject, 'node_modules/electron'));
  const temporary = await fs.mkdtemp(path.join(os.tmpdir(), 'htgc-runtime-'));
  const root = path.join(temporary, 'site');
  const project = path.join(temporary, 'project');
  let app;
  try {
    const files = {
      'pages/start 日本語.html': '<meta charset="utf-8"><script type="module" src="/module.js"></script><a id="docs" href="/docs?query=kept">Docs</a>',
      'module.js': `const {value} = await import('/chunks/lazy.js');
        const data = await (await fetch('/data/日本語.json?query=yes')).json();
        document.body.dataset.result = value + data.value;`,
      'chunks/lazy.js': 'export const value = "ES modules: ";',
      'data/日本語.json': JSON.stringify({ value: '日本語のfetch成功' }),
      'docs/index.html': '<a id="next" href="next.html">Next</a>',
      'docs/next.html': '<h1>Next page</h1>',
    };
    for (const [name, content] of Object.entries(files)) {
      const file = path.join(root, name);
      await fs.mkdir(path.dirname(file), { recursive: true });
      await fs.writeFile(file, content);
    }
    execFileSync(process.env.PYTHON || 'python3', [path.resolve(__dirname, '../HTGC'),
      '-Web', path.join(root, 'pages/start 日本語.html'), '--root', root, '-o', project]);
    app = await electron.launch({
      executablePath: path.resolve(executablePath),
      args: [project, `--user-data-dir=${path.join(temporary, 'profile')}`, ...process.argv.slice(3)],
    });
    const page = await app.firstWindow();
    await page.waitForFunction(() => document.body.dataset.result === 'ES modules: 日本語のfetch成功');
    assert.equal(await page.evaluate(() => typeof require), 'undefined');
    assert.equal(await page.evaluate(() => typeof process), 'undefined');
    const responses = await page.evaluate(async () => {
      const paths = ['/missing.html', '/%2e%2e%2fpackage.json', '/%5c..%5cpackage.json', '/%00', '/bad%xx'];
      const statuses = await Promise.all(paths.map(async url => (await fetch(url)).status));
      const post = await fetch('/docs/', { method: 'POST', body: 'not submitted' });
      const head = await fetch('/docs/index.html', { method: 'HEAD' });
      return { statuses, post: post.status, head: head.status, headBody: await head.text() };
    });
    assert.deepEqual(responses, { statuses: [404, 404, 400, 400, 404], post: 405, head: 200, headBody: '' });
    await page.locator('#docs').click();
    await page.waitForURL('htgc://app/docs/?query=kept');
    await page.locator('#next').click();
    await page.waitForURL('htgc://app/docs/next.html');
    assert.equal(await page.locator('h1').innerText(), 'Next page');
    console.log('PASS: Unicode entry/assets, absolute paths, dynamic import, fetch/query, HEAD, directory redirect, relative navigation, missing/invalid paths, POST rejection, no renderer Node APIs.');
  } finally {
    if (app) await app.close();
    await fs.rm(temporary, { recursive: true, force: true });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
