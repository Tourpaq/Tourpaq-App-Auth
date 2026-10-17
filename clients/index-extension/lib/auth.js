// Signing in to the index through Tourpaq Auth (SPECS.md §10, §24.3), as the IRM's extension does:
// chrome.identity.launchWebAuthFlow opens the auth app's /oauth/authorize for the public client index-extension with
// PKCE S256, state, nonce and offline_access; the code is exchanged at /oauth/token for an access token (tpx_index_…,
// 1 hour) and a rotating refresh token. Both live in chrome.storage.local ("auth"), never synced. The index's
// /api/v1/index takes the access token as a bearer token.
//
// Refresh tokens rotate and a reused one revokes the whole sign-in, so only one refresh may run at a time across the
// panel and any other page of the extension: they share a Web Lock.

const LOCK = 'tourpaq-index-auth-refresh';
const EARLY_MS = 60 * 1000; // refresh this long before the access token expires
export const CLIENT_ID = 'index-extension';
export const SCOPE = 'openid email profile offline_access';

export class AuthError extends Error {
  // signedOut: the sign-in is gone (refused refresh, revoked); the user must sign in again.
  constructor(message, { signedOut = false, code = null } = {}) {
    super(message);
    this.signedOut = signedOut;
    this.code = code;
  }
}

// --- Where to sign in --------------------------------------------------------------------------------

// The auth host that goes with an index host: index.app.journeybooking.eu → auth.app.journeybooking.eu,
// index.localhost:3050 → auth.localhost:3050. Used for the permission request before anything is fetched.
export function issuerFor(server) {
  const url = new URL(server);
  url.hostname = url.hostname.replace(/^index\./, 'auth.');
  return url.origin;
}

// The index tells where to sign in: GET /api/v1/index without a token answers 401 with
// { auth: { issuer, client_id, scope } }. When it says nothing, the issuer is guessed from the index host.
export async function fetchConfig(server) {
  let res;
  try {
    res = await fetch(`${server}/api/v1/index`, {
      headers: { Accept: 'application/json' }, credentials: 'omit', cache: 'no-store', signal: AbortSignal.timeout(10000),
    });
  } catch {
    throw new AuthError(`Cannot reach the index at ${new URL(server).host} (is NetBird connected?).`);
  }
  let auth = null;
  try {
    auth = (await res.json())?.auth || null;
  } catch {
    // not JSON
  }
  return {
    issuer: String(auth?.issuer || issuerFor(server)).replace(/\/+$/, ''),
    clientId: auth?.client_id || CLIENT_ID,
    scope: auth?.scope || SCOPE,
  };
}

// --- PKCE, state, nonce ------------------------------------------------------------------------------

export function base64url(bytes) {
  let s = '';
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function randomString(bytes = 32) {
  return base64url(crypto.getRandomValues(new Uint8Array(bytes)));
}

export async function pkceChallenge(verifier) {
  return base64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)));
}

export async function authorizationUrl(config, { redirectUri, state, nonce, verifier }) {
  const query = new URLSearchParams({
    response_type: 'code', client_id: config.clientId, redirect_uri: redirectUri, scope: config.scope,
    state, nonce, code_challenge: await pkceChallenge(verifier), code_challenge_method: 'S256',
  });
  return `${config.issuer}/oauth/authorize?${query}`;
}

// The claims of a JWT, without checking its signature: the ID token comes straight from the token endpoint over TLS
// (OIDC Core 3.1.3.7), and the extension only reads the nonce and who signed in.
export function jwtClaims(token) {
  const part = String(token || '').split('.')[1];
  if (!part) return null;
  try {
    const json = atob(part.replace(/-/g, '+').replace(/_/g, '/'));
    return JSON.parse(decodeURIComponent(Array.from(json, (c) => `%${c.charCodeAt(0).toString(16).padStart(2, '0')}`).join('')));
  } catch {
    return null;
  }
}

// --- The token endpoint --------------------------------------------------------------------------------

