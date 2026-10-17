// The toolbar button opens the side panel; the shortcut (toggle-panel) opens
// or closes it.
chrome.sidePanel.setPanelBehavior({ openPanelOnActionClick: true }).catch(console.error);

// Each open panel holds a port named after its window, so the shortcut can
// tell open from closed without an async lookup: sidePanel.open() only works
// straight from the key press, before anything is awaited.
const panels = new Map(); // windowId → port

chrome.runtime.onConnect.addListener((port) => {
  if (!port.name.startsWith("panel:")) return;
  const windowId = Number(port.name.slice("panel:".length));
  panels.set(windowId, port);
  port.onDisconnect.addListener(() => {
    if (panels.get(windowId) === port) panels.delete(windowId);
  });
});

chrome.commands.onCommand.addListener((command, tab) => {
  if (command !== "toggle-panel" || !tab) return;
  const windowId = tab.windowId;
  const port = panels.get(windowId);
  if (!port) chrome.sidePanel.open({ windowId }).catch(console.error);
  // sidePanel.close() is newer (Chrome 141); before that the panel closes itself.
  else if (chrome.sidePanel.close) chrome.sidePanel.close({ windowId }).catch(() => port.postMessage({ type: "close" }));
  else port.postMessage({ type: "close" });
});
