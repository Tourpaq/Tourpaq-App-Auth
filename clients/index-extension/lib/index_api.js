// Fetches the index (GET /api/v1/index on the index host, SPECS.md §24.3) with the signed-in user's access token
// (lib/auth.js). On a 401 the token is refreshed once (under the shared lock) and the request retried; a 401 after a
// good refresh means the user may not use the index any more, so the sign-in is forgotten.

import { AuthError, currentAccessToken, refresh } from './auth.js';

export class IndexError extends Error {
  // signedOut: sign in (again). network: the index could not be reached (NetBird off?).
  constructor(message, { status = 0, signedOut = false, network = false } = {}) {
    super(message);
    this.status = status;
    this.signedOut = signedOut;
    this.network = network;
  }
}

async function get(server, token) {
  let res;
  try {
    res = await fetch(`${server}/api/v1/index`, {
      headers: { Accept: 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      cache: 'no-store',
      credentials: 'omit',
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new IndexError(`Couldn't reach ${new URL(server).host} (is NetBird connected?).`, { network: true });
  }
  if (res.status === 401) return { unauthorized: true };
  if (res.status === 403) throw new IndexError('You have no access yet. An admin has been told.', { status: 403 });
  if (!res.ok) throw new IndexError(`The index answered ${res.status}.`, { status: res.status });
  return { data: await res.json() };
}

// The index for `auth` (the stored sign-in, or null). Throws IndexError.
export async function fetchIndex(server, auth) {
  if (!auth?.accessToken) throw new IndexError('Sign in with your Tourpaq account to see the index.', { status: 401, signedOut: true });
  let token;
  try {
    token = await currentAccessToken(auth);
  } catch (e) {
    throw signedOutOr(e);
  }
  let answer = await get(server, token);
  if (!answer.unauthorized) return answer.data;

  let fresh;
  try {
    fresh = await refresh(token);
  } catch (e) {
    throw signedOutOr(e);
  }
  answer = await get(server, fresh.accessToken);
  if (!answer.unauthorized) return answer.data;
  await chrome.storage.local.remove('auth');
  throw new IndexError('Your sign-in no longer gives access to the index. Sign in again.', { status: 401, signedOut: true });
}

function signedOutOr(e) {
  if (e instanceof AuthError && e.signedOut) return new IndexError(e.message || 'The sign-in has ended. Sign in again.', { status: 401, signedOut: true });
  if (e instanceof AuthError) return new IndexError(e.message, { network: true });
  return e;
}
