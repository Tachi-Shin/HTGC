// Check the actual app.asar, not just the staging copy.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { readFileSync } = require('node:fs');
const { createRequire } = require('node:module');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

async function main() {
  const [source, project, archive] = process.argv.slice(2).map(p => path.resolve(p));
  if (!archive) throw new Error('Usage: node assets.cjs <source-git-root> <generated-project> <app.asar>');
  const projectRequire = createRequire(path.join(project, 'package.json'));
  const asar = await import(pathToFileURL(projectRequire.resolve('@electron/asar')).href);
  const files = execFileSync('git', ['-C', source, 'ls-files', '-z']).toString().split('\0').filter(Boolean);
  assert.ok(files.length > 0);
  for (const file of files) {
    assert.deepEqual(asar.extractFile(archive, `site/${file}`), readFileSync(path.join(source, file)), file);
  }
  console.log(`PASS: all ${files.length} tracked source files are byte-identical inside app.asar.`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
