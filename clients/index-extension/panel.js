// The side panel: the signed-in user's index from /api/v1/index on the index host (SPECS.md §24.3), grouped as on the
// site, with the same as-you-type search. The user signs in with Tourpaq Auth (lib/auth.js: launchWebAuthFlow, PKCE,
// rotating refresh tokens); the index answers with what that user may see. The last good copy is kept in storage, so
// the panel opens instantly and still works when the index can't be reached (NetBird off); it is forgotten at sign
// out. Everything from the API is treated as data: text goes in via textContent and only http(s) URLs become links.

import { AuthError, fetchConfig, issuerFor, signIn, signOut } from './lib/auth.js';
import { IndexError, fetchIndex } from './lib/index_api.js';

const DEFAULT_SERVER = "https://index.app.journeybooking.eu";
const API_VERSION = 1;
const MAX_HITS = 50;

const $ = (id) => document.getElementById(id);
const q = $("q");
const list = $("list");
const notice = $("notice");

let server = DEFAULT_SERVER;
let data = null;
let entries = [];
// The one open group's key; null when all are closed, undefined before the
// first visit (then the first group opens).
let openGroup;
let selectedRow = null;

// --- small helpers ---------------------------------------------------------
const el = (tag, className, text) => {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
};

// Only web links, as on the site. Anything else is dropped, not linked.
const safeUrl = (value) => {
  try {
    const url = new URL(value);
    return url.protocol === "https:" || url.protocol === "http:" ? url.href : null;
  } catch {
    return null;
  }
};

const link = (href, className, text) => {
  const url = safeUrl(href);
  const node = el(url ? "a" : "span", className, text);
  if (url) { node.href = url; node.target = "_blank"; node.rel = "noopener"; }
  return node;
};

const openTab = (url, { background = false } = {}) => {
  if (url) chrome.tabs.create({ url, active: !background });
};

const ago = (iso) => {
  const seconds = (Date.now() - new Date(iso).getTime()) / 1000;
  if (!Number.isFinite(seconds)) return "";
  if (seconds < 90) return "just now";
  const minutes = Math.round(seconds / 60);
  if (minutes < 90) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 36) return `${hours} h ago`;
  return `${Math.round(hours / 24)} days ago`;
};

const showNotice = (text) => { notice.textContent = text; notice.hidden = !text; };

// --- loading -----------------------------------------------------------------
const load = async ({ fromCache = true } = {}) => {
  const stored = await chrome.storage.local.get(["server", "cache", "openGroup", "auth"]);
  server = stored.server || DEFAULT_SERVER;
  openGroup = stored.openGroup;
  $("brand").href = server + "/";
  showAccount(stored.auth);

  // The cache belongs to the signed-in user at this server.
  const cache = stored.auth && stored.cache?.server === server && stored.cache?.sub === stored.auth.sub ? stored.cache : null;
  if (fromCache && cache) use(cache.data, cache.fetchedAt);

  $("refresh").disabled = true;
  try {
    const fresh = await fetchIndex(server, stored.auth);
    const fetchedAt = new Date().toISOString();
    await chrome.storage.local.set({ cache: { server, sub: stored.auth.sub, data: fresh, fetchedAt } });
    showNotice("");
    showSignIn(false);
    use(fresh, fetchedAt);
  } catch (error) {
    if (error instanceof IndexError && error.signedOut) {
      await chrome.storage.local.remove("cache");
      data = null;
      entries = [];
      list.replaceChildren();
      showAccount(null);
      showNotice(stored.auth ? error.message : "");
      showSignIn(true);
    } else if (cache) {
      showNotice(`${error.message} Showing the list from ${ago(cache.fetchedAt)}.`);
    } else {
      showNotice(error.message);
      list.replaceChildren();
    }
  } finally {
    $("refresh").disabled = false;
  }
};

const showSignIn = (visible) => {
  $("signin").hidden = !visible;
  if (visible) $("signin-error").hidden = true;
};

const showAccount = (auth) => {
  $("account").hidden = !auth;
  $("who").textContent = auth ? `Signed in as ${auth.email || auth.name || "you"}` : "";
};

