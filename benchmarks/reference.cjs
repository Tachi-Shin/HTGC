// Capture the unchanged benchmark site. Chromium is a test dependency only.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const http = require('node:http');
const path = require('node:path');

const mime = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml',
  '.jpg': 'image/jpeg', '.png': 'image/png', '.webmanifest': 'application/manifest+json',
};
const pages = ['index.html', 'projects.html', 'about.html', 'contact.html'];
const contentSelectors = ['site-header nav', '#news-list li', '#timeline .tl-card', 'site-footer small'];
const selectors = ['header.site', 'nav', '.nav__brand', '.nav__links', '#themeToggle',
  'main', '.hero', '.hero__inner', '.hero__title', '.hero__subtitle', '.hero__cta',
  '.hero__inner .logo', '.bg-band--top', '.bg-band--bottom', '.bg-track--left img',
  '.bg-track--right img', '.affiliation', '.affiliation .qcard', '#highlights',
  '.prose h1', '#os', '#os .card', '#web', '.skills', '#timeline .tl-card',
  'form.contact', 'input:not([type=hidden])', 'textarea', 'footer.site'];

async function main() {
  const [source, output, widthText = '1280', heightText = '720', theme = 'dark'] = process.argv.slice(2);
  const width = Number(widthText), height = Number(heightText);
  if (!source || !output || !Number.isSafeInteger(width) || !Number.isSafeInteger(height)
      || width < 1 || height < 1 || !['light', 'dark', 'auto'].includes(theme)) {
    throw new Error('Usage: node reference.cjs SITE OUTPUT [WIDTH HEIGHT THEME]');
  }
  const root = await fs.realpath(source);
  await fs.mkdir(output, { recursive: true });
  const server = http.createServer(async (request, response) => {
    try {
      const relative = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
      const file = await fs.realpath(path.resolve(root, `.${relative}`));
      if (!file.startsWith(root + path.sep) || request.method !== 'GET') {
        response.writeHead(404).end();
        return;
      }
      const bytes = await fs.readFile(file);
      response.writeHead(200, { 'Content-Type': mime[path.extname(file).toLowerCase()] || 'application/octet-stream' });
      response.end(bytes);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const origin = `http://127.0.0.1:${server.address().port}`;
  let browser;
  try {
    browser = await chromium.launch({ executablePath: process.env.HTGC_REFERENCE_CHROMIUM });
    const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1,
      colorScheme: 'light', reducedMotion: 'reduce', locale: 'ja-JP' });
    await context.route('**/*', route => new URL(route.request().url()).origin === origin
      ? route.continue() : route.abort());
    await context.addInitScript(value => localStorage.setItem('theme', value), theme);
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    const results = {};
    const content = {};
    for (const name of pages) {
      await page.goto(`${origin}/${name}`);
      await page.waitForSelector('site-header nav');
      await page.evaluate(async () => {
        await document.fonts.ready;
        await Promise.all([...document.images].map(image => image.decode()));
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      });
      results[name] = await page.evaluate(queries => Object.fromEntries(queries.flatMap(selector => {
        const element = document.querySelector(selector);
        if (!element) return [];
        const { x, y, width, height } = element.getBoundingClientRect();
        const css = getComputedStyle(element);
        return [[selector, { x, y, width, height, color: css.color,
          backgroundColor: css.backgroundColor, font: css.font, display: css.display }]];
      })), selectors);
      content[name] = await page.evaluate(queries => Object.fromEntries(queries.map(selector => [
        selector, [...document.querySelectorAll(selector)].map(element => element.textContent.replace(/\s+/g, ' ').trim()),
      ])), contentSelectors);
      await page.screenshot({ path: path.join(output, `${path.parse(name).name}.png`), animations: 'disabled' });
    }
    if (errors.length) throw new Error(errors.join('\n'));
    const report = { width, height, theme, colorScheme: 'light', reducedMotion: 'reduce',
      devicePixelRatio: 1, browser: browser.version(), pages: results, content };
    await fs.writeFile(path.join(output, 'reference.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(`Captured ${pages.length} pages at ${width}×${height} (${theme})`);
  } finally {
    if (browser) await browser.close();
    server.close();
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
