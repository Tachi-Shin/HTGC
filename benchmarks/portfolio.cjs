// Run against the packaged executable, not an HTML preview or a development server.
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron } = require('playwright');

async function main() {
  const executablePath = process.argv[2];
  if (!executablePath) throw new Error('Usage: npm run portfolio -- /path/to/HTGC-Web [Electron flags]');
  const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'htgc-benchmark-'));
  let app;
  try {
    app = await electron.launch({
      executablePath: path.resolve(executablePath),
      args: [`--user-data-dir=${profile}`, ...process.argv.slice(3)],
      timeout: 30000,
    });
    const page = await app.firstWindow();
    page.setDefaultTimeout(15000);
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => {
      if (response.url().startsWith('htgc://app/') && response.status() >= 400) {
        errors.push(`${response.status()} ${response.url()}`);
      }
    });
    page.on('requestfailed', request => errors.push(`${request.url()}: ${request.failure()?.errorText}`));
    // Reload after installing listeners so startup failures are included.
    await page.reload({ waitUntil: 'load' });
    await page.waitForSelector('site-header nav');
    assert.equal(await page.title(), 'Shingo | Portfolio');
    assert.equal(await page.locator('#news-list li').count(), 9);
    await page.waitForFunction(() => [...document.images].every(img => img.complete && img.naturalWidth > 0));
    const images = await page.locator('img').count();
    assert.equal(images, 12);
    assert.equal(await page.locator('.hero').evaluate(el => getComputedStyle(el).display), 'grid');
    assert.equal(await page.locator('script[type="application/ld+json"]').evaluate(el => JSON.parse(el.textContent).name), 'Shingo');
    await page.waitForFunction(() => getComputedStyle(document.querySelector('.hero__inner')).opacity === '1');
    // The pinned source initializes particles before particles.js defines its function.
    // This also leaves an empty canvas when served over HTTP. Record that behavior,
    // then exercise the original function explicitly without rewriting any source.
    const particlesAutoStarted = await page.locator('#bg-canvas').evaluate(c =>
      c.getContext('2d').getImageData(0, 0, c.width, c.height).data.some(v => v !== 0));
    await page.evaluate(() => window.initParticles('bg-canvas'));
    await page.waitForFunction(() => {
      const c = document.querySelector('#bg-canvas');
      return c.width > 0 && c.height > 0 && c.getContext('2d').getImageData(0, 0, c.width, c.height).data.some(v => v !== 0);
    });
    const before = await page.locator('.bg-track--left').evaluate(el => getComputedStyle(el).transform);
    await page.waitForFunction(previous => getComputedStyle(document.querySelector('.bg-track--left')).transform !== previous, before);

    await page.locator('#themeToggle').click(); // auto -> light
    assert.equal(await page.evaluate(() => localStorage.getItem('theme')), 'light');
    const light = await page.locator('body').evaluate(el => getComputedStyle(el).color);
    await page.locator('#themeToggle').click(); // light -> dark
    assert.equal(await page.evaluate(() => localStorage.getItem('theme')), 'dark');
    const dark = await page.locator('body').evaluate(el => getComputedStyle(el).color);
    assert.notEqual(light, dark);

    await page.locator('.hero__cta a[href="projects.html"]').click();
    await page.waitForURL('htgc://app/projects.html');
    assert.equal(await page.title(), 'Projects | Shingo');
    assert.equal(await page.locator('article.card').count(), 5);
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
    await page.locator('.nav__links a[href="about.html"]').click();
    await page.waitForURL('htgc://app/about.html');
    await page.waitForSelector('#timeline .tl-item');
    const timeline = await page.locator('#timeline .tl-item').count();
    assert.ok(timeline >= 50, `Expected the full timeline, got ${timeline}`);
    assert.equal(await page.locator('meter').count(), 5);
    await page.reload();
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'dark');
    await page.locator('.nav__links a[href="index.html"]').click();
    await page.waitForURL('htgc://app/index.html');
    await page.locator('a[href="projects.html#web"]').click();
    await page.waitForURL('htgc://app/projects.html#web');
    assert.equal(await page.evaluate(() => location.hash), '#web');

    await page.goto('htgc://app/contact.html');
    assert.equal(await page.title(), 'Contact | Shingo');
    const form = page.locator('form.contact');
    assert.equal(await form.evaluate(el => el.checkValidity()), false);
    await form.locator('[name="name"]').fill('HTGC benchmark');
    await form.locator('[name="email"]').fill('benchmark@example.invalid');
    await form.locator('[name="message"]').fill('ローカル検証。フォームの送信は行いません。');
    assert.equal(await form.evaluate(el => el.checkValidity()), true);
    assert.ok((await page.locator('site-footer').innerText()).includes('Shingo'));
    // No submission: the original site's form requires a server-side service.

    await page.goto('htgc://app/index.html');
    await page.setViewportSize({ width: 390, height: 844 });
    assert.ok(await page.locator('.container').first().evaluate(el => el.getBoundingClientRect().width <= innerWidth));
    assert.deepEqual(errors, []);
    const versions = await app.evaluate(() => ({ electron: process.versions.electron, chromium: process.versions.chrome }));
    console.log(JSON.stringify({
      result: 'PASS', ...versions, pages: 4, homeImages: images, news: 9,
      projectCards: 5, timelineItems: timeline, particlesAutoStarted,
      checks: ['ES modules', 'Web Components', 'CSS Grid', 'CSS animation', 'Canvas pixels',
        'IntersectionObserver', 'theme persistence', 'HTML links and fragments',
        'form validation (no submission)', '390px viewport', 'no script/resource errors'],
    }, null, 2));
  } finally {
    if (app) await app.close();
    await fs.rm(profile, { recursive: true, force: true });
  }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
