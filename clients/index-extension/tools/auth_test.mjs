// Tests the extension's Tourpaq sign-in (lib/auth.js) and its index fetch with refresh-on-401 (lib/index_api.js) in
// Node, with chrome.storage, chrome.identity and fetch replaced by fakes of the auth app and the index host:
//
//   node clients/index-extension/tools/auth_test.mjs
//
// Only Node built-ins (node:test). The real flow against a running auth app needs a person at the sign-in window;
// the auth app's own tests cover the server side (test/integration/index/api_test.rb).

import assert from 'node:assert/strict';
import { beforeEach, test } from 'node:test';

const ISSUER = 'https://auth.example.test';
const INDEX = 'https://index.example.test';
const REDIRECT = 'https://cicimfifinjjjnagflnckioghehdpogc.chromiumapp.org/';

// --- Fakes ------------------------------------------------------------------------------------------

let store;
let auth; // the fake auth app: issued tokens and what it saw
let index; // the fake index host: what it was sent
let authorizeUrl;
let authorizeAnswer; // (params) => redirect URL

globalThis.chrome = {
  storage: {
    local: {
      async get(keys) {
        const list = keys == null ? Object.keys(store) : Array.isArray(keys) ? keys : [keys];
        return Object.fromEntries(list.filter((k) => k in store).map((k) => [k, structuredClone(store[k])]));
      },
      async set(values) { Object.assign(store, structuredClone(values)); },
      async remove(keys) { for (const k of [keys].flat()) delete store[k]; },
    },
  },
  identity: {
    getRedirectURL: () => REDIRECT,
    async launchWebAuthFlow({ url }) {
      authorizeUrl = new URL(url);
      return authorizeAnswer(Object.fromEntries(authorizeUrl.searchParams));
    },
  },
};

function idToken(claims) {
  const enc = (o) => Buffer.from(JSON.stringify(o)).toString('base64url');
  return `${enc({ alg: 'RS256', kid: 'k' })}.${enc(claims)}.signature`;
}

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

const INDEX_BODY = { version: 1, site: { title: 'Tourpaq DK Home', url: `${INDEX}/` }, groups: [{ name: 'Apps', apps: [{ name: 'IRM', role: 'responder' }] }], docs: [] };

globalThis.fetch = async (url, init = {}) => {
  const u = new URL(url);
  const form = init.body instanceof URLSearchParams ? Object.fromEntries(init.body) : null;
  if (u.origin === ISSUER && u.pathname === '/oauth/token') {
    auth.tokenCalls.push(form);
    await new Promise((r) => setTimeout(r, 5)); // let concurrent callers pile up
    if (form.grant_type === 'authorization_code') {
      if (form.code !== 'the-code' || form.client_id !== 'index-extension' || form.redirect_uri !== REDIRECT) return json(400, { error: 'invalid_grant' });
      return json(200, issue({ id_token: idToken({ iss: ISSUER, aud: 'index-extension', sub: 'sub-1', nonce: auth.nonce, email: 'alice@tourpaq.com', name: 'Alice' }) }));
    }
    if (form.grant_type === 'refresh_token') {
      if (form.refresh_token !== auth.refresh) return json(400, { error: 'invalid_grant', error_description: 'The refresh token was used already.' });
      return json(200, issue());
    }
  }
  if (u.origin === ISSUER && u.pathname === '/oauth/revoke') {
    auth.revoked.push(form.token);
    return new Response('', { status: 200 });
  }
  if (u.origin === INDEX && u.pathname === '/api/v1/index') {
    const bearer = (init.headers?.Authorization || '').replace(/^Bearer /, '');
    index.seen.push({ bearer, credentials: init.credentials });
    if (bearer && bearer === auth.access && !index.refuse) return json(200, INDEX_BODY);
    return json(401, { error: 'unauthorized', auth: { issuer: ISSUER, client_id: 'index-extension', scope: 'openid email profile offline_access' } });
  }
  return json(404, {});
};

let counter = 0;
function issue(extra = {}) {
  counter += 1;
  auth.access = `tpx_index_access${counter}`;
  auth.refresh = `tpr_index_refresh${counter}`;
  return { access_token: auth.access, refresh_token: auth.refresh, token_type: 'Bearer', expires_in: 3600, ...extra };
}

beforeEach(() => {
  store = {};
  auth = { tokenCalls: [], revoked: [], access: null, refresh: null, nonce: null };
  index = { seen: [], refuse: false };
  authorizeAnswer = (params) => {
    auth.nonce = params.nonce;
    return `${REDIRECT}?code=the-code&state=${encodeURIComponent(params.state)}`;
  };
});

const { fetchConfig, issuerFor, pkceChallenge, signIn, signOut } = await import('../lib/auth.js');
const { fetchIndex, IndexError } = await import('../lib/index_api.js');

async function signedIn() {
  return signIn(await fetchConfig(INDEX));
}

// --- Tests ------------------------------------------------------------------------------------------