// Must start from the click: the browser asks for a host permission only inside a user gesture.
const startSignIn = async () => {
  const button = $("signin-button");
  const error = $("signin-error");
  error.hidden = true;
  button.disabled = true;
  try {
    const granted = await chrome.permissions.request({ origins: [`${server}/*`, `${issuerFor(server)}/*`] });
    if (!granted) throw new AuthError(`The panel needs permission to reach ${new URL(server).host} and ${new URL(issuerFor(server)).host}.`);
    const config = await fetchConfig(server);
    await signIn(config);
    await load({ fromCache: false });
  } catch (e) {
    error.textContent = e.message || String(e);
    error.hidden = false;
  } finally {
    button.disabled = false;
  }
};

const use = (index, fetchedAt) => {
  data = index;
  if (data.version > API_VERSION) {
    showNotice("The site has a newer API than this extension knows. Please update the extension.");
  }
  $("brand").href = safeUrl(data.site?.url) || server + "/";
  $("updated").textContent = data.updated_at ? `Updated ${ago(data.updated_at)}` : "";
  $("updated").title = `Fetched ${new Date(fetchedAt).toLocaleString()}`;
  entries = flatten(data);
  render();
};

// One searchable entry per app and per doc, with the same fields the site's
// sidebar search looks in.
const flatten = (index) => [
  ...(index.groups || []).flatMap((group) =>
    (group.apps || []).map((app) => ({
      kind: "app", app, group: group.name,
      name: app.name,
      haystack: [app.name, app.description, group.name, app.address, app.url, app.owner,
        ...(app.links || []).map((l) => l.label)].join(" ").toLowerCase(),
    }))),
  ...(index.docs || []).map((doc) => ({
    kind: "doc", doc, group: "Docs",
    name: doc.title,
    haystack: [doc.title, doc.summary, doc.section, "docs"].join(" ").toLowerCase(),
  })),
];

const score = (entry, terms) => {
  const name = entry.name.toLowerCase();
  return terms.reduce((s, t) => s + (name.startsWith(t) ? 3 : name.includes(t) ? 2 : 1), 0);
};

// --- rendering ---------------------------------------------------------------
const searching = () => q.value.trim() !== "";

const render = () => {
  if (!data) return;
  selectedRow = null;
  if (searching()) renderHits(q.value.toLowerCase().split(/\s+/).filter(Boolean));
  else renderGroups();
};

const renderHits = (terms) => {
  const hits = entries
    .filter((e) => terms.every((t) => e.haystack.includes(t)))
    .sort((a, b) => score(b, terms) - score(a, terms))
    .slice(0, MAX_HITS);
  if (!hits.length) {
    list.replaceChildren(el("p", "empty", "Nothing matches."));
    return;
  }
  list.replaceChildren(...hits.map((e) => (e.kind === "app" ? appRow(e.app, e.group) : docRow(e.doc))));
  select(list.querySelector(".row"));
};

const renderGroups = () => {
  const sections = (data.groups || []).map((group) =>
    section(group.slug || group.name, group.name, group.apps.length, () => group.apps.map((app) => appRow(app))));
  if (data.docs?.length) {
    sections.push(section("docs", "Docs", data.docs.length, () => data.docs.map((doc) => docRow(doc))));
  }
  if (openGroup === undefined && sections.length) openGroup = sections[0].dataset.key;
  list.replaceChildren(...sections);
  const open = sections.find((s) => s.dataset.key === openGroup);
  if (open) openSection(open);
};

// A collapsible group. Only one is open at a time, so the list stays on what
// you're looking at; the panel remembers which.
const section = (key, title, count, rows) => {
  const details = el("details", "group");
  details.dataset.key = key;
  const summary = el("summary");
  summary.append(el("span", "group-name", title), el("span", "count", String(count)));
  details.append(summary);
  details.fillRows = rows; // built on first open: the technical groups can be long
  details.addEventListener("toggle", () => {
    if (details.open) openSection(details);
    else closeSection(details);
  });
  return details;
};

// Synchronous, so the keyboard can open a group and select in it straight away.
// Setting `open` also fires `toggle` later, which then finds nothing to do.
const openSection = (details) => {
  if (details.childElementCount === 1) details.append(...details.fillRows());
  details.open = true;
  for (const other of list.querySelectorAll("details.group[open]")) {
    if (other !== details) closeSection(other);
  }
  if (openGroup !== details.dataset.key) {
    openGroup = details.dataset.key;
    chrome.storage.local.set({ openGroup });
  }
};

const closeSection = (details) => {
  details.open = false;
  if (selectedRow && details.contains(selectedRow)) select(null);
  if (openGroup === details.dataset.key) {
    openGroup = null;
    chrome.storage.local.set({ openGroup });
  }
};

