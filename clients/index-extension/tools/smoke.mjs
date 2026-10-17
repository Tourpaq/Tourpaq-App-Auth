// Loads the unpacked extension in headless Chrome and checks that it works:
//   node clients/index-extension/tools/smoke.mjs
//
// - the manifest "key" gives the extension id the auth app's seeds register (cicimfifinjjjnagflnckioghehdpogc);
// - the service worker starts, and panel.html loads without console errors;
// - against a fake index host (started here, answering /api/v1/index like the real one): not signed in, the panel
//   offers "Sign in with Tourpaq" (the sign-in window itself needs a person: tools/auth_test.mjs tests the flow with
//   fakes); signed in (a token put in storage), it shows the groups with the user's role, and search works.
//
// Chrome-branded builds ignore --load-extension (since Chrome 137), so the extension is loaded with the DevTools
// protocol's Extensions.loadUnpacked over --remote-debugging-pipe. Only Node built-ins.

import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const CHROME = process.env.CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const EXTENSION = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const EXTENSION_ID = 'cicimfifinjjjnagflnckioghehdpogc';
const profile = mkdtempSync(join(tmpdir(), 'index-ext-'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let failures = 0;
const check = (ok, label, detail = '') => {
  if (!ok) failures++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`);
};

// --- A fake index host -------------------------------------------------------------------------
const TOKEN = 'tpx_index_smoke';
const fake = createServer((req, res) => {
  const headers = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Authorization, Accept' };
  if (req.method === 'OPTIONS') { res.writeHead(204, headers); res.end(); return; }
  if (req.url !== '/api/v1/index') { res.writeHead(404, headers); res.end('{}'); return; }
  if (req.headers.authorization !== `Bearer ${TOKEN}`) {
    res.writeHead(401, headers);
    res.end(JSON.stringify({ error: 'unauthorized', auth: { issuer: 'http://127.0.0.1:1', client_id: 'index-extension', scope: 'openid offline_access' } }));
    return;
  }
  res.writeHead(200, headers);
  res.end(JSON.stringify({
    version: 1, site: { title: 'Tourpaq DK Home', brand: 'TP DK Home', url: 'https://index.app.journeybooking.eu/' }, updated_at: new Date().toISOString(),
    groups: [
      { name: 'Apps', slug: 'apps', audience: 'everyone', apps: [
        { name: 'IRM', description: 'Incident response.', status: 'live', url: 'https://irm.app.journeybooking.eu', initials: 'I',
          access: { label: 'NetBird access', tone: 'ok' }, login: { label: 'SSO login', tone: 'ok' }, links: [], app: 'irm', role: 'responder', roles: ['responder'] },
        { name: 'Salesview', description: 'Bookings.', status: 'beta', url: 'https://salesview.app.journeybooking.eu', initials: 'S', access: null, login: null,
          links: [{ label: 'Booking admin', url: 'https://salesview.app.journeybooking.eu/admin', note: null }], app: null, role: null, roles: [] },
      ] },
    ],
    docs: [{ title: 'App deployment', summary: 'How to get an app online.', section: 'Deployment', url: 'https://index.app.journeybooking.eu/docs/deployment/deploying-a-new-app' }],
  }));
});
await new Promise((r) => fake.listen(0, '127.0.0.1', r));
const server = `http://127.0.0.1:${fake.address().port}`;

// --- A CDP client over the pipe (fd 3 in, fd 4 out, NUL-separated JSON) ----------------------
const chrome = spawn(CHROME, [
  '--headless=new', '--remote-debugging-pipe', '--enable-unsafe-extension-debugging',
  `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check', 'about:blank',
], { stdio: ['ignore', 'ignore', 'ignore', 'pipe', 'pipe'] });

let nextId = 0;
const pending = new Map();
const listeners = [];
let buffer = '';
chrome.stdio[4].on('data', (chunk) => {
  buffer += chunk.toString();
  let i;
  while ((i = buffer.indexOf('\0')) >= 0) {
    const msg = JSON.parse(buffer.slice(0, i));
    buffer = buffer.slice(i + 1);
    if (msg.id && pending.has(msg.id)) {
      const { resolve: ok, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      msg.error ? reject(new Error(`${msg.error.message} ${msg.error.data || ''}`)) : ok(msg.result);
    } else for (const l of listeners) l(msg);
  }
});
function send(method, params = {}, sessionId) {
  const id = ++nextId;
  chrome.stdio[3].write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + '\0');
  return new Promise((ok, reject) => pending.set(id, { resolve: ok, reject }));
}

// Opens a page target, collects its console errors and exceptions.
async function openPage(url) {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const errors = [];
  listeners.push((m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') errors.push(`exception: ${m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text}`);
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error') errors.push(`console.error: ${m.params.args.map((a) => a.value ?? a.description).join(' ')}`);
    // HTTP errors (a wrong PIN's 401, a server without incidents) are the app's to handle and show;
    // only script errors count here.
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error' && m.params.entry.source !== 'network') errors.push(`log: ${m.params.entry.text}`);
  });
  await send('Runtime.enable', {}, sessionId);
  await send('Log.enable', {}, sessionId);
  await send('Page.enable', {}, sessionId);
  await send('Page.navigate', { url }, sessionId);
  await sleep(1200);
  const evaluate = async (expression) => {
    const r = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true }, sessionId);
    if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text);
    return r.result.value;
  };
  return { evaluate, errors, close: () => send('Target.closeTarget', { targetId }) };
}

async function waitFor(page, expression, timeout = 8000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (await page.evaluate(expression)) return true;
    await sleep(250);
  }
  return false;
}

try {
  await sleep(1000);
  const { id } = await send('Extensions.loadUnpacked', { path: EXTENSION });
  check(id === EXTENSION_ID, 'the manifest key fixes the extension id the auth app registers', id);
  const base = `chrome-extension://${id}`;

  await sleep(1500);
  const { targetInfos } = await send('Target.getTargets');
  const worker = targetInfos.find((t) => t.type === 'service_worker' && t.url.startsWith(base));
  check(Boolean(worker), 'service worker is running', worker?.url);

  let panel = await openPage(`${base}/panel.html`);
  const manifest = await panel.evaluate('chrome.runtime.getManifest()');
  check(manifest.permissions.includes('identity'), 'the manifest asks for chrome.identity');
  check(await panel.evaluate('chrome.identity.getRedirectURL()') === `https://${EXTENSION_ID}.chromiumapp.org/`, 'the redirect URI is the seeded one');
  await panel.evaluate(`chrome.storage.local.set({ server: ${JSON.stringify(server)} }).then(() => true)`);
  await panel.close();

  panel = await openPage(`${base}/panel.html`);
  check(await waitFor(panel, "!document.getElementById('signin').hidden"), 'not signed in, the panel offers Sign in with Tourpaq');
  check(await panel.evaluate("document.querySelectorAll('.row').length === 0"), 'and shows nothing of the index');
  check(panel.errors.length === 0, 'panel.html has no console errors', panel.errors.join('; '));
  await panel.evaluate(`chrome.storage.local.set({ auth: { issuer: 'http://127.0.0.1:1', clientId: 'index-extension', accessToken: ${JSON.stringify(TOKEN)},
    refreshToken: 'tpr_index_smoke', expiresAt: Date.now() + 3600000, sub: 'sub-1', email: 'alice@tourpaq.com' } }).then(() => true)`);
  await panel.close();

  panel = await openPage(`${base}/panel.html`);
  check(await waitFor(panel, "document.querySelectorAll('.row').length > 0"), 'signed in, the panel shows the index');
  check(await panel.evaluate("document.getElementById('signin').hidden"), 'and no sign-in box');
  check(await panel.evaluate("document.querySelector('.row .role')?.textContent === 'responder'"), "an app's row shows the user's role");
  check(await panel.evaluate("document.getElementById('who').textContent.includes('alice@tourpaq.com')"), 'the footer says who is signed in');
  await panel.evaluate("(() => { const q = document.getElementById('q'); q.value = 'booking admin'; q.dispatchEvent(new Event('input')); return true; })()");
  check(await waitFor(panel, "document.querySelectorAll('.row').length === 1 && document.querySelector('.row .row-title').textContent === 'Salesview'"),
    'search finds an entry by its link label');
  check(panel.errors.length === 0, 'no console errors when signed in', panel.errors.join('; '));
  await panel.close();
} catch (e) {
  failures++;
  console.log(`FAIL ${e.message}`);
} finally {
  const exited = new Promise((r) => chrome.once('exit', r));
  chrome.kill();
  await Promise.race([exited, sleep(5000)]);
  fake.close();
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
console.log(failures ? `${failures} check(s) failed` : 'all checks passed');
process.exit(failures ? 1 : 0);
