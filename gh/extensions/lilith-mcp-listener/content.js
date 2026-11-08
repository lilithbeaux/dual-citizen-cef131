// Lilith-MCP Listener — content script
// Runs on EVERY page, ALL frames, document_start.
// Programmable listener: DOM mutations, network, console, navigation, visibility.
// Exposes a local MCP command channel that the background worker bridges to the
// external agent via the CEF Unix socket (mcp:// scheme / cefQuery router).

(function () {
  'use strict';

  const FRAME_ID = Math.random().toString(36).slice(2, 10);
  const IS_MAIN = window.top === window.self;

  // ---- State: registered listeners (from external agent) ----
  const listeners = new Map(); // id => {type, selector, condition, once, fired, cbRef}
  let listenerSeq = 0;

  // ---- Event buffer (for push to agent via background worker / socket) ----
  const eventQueue = [];
  const MAX_QUEUE = 500;
  let flushTimer = null;

  function enqueue(ev) {
    if (eventQueue.length >= MAX_QUEUE) eventQueue.shift();
    eventQueue.push({ frame: FRAME_ID, isMain: IS_MAIN, ts: Date.now(), ...ev });
    scheduleFlush();
  }

  function scheduleFlush() {
    if (flushTimer) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      const batch = eventQueue.splice(0, eventQueue.length);
      if (batch.length) pushEvents(batch);
    }, 250);
  }

  // ---- DOM mutation listener ----
  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      enqueue({ type: 'dom', target: m.target.tagName, addedNodes: m.addedNodes.length, removedNodes: m.removedNodes.length, attributeName: m.attributeName });

      // Check registered DOM listeners
      for (const [id, l] of listeners) {
        if (l.type !== 'dom') continue;
        if (l.selector && m.target.matches && m.target.matches(l.selector)) {
          fireListener(id, { kind: 'dom', mutation: m });
        }
      }
    }
  });

  if (document.documentElement) {
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeOldValue: false,
      characterData: false
    });
  }

  // ---- Network listener (fetch + XHR interception at page level) ----
  const origFetch = window.fetch;
  window.fetch = async function (input, init) {
    const url = String(input);
    const start = Date.now();
    enqueue({ type: 'network', method: (init && init.method) || 'GET', url, status: 'request' });
    try {
      const res = await origFetch(input, init);
      enqueue({ type: 'network', method: (init && init.method) || 'GET', url, status: res.status, duration: Date.now() - start });
      return res;
    } catch (e) {
      enqueue({ type: 'network', method: (init && init.method) || 'GET', url, status: 'error', error: String(e) });
      throw e;
    }
  };

  // ---- Console listener ----
  const origLog = console.log.bind(console);
  const origWarn = console.warn.bind(console);
  const origError = console.error.bind(console);
  console.log = (...args) => { enqueue({ type: 'console', level: 'log', args: args.map(String) }); origLog(...args); };
  console.warn = (...args) => { enqueue({ type: 'console', level: 'warn', args: args.map(String) }); origWarn(...args); };
  console.error = (...args) => { enqueue({ type: 'console', level: 'error', args: args.map(String) }); origError(...args); };

  // ---- Navigation / URL change listener ----
  let lastUrl = location.href;
  const urlInterval = setInterval(() => {
    if (location.href !== lastUrl) {
      const old = lastUrl;
      lastUrl = location.href;
      enqueue({ type: 'navigation', from: old, to: lastUrl });
    }
  }, 1000);

  // ---- Visibility change ----
  document.addEventListener('visibilitychange', () => {
    enqueue({ type: 'visibility', hidden: document.hidden });
  });

  // ---- Listener firing ----
  function fireListener(id, detail) {
    const l = listeners.get(id);
    if (!l) return;
    if (l.once && l.fired) return;
    if (l.once) l.fired = true;
    enqueue({ type: 'listener_fired', listenerId: id, detail });
    pushEvents([{ type: 'listener_fired', listenerId: id, detail, frame: FRAME_ID, ts: Date.now() }]);
  }

  // ---- Local MCP command channel (from background worker / injected script) ----
  window.__lilithMCP = {
    registerListener(spec) {
      const id = 'l_' + (++listenerSeq) + '_' + Date.now().toString(36);
      listeners.set(id, { ...spec, id, fired: false, created: Date.now() });
      return { ok: true, id };
    },
    unregisterListener(id) {
      return { ok: listeners.delete(id) };
    },
    listListeners() {
      return { ok: true, listeners: Array.from(listeners.entries()).map(([k, v]) => ({ id: k, type: v.type, selector: v.selector, fired: v.fired })) };
    },
    evaluate(code) {
      try {
        const result = (0, eval)(code);
        return { ok: true, result: String(result) };
      } catch (e) {
        return { ok: false, error: String(e) };
      }
    },
    click(selector) {
      const el = document.querySelector(selector);
      if (!el) return { ok: false, error: 'element not found' };
      el.click();
      return { ok: true };
    },
    fill(fields) {
      try {
        const f = typeof fields === 'string' ? JSON.parse(fields) : fields;
        Object.keys(f).forEach((k) => {
          const el = document.querySelector('[name="' + k + '"]') || document.getElementById(k);
          if (el) { el.value = f[k]; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); }
        });
        return { ok: true, filled: Object.keys(f).length };
      } catch (e) { return { ok: false, error: String(e) }; }
    },
    title() { return { ok: true, title: document.title }; },
    url() { return { ok: true, url: location.href }; },
    formFields() {
      const fields = Array.from(document.querySelectorAll('input,select,textarea')).map((el) => ({
        tag: el.tagName, name: el.name || '', id: el.id || '', type: el.type || '', value: el.value || ''
      }));
      return { ok: true, fields };
    }
  };

  // Push events to background worker (which relays to socket via cefQuery / mcp://)
  function pushEvents(batch) {
    try {
      if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.sendMessage) {
        chrome.runtime.sendMessage({ kind: 'events', batch });
      }
    } catch (e) {
      // background may not be ready; queue will retry on next flush
    }
  }

  // Expose on window for background worker injection discovery
  window.__lilithFrameId = FRAME_ID;
  window.__lilithIsMain = IS_MAIN;

})();
