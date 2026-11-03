// usage: node render.mjs <outDir> <fps> <start> <end> [times...]
// renders frames start..end-1 (or explicit times in seconds if given)
import { chromium } from 'playwright-core';
import path from 'node:path';
const [, , outDir, fpsS, startS, endS, ...times] = process.argv;
const fps = +fpsS;
const V = process.env.V === '1';
const html = 'file://' + path.resolve(path.dirname(new URL(import.meta.url).pathname), 'intro.html') + (V ? '?v=1' : '');
const browser = await chromium.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  args: ['--force-color-profile=srgb', '--hide-scrollbars', '--disable-lcd-text'],
});
const page = await browser.newPage({ viewport: V ? { width: 1080, height: 1920 } : { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
page.on('pageerror', e => { console.error('PAGEERROR', e.message); process.exit(1); });
await page.goto(html);
await page.waitForFunction(() => window.ready === true);
const jobs = times.length
  ? times.map(t => ({ t: +t, name: `t${(+t).toFixed(2)}.png` }))
  : Array.from({ length: +endS - +startS }, (_, i) => { const f = +startS + i; return { t: f / fps, name: `f${String(f).padStart(5, '0')}.png` }; });
for (const j of jobs) {
  await page.evaluate(t => window.render(t), j.t);
  await page.screenshot({ path: path.join(outDir, j.name) });
}
await browser.close();
