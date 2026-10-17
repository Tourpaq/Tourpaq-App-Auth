# Tourpaq Index (browser extension)

A Manifest V3 extension for Chrome (116+) and Edge that puts the index of **https://index.app.journeybooking.eu** in
the browser's side panel: the groups as on the site, the same as-you-type search, copyable addresses, the access and
login pills, and your role in each of our apps. It moved here from Tourpaq-App-WWW's `extension/` when the index
was merged into the auth app (SPECS.md §24.3).

- **Open and close**: the toolbar button, or **Ctrl+Shift+Space** on Windows, **⌘⇧Space** on a Mac (change it at
  `chrome://extensions/shortcuts`, `edge://extensions/shortcuts`; the browser skips a suggested key that is taken).
- **Groups** work as an accordion: opening one closes the others.
- **Each entry is a button**: a click anywhere opens it (Cmd/Ctrl-click in the background). Its links, *Details* and
  the address keep their own click.
- **Keyboard**: `/` focuses search. ↑/↓ walk the open group (past its end the next group opens); in a search they
  walk the results. Enter opens, Shift+Enter in the background; Esc clears the search.

## Signing in

The index is personal (an app of ours is shown only to people with access to it, technical groups only to their
groups), so the panel signs in first, through Tourpaq Auth, as the IRM's extension does (SPECS.md §10):

- **Sign in with Tourpaq** opens `chrome.identity.launchWebAuthFlow` at the auth host's `/oauth/authorize` for the
  public client **`index-extension`**, with PKCE `S256`, `state`, `nonce` and `offline_access`. With an auth session
  alive the window closes by itself. The code is exchanged at `/oauth/token` for an access token (`tpx_index_…`, 1 hour)
  and a rotating refresh token, kept in this profile's `chrome.storage.local` (not synced). Refreshes are serialised
  with a Web Lock, because a refresh token used twice revokes the sign-in.
- The panel then reads **`GET /api/v1/index`** on the index host with `Authorization: Bearer tpx_index_…` (no cookies).
  The index checks the token in-process with the rules of `/oauth/introspect` and answers with what this user may see.
  Without a token it answers 401 with where to sign in (`auth.issuer`, `auth.client_id`), which is how the panel finds
  the auth host.
- **Access**: signing in needs access to the auth app's app **Index** (a role in it, directly or through a group;
  DK Tech has it from the seeds). Without it the auth app says so.
- **Sign out** (footer) revokes the refresh token at the auth app and forgets the tokens and the cached index.

### The extension id and the redirect URI (manifest `key`)

The auth app only redirects to registered URIs, and the extension's is `https://<extension id>.chromiumapp.org/`. An
unpacked extension's id would come from its folder path, so `manifest.json` has a **`key`** (a public RSA key, base64
DER) that fixes it on every install:

- extension id **`cicimfifinjjjnagflnckioghehdpogc`**
- redirect URI **`https://cicimfifinjjjnagflnckioghehdpogc.chromiumapp.org/`**, which the auth app's seeds register on
  the client `index-extension` (an auth app seeded before this needs it added on the admin host, on the client's page).

`test/clients/index_extension_manifest_test.rb` checks that the key gives this id. The private half was not kept: it
is only needed to pack a `.crx` or to publish in a store, and a store listing brings its own key. To replace the key,
put the new public key in `manifest.json` (`openssl rsa -in new.pem -pubout -outform DER | base64 | tr -d '\n'`), and
update the id here, in the test, in `db/seeds.rb` and on the client `index-extension`.

## Trying it

1. `chrome://extensions` (or `edge://extensions`), switch on **Developer mode**, **Load unpacked**, pick this folder.
2. Against a local auth app (`bin/docker-dev` in the repository root): **Settings** at the bottom of the panel, enter
   `http://index.localhost:3050` (the panel signs in at the matching `http://auth.localhost:3050`), save, then **Sign in
   with Tourpaq** and use the fake identity provider.

The panel keeps the last good copy of the index, so it opens instantly and still works with NetBird off (it says so).
The API changes only by adding fields; for anything that breaks it the index bumps `version` and the panel asks
people to update.

## Tests

```bash
node clients/index-extension/tools/auth_test.mjs   # sign-in, refresh rotation, the index fetch (fakes, Node only)
node clients/index-extension/tools/smoke.mjs       # loads it in headless Chrome against a fake index host
```

## Handing it out

`bin/package-index-extension` (repository root) zips this folder to `tmp/tourpaq-index-extension-<version>.zip` (bump
`version` in `manifest.json` first). Upload it to the Chrome Web Store as **Unlisted** or private to the company
domain, and to Edge Add-ons. The panel has no tracking and reads only the index and auth hosts.

## Files

| File | What |
| --- | --- |
| `manifest.json` | permissions (`sidePanel`, `storage`, `identity`), hosts, the fixed `key` |
| `background.js` | opens and closes the side panel (toolbar button, shortcut) |
| `panel.html`, `panel.js`, `panel.css` | the panel |
| `lib/auth.js` | Tourpaq sign-in: PKCE, launchWebAuthFlow, token exchange, refresh, sign out |
| `lib/index_api.js` | `GET /api/v1/index` with the bearer token, refresh on 401 |
| `tools/auth_test.mjs`, `tools/smoke.mjs` | the tests |