test('PKCE S256 matches RFC 7636 appendix B', async () => {
  assert.equal(await pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
});

test('the auth host goes with the index host', () => {
  assert.equal(issuerFor('https://index.app.journeybooking.eu'), 'https://auth.app.journeybooking.eu');
  assert.equal(issuerFor('http://index.localhost:3050'), 'http://auth.localhost:3050');
});

test('the index says where to sign in (its 401), else the auth host is guessed', async () => {
  assert.deepEqual(await fetchConfig(INDEX), { issuer: ISSUER, clientId: 'index-extension', scope: 'openid email profile offline_access' });
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response('<html>', { status: 502 });
  try {
    assert.equal((await fetchConfig('https://index.app.journeybooking.eu')).issuer, 'https://auth.app.journeybooking.eu');
  } finally {
    globalThis.fetch = original;
  }
});

test('signs in with the code flow: PKCE, state, nonce, offline_access, the fixed extension redirect URI', async () => {
  const stored = await signedIn();
  const q = Object.fromEntries(authorizeUrl.searchParams);
  assert.equal(`${authorizeUrl.origin}${authorizeUrl.pathname}`, `${ISSUER}/oauth/authorize`);
  assert.equal(q.client_id, 'index-extension');
  assert.equal(q.redirect_uri, REDIRECT);
  assert.equal(q.response_type, 'code');
  assert.equal(q.code_challenge_method, 'S256');
  assert.match(q.scope, /\bopenid\b.*\boffline_access\b/);
  assert.ok(q.state && q.nonce && q.code_challenge);
  assert.equal(await pkceChallenge(auth.tokenCalls[0].code_verifier), q.code_challenge);
  assert.equal(stored.accessToken, auth.access);
  assert.ok(stored.accessToken.startsWith('tpx_index_'));
  assert.equal(store.auth.refreshToken, auth.refresh);
  assert.equal(store.auth.email, 'alice@tourpaq.com');
});

test('refuses a callback with another state, an error, or an ID token for another sign-in', async () => {
  const config = await fetchConfig(INDEX);
  authorizeAnswer = () => `${REDIRECT}?code=the-code&state=forged`;
  await assert.rejects(signIn(config), /not started here/);
  authorizeAnswer = (p) => `${REDIRECT}?error=access_denied&state=${p.state}`;
  await assert.rejects(signIn(config), /no access to the index extension/);
  authorizeAnswer = (p) => { auth.nonce = 'another'; return `${REDIRECT}?code=the-code&state=${p.state}`; };
  await assert.rejects(signIn(config), /does not belong to this sign-in/);
  assert.equal(store.auth, undefined);
});

test('fetches the index with the bearer token and without cookies', async () => {
  const stored = await signedIn();
  const body = await fetchIndex(INDEX, stored);
  assert.equal(body.groups[0].apps[0].role, 'responder');
  assert.deepEqual(index.seen.at(-1), { bearer: auth.access, credentials: 'omit' });
});

test('not signed in: asks to sign in, sends nothing', async () => {
  const err = await fetchIndex(INDEX, null).catch((e) => e);
  assert.ok(err instanceof IndexError);
  assert.ok(err.signedOut);
  assert.equal(index.seen.length, 0);
});

test('on a 401 it refreshes once (rotating) and retries', async () => {
  await signedIn();
  const firstRefresh = auth.refresh;
  auth.access = 'expired-on-the-server';
  const body = await fetchIndex(INDEX, store.auth);
  assert.equal(body.version, 1);
  const refreshes = auth.tokenCalls.filter((c) => c.grant_type === 'refresh_token');
  assert.equal(refreshes.length, 1);
  assert.equal(refreshes[0].refresh_token, firstRefresh);
  assert.equal(refreshes[0].client_id, 'index-extension');
  assert.equal(store.auth.accessToken, auth.access);
  assert.equal(store.auth.refreshToken, auth.refresh, 'the rotated refresh token is kept');
  assert.notEqual(store.auth.refreshToken, firstRefresh);
});

test('concurrent 401s share one refresh (a second would count as reuse)', async () => {
  await signedIn();
  auth.access = 'expired-on-the-server';
  const signedInAs = store.auth;
  const results = await Promise.all([1, 2, 3].map(() => fetchIndex(INDEX, signedInAs)));
  assert.equal(results.length, 3);
  assert.equal(auth.tokenCalls.filter((c) => c.grant_type === 'refresh_token').length, 1);
});

test('refreshes ahead of expiry', async () => {
  await signedIn();
  store.auth.expiresAt = Date.now() + 10_000;
  await fetchIndex(INDEX, store.auth);
  assert.equal(auth.tokenCalls.filter((c) => c.grant_type === 'refresh_token').length, 1);
  assert.ok(store.auth.expiresAt > Date.now() + 3_000_000);
});

test('a refused refresh signs out: the tokens are gone and the panel asks to sign in', async () => {
  await signedIn();
  auth.access = 'expired-on-the-server';
  auth.refresh = 'revoked-chain';
  const err = await fetchIndex(INDEX, store.auth).catch((e) => e);
  assert.ok(err instanceof IndexError);
  assert.ok(err.signedOut);
  assert.equal(store.auth, undefined);
});

test('a 401 after a good refresh (no access to the index any more) forgets the sign-in', async () => {
  await signedIn();
  index.refuse = true;
  const err = await fetchIndex(INDEX, store.auth).catch((e) => e);
  assert.ok(err.signedOut);
  assert.match(err.message, /no longer gives access/);
  assert.equal(store.auth, undefined);
});

test('the index unreachable is not a sign out', async () => {
  await signedIn();
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init) => (new URL(url).origin === INDEX ? Promise.reject(new TypeError('Failed to fetch')) : original(url, init));
  try {
    const err = await fetchIndex(INDEX, store.auth).catch((e) => e);
    assert.ok(err.network);
    assert.ok(!err.signedOut);
    assert.ok(store.auth, 'still signed in');
  } finally {
    globalThis.fetch = original;
  }
});

test('sign out revokes the refresh token and forgets the tokens', async () => {
  await signedIn();
  const refreshToken = auth.refresh;
  await signOut();
  assert.deepEqual(auth.revoked, [refreshToken]);
  assert.equal(store.auth, undefined);
});
