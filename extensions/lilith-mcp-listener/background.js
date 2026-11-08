// Lilith-MCP Listener — background service worker
// Receives events from content scripts, relays to external agent via CEF socket,
// and accepts MCP commands from the agent to distribute to content scripts.

const SOCKET_SCHEME = 'mcp://';
const CONTROL_URL = 'mcp://control';

let contentPorts = new Map(); // tabId => port

// ---- Relay content-script events to the external agent ----
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.kind === 'events') {
    // Forward to agent via mcp:// scheme POST (handled by CEF scheme handler)
    fetch(CONTROL_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ kind: 'events', batch: message.batch, sender: { tab: sender.tab, url: sender.url } })
    }).catch(() => {}); // fire-and-forget; socket may buffer
    sendResponse({ ok: true });
    return true;
  }
  if (message.kind === 'mcp_command') {
    // Agent -> extension: execute on a specific tab/frame
    handleMCPCommand(message).then(sendResponse).catch((e) => sendResponse({ ok: false, error: String(e) }));
    return true;
  }
  return false;
});

// ---- Connect ports from content scripts (for direct tab-scoped commands) ----
chrome.runtime.onConnect.addListener((port) => {
  if (port.name === 'lilith-content') {
    const tabId = port.sender.tab?.id;
    if (tabId) contentPorts.set(tabId, port);
    port.onDisconnect.addListener(() => {
      if (tabId) contentPorts.delete(tabId);
    });
  }
});

// ---- MCP command handler (agent -> browser) ----
async function handleMCPCommand(cmd) {
  const { action, tabId, params } = cmd;
  try {
    switch (action) {
      case 'register_listener':
      case 'unregister_listener':
      case 'list_listeners':
      case 'evaluate':
      case 'click':
      case 'fill':
      case 'title':
      case 'url':
      case 'form_fields': {
        // Deliver to content script of target tab
        const port = contentPorts.get(tabId);
        if (port) {
          port.postMessage({ kind: 'mcp_command', cmd: cmd });
          return { ok: true, delivered: true };
        }
        // Fallback: use scripting.executeScript
        await chrome.scripting.executeScript({
          target: { tabId, allFrames: true },
          func: (c) => {
            const api = window.__lilithMCP;
            if (!api) return { ok: false, error: 'listener not ready' };
            switch (c.action) {
              case 'register_listener': return api.registerListener(c.params);
              case 'unregister_listener': return api.unregisterListener(c.params.id);
              case 'list_listeners': return api.listListeners();
              case 'evaluate': return api.evaluate(c.params.code);
              case 'click': return api.click(c.params.selector);
              case 'fill': return api.fill(c.params.fields);
              case 'title': return api.title();
              case 'url': return api.url();
              case 'form_fields': return api.formFields();
              default: return { ok: false, error: 'unknown action' };
            }
          },
          args: [cmd]
        });
        return { ok: true, delivered: false, via: 'scripting' };
      }
      case 'navigate': {
        await chrome.tabs.update(tabId, { url: params.url });
        return { ok: true };
      }
      case 'screenshot': {
        const data = await chrome.tabs.captureVisibleTab(tabId, { format: 'png' });
        return { ok: true, screenshot: data };
      }
      default:
        return { ok: false, error: 'unknown action: ' + action };
    }
  } catch (e) {
    return { ok: false, error: String(e) };
  }
}

// ---- Initialize: inject listener into existing tabs on install/update ----
chrome.runtime.onInstalled.addListener(async () => {
  const tabs = await chrome.tabs.query({});
  for (const t of tabs) {
    if (t.url && t.url.startsWith('http')) {
      try { await chrome.scripting.executeScript({ target: { tabId: t.id, allFrames: true }, files: ['content.js'] }); } catch (e) {}
    }
  }
});

console.log('[Lilith-MCP] Background worker ready');
