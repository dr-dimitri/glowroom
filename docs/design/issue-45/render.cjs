// Render the presentation source with an installed Playwright + Chromium.
// Independent browser pages share one browser; eight renders are bounded to two workers.
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');

(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    const cases = ['a-open', 'a-closed', 'b-open', 'b-closed'];
    const sizes = [{width:1440,height:900},{width:1000,height:660}];
    const jobs = sizes.flatMap(size => cases.map(name => ({name, size})));
    const measurements = [];
    async function worker() {
      for (let job; (job = jobs.shift());) {
        const page = await browser.newPage({viewport:job.size,deviceScaleFactor:1});
        try {
          const [design,state] = job.name.split('-');
          const url = pathToFileURL(path.join(__dirname,'mockups.html'));
          url.search = new URLSearchParams({design,state}).toString();
          await page.goto(url.href);
          await page.screenshot({path:path.join(__dirname,`${job.name}-${job.size.width}.png`)});
          const metrics = await page.evaluate(() => {
            const rect = document.querySelector('[data-viewport]').getBoundingClientRect();
            const photo = document.querySelector('main .photo').getBoundingClientRect();
            const fit = (w,h) => { const k=Math.min(photo.width/w,photo.height/h); return {width:+(w*k).toFixed(2),height:+(h*k).toFixed(2)}; };
            const clipped = [...document.querySelectorAll('header button,.dock button')].filter(el=>{
              const r=el.getBoundingClientRect();return r.x<0||r.right>innerWidth;
            }).map(el=>el.textContent.trim());
            return {viewport:{width:rect.width,height:rect.height},inner:{width:photo.width,height:photo.height},landscape:fit(3,2),portrait:fit(2,3),horizontalOverflow:document.documentElement.scrollWidth>innerWidth,clippedControls:clipped};
          });
          if(metrics.horizontalOverflow||metrics.clippedControls.length)throw new Error(`Clipped controls: ${job.name} at ${job.size.width}: ${JSON.stringify(metrics)}`);
          measurements.push({state:job.name,window:job.size,...metrics});
        } finally { await page.close(); }
      }
    }
    await Promise.all([worker(),worker()]);
    measurements.sort((a,b)=>b.window.width-a.window.width||a.state.localeCompare(b.state));
    await fs.writeFile(path.join(__dirname,'layout-measurements.json'),JSON.stringify(measurements,null,2)+'\n');
    console.log(`Rendered ${measurements.length} stills; viewport and fitted 3:2 / 2:3 geometry recorded.`);
  } finally { await browser.close(); }
})().catch(error=>{console.error(error);process.exitCode=1;});
