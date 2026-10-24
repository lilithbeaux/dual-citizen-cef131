(function () {
  'use strict';

  const AGENT_ID = 'dc_agent_' + Math.random().toString(36).slice(2, 10);
  const MAX_IFRAME_DEPTH = 5;
  const SELECTOR_TIMEOUT = 10000;
  const VISIBILITY_CHECK_INTERVAL = 100;

  const eventHandlers = new Map();
  const mutationObserver = new MutationObserver(handleMutations);
  const networkRequests = [];
  const consoleLogs = [];

  function getAllShadowRoots(root = document) {
    const roots = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT, null, false);
    let node;
    while (node = walker.nextNode()) {
      if (node.shadowRoot) roots.push(node.shadowRoot);
    }
    return roots;
  }

  function querySelectorAllDeep(selector, root = document) {
    const results = [];
    try { results.push(...root.querySelectorAll(selector)); } catch { }
    for (const sr of getAllShadowRoots(root)) {
      try { results.push(...sr.querySelectorAll(selector)); } catch { }
    }
    return results;
  }

  function querySelectorDeep(selector, root = document) {
    try {
      const el = root.querySelector(selector);
      if (el) return el;
    } catch { }
    for (const sr of getAllShadowRoots(root)) {
      try {
        const el = sr.querySelector(selector);
        if (el) return el;
      } catch { }
    }
    return null;
  }

  const SELECTOR_STRATEGIES = [
    s => s,
    s => s.replace(/^#/, '[id="'),
    s => s.replace(/^\./, '[class*="'),
    s => s.replace(/^\[([^\]]+)\]$/, '*[$1]'),
    s => s + ':not([hidden])',
    s => s.replace(/^(\w+)/, '*[$1]')
  ];

  function trySelectorVariants(selector) {
    for (const strategy of SELECTOR_STRATEGIES) {
      const variant = strategy(selector);
      const found = querySelectorDeep(variant);
      if (found) return { element: found, selector: variant };
    }
    return null;
  }

  function trySelectors(selectors) {
    for (const sel of selectors) {
      const result = trySelectorVariants(sel);
      if (result) return result;
    }
    return null;
  }

  function isVisible(element) {
    if (!element) return false;
    const style = getComputedStyle(element);
    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
    const rect = element.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return false;
    return true;
  }

  async function waitForVisible(element, timeout = 5000) {
    const start = Date.now();
    while (Date.now() - start < timeout) {
      if (isVisible(element)) return true;
      await new Promise(r => setTimeout(r, VISIBILITY_CHECK_INTERVAL));
    }
    return isVisible(element);
  }

  async function scrollIntoViewIfNeeded(element) {
    const rect = element.getBoundingClientRect();
    const vp = { w: window.innerWidth, h: window.innerHeight };
    if (rect.top < 0 || rect.bottom > vp.h || rect.left < 0 || rect.right > vp.w) {
      element.scrollIntoView({ behavior: 'smooth', block: 'center', inline: 'center' });
      await new Promise(r => setTimeout(r, 300));
    }
  }

  async function takeScreenshot(options = {}) {
    const { format = 'png', quality = 0.92, fullPage = false, selector = null } = options;
    let target = document.body;
    if (selector) {
      const result = trySelectorVariants(selector);
      if (result) target = result.element;
    }
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d');
    if (fullPage) {
      canvas.width = document.documentElement.scrollWidth;
      canvas.height = document.documentElement.scrollHeight;
      ctx.drawWindow(window, 0, 0, canvas.width, canvas.height, 'rgba(255,255,255,1)');
    } else {
      const rect = target.getBoundingClientRect();
      canvas.width = Math.min(rect.width, window.innerWidth);
      canvas.height = Math.min(rect.height, window.innerHeight);
      const x = Math.max(0, rect.left);
      const y = Math.max(0, rect.top);
      ctx.drawWindow(window, x, y, canvas.width, canvas.height, 'rgba(255,255,255,1)');
    }
    return new Promise(resolve => {
      canvas.toBlob(blob => {
        const reader = new FileReader();
        reader.onloadend = () => resolve(reader.result.split(',')[1]);
        reader.readAsDataURL(blob);
      }, `image/${format}`, quality);
    });
  }

  function getAllIframes(root = document, depth = 0) {
    if (depth > MAX_IFRAME_DEPTH) return [];
    const frames = [];
    const iframes = root.querySelectorAll('iframe, frame');
    for (const iframe of iframes) {
      try {
        if (iframe.contentDocument) {
          frames.push({ iframe, doc: iframe.contentDocument, depth });
          frames.push(...getAllIframes(iframe.contentDocument, depth + 1));
        }
      } catch { }
    }
    return frames;
  }

  async function findElement(selector, options = {}) {
    let result = trySelectors([selector, ...(options.fallbackSelectors || [])]);
    if (result) return result;
    if (!options.pierceIframes) return null;
    const frames = getAllIframes();
    for (const { doc } of frames) {
      const origQuery = querySelectorDeep;
      querySelectorDeep = (s, r = doc) => origQuery(s, r);
      result = trySelectors([selector, ...(options.fallbackSelectors || [])]);
      querySelectorDeep = origQuery;
      if (result) return { ...result, iframe: true };
    }
    return null;
  }

  function humanDelay(min = 50, max = 200) {
    const base = min + Math.random() * (max - min);
    const jitter = (Math.random() - 0.5) * 30;
    return new Promise(r => setTimeout(r, Math.max(1, base + jitter)));
  }

  function randomOffset(rect) {
    const padding = 3;
    return {
      x: rect.left + padding + Math.random() * Math.max(1, rect.width - padding * 2),
      y: rect.top + padding + Math.random() * Math.max(1, rect.height - padding * 2)
    };
  }

  function emit(event, data) {
    const handlers = eventHandlers.get(event) || [];
    for (const handler of handlers) {
      try { handler(data); } catch { }
    }
    postMessage({ type: 'event', event, data, agentId: AGENT_ID });
  }

  function handleMutations(mutations) {
    for (const mutation of mutations) {
      emit('mutation', {
        type: mutation.type,
        target: getSelector(mutation.target),
        addedNodes: Array.from(mutation.addedNodes).map(getSelector),
        removedNodes: Array.from(mutation.removedNodes).map(getSelector),
        attributeName: mutation.attributeName,
        oldValue: mutation.oldValue
      });
    }
  }

  function getSelector(node) {
    if (node.nodeType === Node.TEXT_NODE) return `#text: "${node.textContent?.slice(0, 50)}"`;
    if (node.id) return `#${node.id}`;
    if (node.className) return `.${node.className.split(' ')[0]}`;
    return node.tagName?.toLowerCase() || 'unknown';
  }

  function setupNetworkListener() {
    const originalFetch = window.fetch;
    window.fetch = async (...args) => {
      const start = Date.now();
      const response = await originalFetch(...args);
      networkRequests.push({
        url: args[0], method: args[1]?.method || 'GET', status: response.status,
        duration: Date.now() - start, timestamp: Date.now()
      });
      if (networkRequests.length > 100) networkRequests.shift();
      emit('network', { url: args[0], status: response.status });
      return response;
    };

    const originalXHR = window.XMLHttpRequest;
    window.XMLHttpRequest = function () {
      const xhr = new originalXHR();
      const originalOpen = xhr.open;
      xhr.open = function (method, url) {
        this._url = url; this._method = method;
        return originalOpen.apply(this, arguments);
      };
      const originalSend = xhr.send;
      xhr.send = function () {
        const start = Date.now();
        this.addEventListener('loadend', () => {
          networkRequests.push({
            url: this._url, method: this._method, status: this.status,
            duration: Date.now() - start, timestamp: Date.now()
          });
          if (networkRequests.length > 100) networkRequests.shift();
          emit('network', { url: this._url, status: this.status });
        });
        return originalSend.apply(this, arguments);
      };
      return xhr;
    };
  }

  function setupConsoleListener() {
    const originalLog = console.log, originalError = console.error, originalWarn = console.warn;
    console.log = (...args) => {
      consoleLogs.push({ type: 'log', args: args.map(String), timestamp: Date.now() });
      if (consoleLogs.length > 200) consoleLogs.shift();
      emit('console', { type: 'log', message: args.join(' ') });
      originalLog.apply(console, args);
    };
    console.error = (...args) => {
      consoleLogs.push({ type: 'error', args: args.map(String), timestamp: Date.now() });
      if (consoleLogs.length > 200) consoleLogs.shift();
      emit('console', { type: 'error', message: args.join(' ') });
      originalError.apply(console, args);
    };
    console.warn = (...args) => {
      consoleLogs.push({ type: 'warn', args: args.map(String), timestamp: Date.now() });
      if (consoleLogs.length > 200) consoleLogs.shift();
      emit('console', { type: 'warn', message: args.join(' ') });
      originalWarn.apply(console, args);
    };
  }

  function postMessage(message) {
    window.parent.postMessage({ ...message, source: 'dc_agent', agentId: AGENT_ID }, '*');
  }

  function sendResponse(id, result, error) {
    postMessage({ type: 'response', id, result, error: error?.message });
  }

  async function handleMessage(event) {
    if (event.source !== window.parent) return;
    const msg = event.data;
    if (!msg || msg.source !== 'browser_process' || msg.target !== AGENT_ID) return;

    const { id, command, params } = msg;
    try {
      let result;
      switch (command) {
        case 'click': result = await click(params.selector, params.options); break;
        case 'type': result = await type(params.selector, params.text, params.options); break;
        case 'scroll': result = await scroll(params.selector, params.x, params.y, params.options); break;
        case 'screenshot': result = await takeScreenshot(params.options); break;
        case 'query': result = await query(params.selector, params.attribute, params.options); break;
        case 'on': on(params.event, (data) => postMessage({ type: 'event', event: params.event, data, agentId: AGENT_ID })); result = { subscribed: true }; break;
        case 'getNetworkLogs': result = networkRequests; break;
        case 'getConsoleLogs': result = consoleLogs; break;
        case 'waitForSelector': result = await waitForSelector(params.selector, params.timeout); break;
        case 'executeScript': result = await executeScript(params.script, params.args); break;
        default: throw new Error(`Unknown command: ${command}`);
      }
      sendResponse(id, result);
    } catch (err) { sendResponse(id, null, err); }
  }

  function on(event, handler) {
    if (!eventHandlers.has(event)) eventHandlers.set(event, []);
    eventHandlers.get(event).push(handler);
    return () => { const arr = eventHandlers.get(event); const idx = arr.indexOf(handler); if (idx > -1) arr.splice(idx, 1); };
  }

  async function click(selector, options = {}) {
    const { fallbackSelectors, delay = true, force = false } = options;
    const selectors = [selector, ...(fallbackSelectors || [])];

    let result = trySelectors(selectors);
    if (!result) { await waitForSelector(selectors, options.timeout || SELECTOR_TIMEOUT); result = trySelectors(selectors); }
    if (!result) throw new Error(`Element not found: ${selector}`);

    await scrollIntoViewIfNeeded(result.element);
    await waitForVisible(result.element);

    if (delay) await humanDelay(50, 150);

    const rect = result.element.getBoundingClientRect();
    const target = randomOffset(rect);

    if (!force) {
      const events = ['mousemove', 'mouseover', 'mouseenter', 'mousedown', 'mouseup', 'click'];
      for (const evtType of events) {
        const evt = new MouseEvent(evtType, { bubbles: true, cancelable: true, view: window, clientX: target.x, clientY: target.y, screenX: target.x, screenY: target.y });
        result.element.dispatchEvent(evt);
        if (delay) await humanDelay(10, 40);
      }
    } else { result.element.click(); }

    emit('click', { selector: result.selector, target });
    return { success: true, selector: result.selector };
  }

  async function type(selector, text, options = {}) {
    const { fallbackSelectors, delay = true, clear = true, submit = false } = options;
    const selectors = [selector, ...(fallbackSelectors || [])];

    let result = trySelectors(selectors);
    if (!result) { await waitForSelector(selectors, options.timeout || SELECTOR_TIMEOUT); result = trySelectors(selectors); }
    if (!result) throw new Error(`Element not found: ${selector}`);

    await scrollIntoViewIfNeeded(result.element);
    await waitForVisible(result.element);

    const input = result.element;
    const isContentEditable = input.isContentEditable;
    const tag = input.tagName.toLowerCase();
    const isInput = ['input', 'textarea'].includes(tag);

    if (clear) { if (isContentEditable) input.textContent = ''; else if (isInput) input.value = ''; }

    input.focus();
    await humanDelay(50, 100);

    for (const char of text) {
      if (isContentEditable) document.execCommand('insertText', false, char);
      else if (isInput) { input.value += char; input.dispatchEvent(new Event('input', { bubbles: true })); }
      if (delay) await humanDelay(30, 120);
    }

    if (submit) {
      const form = input.closest('form');
      if (form) { const submitBtn = form.querySelector('button[type="submit"], input[type="submit"]'); if (submitBtn) await click(submitBtn, { force: true }); }
    }

    emit('type', { selector: result.selector, length: text.length });
    return { success: true, selector: result.selector, typed: text.length };
  }

  async function scroll(selector, x = 0, y = 0, options = {}) {
    const { fallbackSelectors, behavior = 'smooth' } = options;
    const selectors = [selector, ...(fallbackSelectors || [])];

    let result = trySelectors(selectors);
    if (!result) throw new Error(`Element not found: ${selector}`);

    const el = result.element;
    if (el === document.body || el === document.documentElement) window.scrollBy({ left: x, top: y, behavior });
    else el.scrollBy({ left: x, top: y, behavior });
    await humanDelay(100, 300);

    emit('scroll', { selector: result.selector, x, y });
    return { success: true, selector: result.selector };
  }

  async function query(selector, attribute = null, options = {}) {
    const { fallbackSelectors, all = false } = options;
    const selectors = [selector, ...(fallbackSelectors || [])];

    if (all) {
      const elements = [];
      for (const sel of selectors) {
        const found = querySelectorAllDeep(sel);
        if (found.length) {
          for (const el of found) elements.push(attribute ? el.getAttribute(attribute) : getElementData(el));
          if (elements.length) return elements;
        }
      }
      return [];
    }

    let result = trySelectors(selectors);
    if (!result && options.wait) { await waitForSelector(selectors, options.timeout || SELECTOR_TIMEOUT); result = trySelectors(selectors); }
    if (!result) return null;

    return attribute ? result.element.getAttribute(attribute) : getElementData(result.element);
  }

  function getElementData(el) {
    const rect = el.getBoundingClientRect();
    return { tag: el.tagName.toLowerCase(), id: el.id, class: el.className, text: el.textContent?.slice(0, 500), html: el.outerHTML?.slice(0, 2000), rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }, visible: isVisible(el), attributes: Array.from(el.attributes).reduce((acc, attr) => { acc[attr.name] = attr.value; return acc; }, {}) };
  }

  async function waitForSelector(selectors, timeout = SELECTOR_TIMEOUT) {
    const selectorList = Array.isArray(selectors) ? selectors : [selectors];
    return new Promise((resolve, reject) => {
      const start = Date.now();
      const check = () => {
        for (const sel of selectorList) { const result = trySelectors(sel); if (result) return resolve(result); }
        if (Date.now() - start > timeout) return reject(new Error(`Selector not found: ${selectorList.join(', ')}`));
        setTimeout(check, 100);
      };
      check();
    });
  }

  async function executeScript(script, args = []) {
    const fn = new Function(...Object.keys(args), script);
    return await fn(...Object.values(args));
  }

  function init() {
    mutationObserver.observe(document, { childList: true, subtree: true, attributes: true, characterData: true, attributeOldValue: true, characterDataOldValue: true });
    setupNetworkListener(); setupConsoleListener();
    window.addEventListener('message', handleMessage);
    postMessage({ type: 'ready', agentId: AGENT_ID, url: window.location.href });
    document.addEventListener('visibilitychange', () => emit('visibilitychange', { hidden: document.hidden }));
    window.addEventListener('beforeunload', () => { mutationObserver.disconnect(); postMessage({ type: 'unload', agentId: AGENT_ID }); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  window.dcAgent = { click, type, scroll, screenshot: takeScreenshot, query, on, waitForSelector, executeScript, getNetworkLogs: () => networkRequests, getConsoleLogs: () => consoleLogs, agentId: AGENT_ID };
})();