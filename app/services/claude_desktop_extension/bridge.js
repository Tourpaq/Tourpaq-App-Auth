#!/usr/bin/env node
// Tourpaq MCP Gateway for Claude Desktop (Tourpaq Auth SPECS.md §25.8): a bridge between Claude Desktop (MCP over
// stdio) and the MCP Gateway (MCP Streamable HTTP, JSON answers). No dependencies: it runs on the Node.js that ships
// with Claude Desktop (fetch, Node 18 or later).
//
//   TOURPAQ_MCP_URL    the gateway's endpoint, e.g. https://mcp.app.journeybooking.eu/mcp (set by manifest.json)
//   TOURPAQ_MCP_TOKEN  the person's gateway token, tpa_mcp_… (asked for when the extension is installed; Claude
//                      Desktop keeps it in the system keychain)
//
// Each JSON-RPC line from Claude Desktop is POSTed as it is; the answer (JSON, or the data lines of an SSE answer) is
// written back as one line. A failure that is not a JSON-RPC answer becomes an error for the request, so Claude shows
// the reason instead of waiting. The token never appears in any output or log.
"use strict";

const readline = require("node:readline");

const ENDPOINT = (process.env.TOURPAQ_MCP_URL || "").trim();
const TOKEN = (process.env.TOURPAQ_MCP_TOKEN || "").trim().replace(/^Bearer\s+/i, "");
const TIMEOUT_MS = 5 * 60 * 1000;
const TOKENS_PAGE = "the Tokens page of Tourpaq Auth (index.app.journeybooking.eu/tokens)";

let sessionId = null;
const pending = new Set();

const log = (message) => process.stderr.write(`[tourpaq-mcp] ${message}\n`);
const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);

// An error answer for every request (a message with an id and a method) in what Claude Desktop sent.
function fail(sent, code, message) {
  for (const m of [].concat(sent)) {
    if (m && typeof m === "object" && m.method && m.id !== undefined && m.id !== null) {
      send({ jsonrpc: "2.0", id: m.id, error: { code, message } });
    }
  }
}

function hint(status) {
  if (status === 401) return ` Your token may be expired or revoked: create a new one on ${TOKENS_PAGE} and set it in Claude Desktop → Settings → Extensions.`;
  if (status === 403) return " You may have no MCP access to any app: ask an admin of Tourpaq Auth.";
  return "";
}

async function forward(line) {
  let sent;
  try {
    sent = JSON.parse(line);
  } catch {
    send({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
    return;
  }
  if (!ENDPOINT) return fail(sent, -32000, "The extension has no gateway URL. Download it again from " + TOKENS_PAGE + ".");
  if (!TOKEN.startsWith("tpa_mcp_")) {
    return fail(sent, -32001, `No MCP Gateway token (tpa_mcp_…). Create one on ${TOKENS_PAGE} and set it in Claude Desktop → Settings → Extensions → Tourpaq MCP Gateway.`);
  }

  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json, text/event-stream",
    Authorization: `Bearer ${TOKEN}`,
  };
  if (sessionId) headers["Mcp-Session-Id"] = sessionId;

  let response;
  try {
    response = await fetch(ENDPOINT, { method: "POST", headers, body: line, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch (error) {
    const reason = error?.cause?.code || error?.name || "network error";
    return fail(sent, -32000, `The MCP Gateway cannot be reached at ${ENDPOINT} (${reason}). Are you connected to NetBird?`);
  }

  const id = response.headers.get("mcp-session-id");
  if (id) sessionId = id;
  const text = await response.text();
  if (response.status === 202 || !text.trim()) {
    if (!response.ok) fail(sent, -32000, `The MCP Gateway answered HTTP ${response.status}.${hint(response.status)}`);
    return;
  }

  const type = response.headers.get("content-type") || "";
  const bodies = type.includes("text/event-stream")
    ? text.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).filter(Boolean)
    : [text];

  for (const body of bodies) {
    let answer;
    try {
      answer = JSON.parse(body);
    } catch {
      fail(sent, -32000, `The MCP Gateway answered HTTP ${response.status}: ${body.slice(0, 200)}${hint(response.status)}`);
      continue;
    }
    // The gateway answers a refused request (401, 403, 429, 503) with a JSON-RPC error without the request's id:
    // give it the id, so Claude Desktop sees the reason.
    if (!response.ok && answer && !Array.isArray(answer) && answer.error && (answer.id === undefined || answer.id === null)) {
      fail(sent, answer.error.code ?? -32000, `${answer.error.message} (HTTP ${response.status}).${hint(response.status)}`);
      continue;
    }
    send(answer);
  }
}

const input = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on("line", (line) => {
  if (!line.trim()) return;
  const work = forward(line).catch((error) => log(`unexpected error: ${error?.message || error}`));
  pending.add(work);
  work.finally(() => pending.delete(work));
});
input.on("close", async () => {
  await Promise.allSettled([...pending]);
  process.exit(0);
});
