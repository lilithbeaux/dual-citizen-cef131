// User-Agent Switcher - background service worker
var EXT_ID = 'user-agent-switcher';
var EXT_NAME = 'User-Agent Switcher';

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
