// Tab Isolator - background service worker
var EXT_ID = 'tab-isolator';
var EXT_NAME = 'Tab Isolator';

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

// Session cookie isolation helper - clear session cookies for profile reset
chrome.runtime.onMessage.addListener(function(request, sender, sendResponse) {
  if (request.action === 'clear_cookies') {
    chrome.cookies.getAll({"session": true}, function(cookies) {
      cookies.forEach(function(c) {
        chrome.cookies.remove({url: (c.secure ? 'https://' : 'http://') + c.domain + '/', name: c.name});
      });
      sendResponse({status: 'Cleared ' + cookies.length + ' session cookies'});
    });
    return true;
  } else if (request.action === 'clear_all_cookies') {
    chrome.cookies.getAll({}, function(cookies) {
      cookies.forEach(function(c) {
        chrome.cookies.remove({url: (c.secure ? 'https://' : 'http://') + c.domain + '/', name: c.name});
      });
      sendResponse({status: 'Cleared ' + cookies.length + ' cookies'});
    });
    return true;
  }
});