async function tokenRequest(issuer, form) {
  let res;
  try {
    res = await fetch(`${issuer}/oauth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
      body: new URLSearchParams(form),
      credentials: 'omit',
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new AuthError(`Cannot reach Tourpaq Auth at ${new URL(issuer).host}.`);
  }
  let json = null;
  try {
    json = await res.json();
  } catch {
    // not JSON
  }
  if (!res.ok) {
    const code = json?.error || null;
    // invalid_grant: the code or refresh token is used up, expired or revoked (or was reused).
    const signedOut = res.status === 400 || res.status === 401;
    throw new AuthError(json?.error_description || code || `Tourpaq Auth answered ${res.status}.`, { signedOut, code });
  }
  return json;
}

function stored(config, tokens, previous = {}) {
  const claims = tokens.id_token ? jwtClaims(tokens.id_token) : null;
  return {
    issuer: config.issuer,
    clientId: config.clientId,
    accessToken: tokens.access_token,
    // Rotation returns a new refresh token; keep the old one only if none came back.
    refreshToken: tokens.refresh_token || previous.refreshToken || '',
    expiresAt: Date.now() + (Number(tokens.expires_in) || 3600) * 1000,
    sub: claims?.sub || previous.sub || null,
    email: claims?.email || previous.email || null,
    name: claims?.name || previous.name || null,
  };
}

// --- Sign in, refresh, sign out ----------------------------------------------------------------------

// Opens the sign-in window (it closes at once when an auth session is alive) and stores the tokens. Returns the
// stored "auth" object.
export async function signIn(config, { interactive = true } = {}) {
  const redirectUri = chrome.identity.getRedirectURL();
  const state = randomString();
  const nonce = randomString();
  const verifier = randomString(48);
  const url = await authorizationUrl(config, { redirectUri, state, nonce, verifier });

  let responseUrl;
  try {
    responseUrl = await chrome.identity.launchWebAuthFlow({ url, interactive });
  } catch (e) {
    throw new AuthError(/did not approve|canceled|cancelled|closed/i.test(e?.message || '') ? 'Sign-in was cancelled.' : `Sign-in failed: ${e?.message || e}`);
  }
  const params = new URL(responseUrl).searchParams;
  if (params.get('error')) {
    throw new AuthError(params.get('error') === 'access_denied'
      ? 'You have no access to the index extension in Tourpaq Auth yet. Ask an admin (DK Tech).'
      : `Tourpaq Auth did not sign you in: ${params.get('error_description') || params.get('error')}.`, { code: params.get('error') });
  }
  if (params.get('state') !== state) throw new AuthError('This sign-in was not started here. Try again.');

  const tokens = await tokenRequest(config.issuer, {
    grant_type: 'authorization_code', code: params.get('code') || '', redirect_uri: redirectUri,
    client_id: config.clientId, code_verifier: verifier,
  });
  const claims = jwtClaims(tokens.id_token);
  if (!claims || claims.nonce !== nonce || claims.iss !== config.issuer ||
      !(Array.isArray(claims.aud) ? claims.aud : [claims.aud]).includes(config.clientId)) {
    throw new AuthError('Tourpaq Auth answered with an ID token that does not belong to this sign-in.');
  }
  if (!tokens.access_token) throw new AuthError('Tourpaq Auth answered without an access token.');
  const auth = stored(config, tokens);
  await chrome.storage.local.set({ auth });
  return auth;
}

// A fresh access token for the request that got a 401 (or is about to expire) with `staleAccessToken`. Runs under the
// shared lock; when another page already refreshed, its result is used.
export async function refresh(staleAccessToken) {
  return navigator.locks.request(LOCK, async () => {
    const { auth } = await chrome.storage.local.get('auth');
    if (!auth?.accessToken) throw new AuthError('Signed out.', { signedOut: true });
    if (auth.accessToken !== staleAccessToken && auth.expiresAt - EARLY_MS > Date.now()) return auth;
    if (!auth.refreshToken) {
      await chrome.storage.local.remove('auth');
      throw new AuthError('The sign-in has ended. Sign in again.', { signedOut: true });
    }
    let tokens;
    try {
      tokens = await tokenRequest(auth.issuer, { grant_type: 'refresh_token', refresh_token: auth.refreshToken, client_id: auth.clientId });
    } catch (e) {
      if (e.signedOut) await chrome.storage.local.remove('auth');
      throw e;
    }
    const next = stored({ issuer: auth.issuer, clientId: auth.clientId }, tokens, auth);
    await chrome.storage.local.set({ auth: next });
    return next;
  });
}

// The access token to send now: refreshed first when it is about to expire.
export async function currentAccessToken(auth) {
  if (auth.expiresAt - EARLY_MS > Date.now()) return auth.accessToken;
  return (await refresh(auth.accessToken)).accessToken;
}

// Revokes the refresh token at the auth app (which ends the whole sign-in) and forgets the tokens here.
export async function signOut() {
  const { auth } = await chrome.storage.local.get('auth');
  await chrome.storage.local.remove('auth');
  if (!auth?.refreshToken) return;
  try {
    await fetch(`${auth.issuer}/oauth/revoke`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ token: auth.refreshToken, token_type_hint: 'refresh_token', client_id: auth.clientId }),
      credentials: 'omit',
      signal: AbortSignal.timeout(10000),
    });
  } catch {
    // Offline: the tokens are forgotten here; the refresh token expires on its own.
  }
}
