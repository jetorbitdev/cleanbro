import { chromium } from 'playwright-core';
const b = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', args: ['--force-color-profile=srgb'] });
for (const [v, w, h, out] of [[0, 1920, 1080, 'thumb/thumb_h.png'], [1, 1080, 1920, 'thumb/thumb_v.png']]) {
  const p = await b.newPage({ viewport: { width: w, height: h } });
  await p.goto('file://' + process.cwd() + '/thumb.html' + (v ? '?v=1' : ''));
  await p.waitForLoadState('load');
  await p.screenshot({ path: out });
}
await b.close();