const iconTile = (app) => {
  const iconUrl = safeUrl(app.icon_url);
  if (iconUrl) {
    const tile = el("span", "icon icon-img");
    const img = el("img");
    img.src = iconUrl; img.alt = ""; img.loading = "lazy"; img.referrerPolicy = "no-referrer";
    tile.append(img);
    return tile;
  }
  if (app.icon) return el("span", "icon", app.icon);
  return el("span", "icon icon-initials", app.initials || "?");
};

// How it's reached and how you sign in. Unset is shown, never hidden.
const pill = (marker, unset, prefix) => {
  const node = el("span", `pill tone-${marker ? marker.tone : "unset"}`, marker ? marker.label : unset);
  node.title = marker ? `${prefix}: ${marker.label}` : `${prefix} not recorded`;
  return node;
};

// A row is one big button: a click anywhere on it (outside its own links)
// opens `href`, as does Enter when it's selected.
const row = (href) => {
  const node = el("article", "row");
  const url = safeUrl(href);
  if (url) node.dataset.href = url;
  return node;
};

const appRow = (app, group) => {
  const links = app.links || [];
  // The row opens the thing itself; the site's details page is one click further.
  const node = row(app.url || links[0]?.url || app.page_url || app.details_url);

  const head = el("div", "row-head");
  head.append(iconTile(app), link(node.dataset.href, "row-title", app.name));
  if (app.status && app.status !== "live") head.append(el("span", `badge badge-${app.status}`, app.status));
  // The viewer's role in one of our apps (added to the API by the index merge).
  const roles = Array.isArray(app.roles) && app.roles.length ? app.roles : (app.role ? [app.role] : []);
  if (roles.length) head.append(el("span", "role", roles.join(", ")));
  if (app.page_url) head.append(link(app.page_url, "row-more", "Details"));
  node.append(head);

  const meta = el("div", "row-meta");
  if (group) meta.append(el("span", "row-group", group));
  if (app.address) {
    const address = el("code", "address", app.address);
    address.title = "Click to copy";
    address.dataset.copy = app.address;
    meta.append(address);
  } else {
    meta.append(el("span", "row-desc", app.description));
  }
  node.append(meta);
  node.title = [app.description, app.owner && `Owner: ${app.owner}`].filter(Boolean).join("\n");

  const extras = el("div", "row-extras");
  for (const l of links) {
    const a = link(l.url, "chip", l.label);
    if (l.note) a.title = l.note;
    extras.append(a);
  }
  if (app.repo) extras.append(link(app.repo, "chip", "Repo"));
  const pills = el("span", "pills");
  pills.append(pill(app.access, "Access?", "Network access"), pill(app.login, "Login?", "Login"));
  extras.append(pills);
  node.append(extras);
  return node;
};

const docRow = (doc) => {
  const node = row(doc.url);
  const head = el("div", "row-head");
  head.append(el("span", "icon icon-doc", "📄"), link(doc.url, "row-title", doc.title));
  node.append(head);
  const meta = el("div", "row-meta");
  if (doc.section) meta.append(el("span", "row-group", doc.section));
  if (doc.summary) meta.append(el("span", "row-desc", doc.summary));
  node.append(meta);
  return node;
};

// --- keyboard ------------------------------------------------------------------
const select = (node) => {
  selectedRow?.classList.remove("selected");
  selectedRow = node;
  if (!node) return;
  node.classList.add("selected");
  // At the top of a group, keep its heading in view too.
  if (!node.previousElementSibling?.classList.contains("row")) {
    node.closest("details")?.querySelector("summary").scrollIntoView({ block: "nearest" });
  }
  node.scrollIntoView({ block: "nearest" });
};

const rowsIn = (scope) => [...scope.querySelectorAll(".row")];

// Up and down walk the rows. Without a search they stay in the open group;
// past its last row the next group opens (and this one closes), past its
// first row the previous one does. From the last group it wraps to the first.
const move = (delta) => {
  if (searching()) {
    const rows = rowsIn(list);
    if (!rows.length) return;
    const i = rows.indexOf(selectedRow);
    select(rows[(i + delta + rows.length) % rows.length]);
    return;
  }

  const groups = [...list.querySelectorAll("details.group")];
  if (!groups.length) return;
  const current = groups.findIndex((d) => d.open);
  if (current !== -1) {
    const rows = rowsIn(groups[current]);
    const i = rows.indexOf(selectedRow);
    const next = i === -1 ? (delta > 0 ? 0 : rows.length - 1) : i + delta;
    if (rows[next]) { select(rows[next]); return; }
  }

  const target = current === -1
    ? (delta > 0 ? 0 : groups.length - 1)
    : (current + delta + groups.length) % groups.length;
  openSection(groups[target]);
  const rows = rowsIn(groups[target]);
  select(delta > 0 ? rows[0] : rows[rows.length - 1]);
};

