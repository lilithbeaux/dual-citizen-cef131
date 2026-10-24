// Proxy Manager - background service worker
var EXT_ID = 'proxy-manager';
var EXT_NAME = 'Proxy Manager';

chrome.runtime.onInstalled.addListener(function() {
  chrome.storage.local.set({EXT_ID + '_enabled': true});
  chrome.runtime.sendMessage({action: 'status', status: 'Initialized'});
});

chrome.runtime.onMessage.addListener(function(request, sender, sendResponse) {
  if (request.action === 'activate') {
    chrome.storage.local.set({EXT_ID + '_enabled': true});
    sendResponse({status: 'Activated'});
  } else if (request.action === 'status') {
    chrome.storage.local.get([EXT_ID + '_enabled'], function(result) {
      sendResponse({status: result[EXT_ID + '_enabled'] ? 'Active' : 'Inactive'});
    });
    return true;
  } else if (request.action === 'toggle') {
    chrome.storage.local.get([EXT_ID + '_enabled'], function(result) {
      var enabled = !result[EXT_ID + '_enabled'];
      chrome.storage.local.set({EXT_ID + '_enabled': enabled}, function() {
        sendResponse({status: enabled ? 'Activated' : 'Deactivated', enabled: enabled});
      });
    });
    return true;
  }
});

chrome.runtime.onMessage.addListener(function(request, sender, sendResponse) {
  if (request.action === 'set_proxy') {
    var proxy = {host: request.host || '', port: request.port || 0, enabled: request.enabled};
    chrome.storage.local.set({'proxy-manager_proxy': proxy}, function() {
      var pac = proxy.enabled && proxy.host
        ? 'PROXY ' + proxy.host + ':' + proxy.port + '; DIRECT'
        : 'DIRECT';
      console.log('[Proxy Manager] PAC config:', pac);
      sendResponse({status: 'Proxy set', proxy: proxy});
    });
    return true;
  } else if (request.action === 'get_proxy') {
    chrome.storage.local.get(['proxy-manager_proxy'], function(result) {
      var p = result['proxy-manager_proxy'] || {host:'', port:0, enabled:false};
      sendResponse({status: 'ok', proxy: p});
    });
    return true;
  }
});