document.addEventListener("keydown", (ev) => {
  if (ev.target.closest?.("#settings")) return;
  const typing = ev.target === q;

  if (ev.key === "ArrowDown" || ev.key === "ArrowUp") {
    ev.preventDefault();
    move(ev.key === "ArrowDown" ? 1 : -1);
  } else if (ev.key === "Enter" && selectedRow && (typing || ev.target === document.body)) {
    ev.preventDefault();
    openTab(selectedRow.dataset.href, { background: ev.shiftKey });
  } else if (ev.key === "Escape") {
    if (q.value) { q.value = ""; render(); } else select(null);
  } else if (ev.key === "/" && !typing && !ev.metaKey && !ev.ctrlKey) {
    // "/" focuses search from anywhere in the panel, as on the site.
    ev.preventDefault();
    q.focus();
  }
});

q.addEventListener("input", render);

// A click on a row opens it; its own links, the Details link and the address
// keep their meaning. Cmd/Ctrl-click opens in the background.
list.addEventListener("click", (ev) => {
  const copy = ev.target.closest("[data-copy]");
  if (copy) {
    navigator.clipboard?.writeText(copy.dataset.copy).then(() => {
      copy.classList.add("copied");
      setTimeout(() => copy.classList.remove("copied"), 1200);
    });
    return;
  }
  if (ev.target.closest("a, button, summary")) return;
  const node = ev.target.closest(".row[data-href]");
  if (node) openTab(node.dataset.href, { background: ev.metaKey || ev.ctrlKey });
});

// --- the shortcut closes the panel ---------------------------------------------
// The background worker sends "close" down this port. It reconnects if the
// worker was stopped while idle, so the worker always knows the panel is open.
const connect = async () => {
  const { id } = await chrome.windows.getCurrent();
  const port = chrome.runtime.connect({ name: `panel:${id}` });
  port.onMessage.addListener((message) => { if (message.type === "close") window.close(); });
  port.onDisconnect.addListener(() => setTimeout(connect, 100));
};

// --- footer: refresh, account and settings ------------------------------------
$("refresh").addEventListener("click", () => load({ fromCache: false }));
$("signin-button").addEventListener("click", startSignIn);
$("signout").addEventListener("click", async () => {
  await signOut();
  await chrome.storage.local.remove("cache");
  load({ fromCache: false });
});

$("settings-toggle").addEventListener("click", () => {
  const form = $("settings");
  form.hidden = !form.hidden;
  $("settings-toggle").setAttribute("aria-expanded", String(!form.hidden));
  if (!form.hidden) { $("server").value = server; $("server").focus(); }
});

const saveServer = async (value) => {
  const error = $("settings-error");
  error.hidden = true;
  let origin;
  try {
    origin = new URL(value).origin;
    if (!/^https?:$/.test(new URL(value).protocol)) throw new Error();
  } catch {
    error.textContent = "That isn't an http(s) address.";
    error.hidden = false;
    return;
  }
  // Must run straight from the click: the browser only asks inside a user gesture. The auth host is asked for too.
  const granted = await chrome.permissions.request({ origins: [`${origin}/*`, `${issuerFor(origin)}/*`] });
  if (!granted) {
    error.textContent = `The panel needs permission to read ${origin} and ${issuerFor(origin)}.`;
    error.hidden = false;
    return;
  }
  // Another index means another sign-in.
  if (origin !== server) {
    await signOut();
    await chrome.storage.local.remove("cache");
  }
  await chrome.storage.local.set({ server: origin });
  $("settings").hidden = true;
  $("settings-toggle").setAttribute("aria-expanded", "false");
  load();
};

$("settings").addEventListener("submit", (ev) => { ev.preventDefault(); saveServer($("server").value.trim()); });
$("server-reset").addEventListener("click", () => saveServer(DEFAULT_SERVER));

connect();
load();
q.focus();
