// Web Request Controller - background service worker
var EXT_ID = 'web-request-controller';
var EXT_NAME = 'Web Request Controller';

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

// Web request blocking / redirecting per account profile
chrome.runtime.onMessage.addListener(function(request, sender, sendResponse) {
  if (request.action === 'block_url') {
    chrome.storage.local.get(['web-request-controller_blocklist'], function(result) {
      var list = result['web-request-controller_blocklist'] || [];
      if (request.url && list.indexOf(request.url) === -1) list.push(request.url);
      chrome.storage.local.set({'web-request-controller_blocklist': list});
      sendResponse({status: 'Blocked: ' + request.url});
    });
    return true;
  } else if (request.action === 'get_block_list') {
    chrome.storage.local.get(['web-request-controller_blocklist'], function(result) {
      sendResponse({status: 'ok', list: result['web-request-controller_blocklist'] || []});
    });
    return true;
  }
});

chrome.webRequest.onBeforeRequest.addListener(
  function(details) {
    // Check block list for redirects
    return chrome.storage.local.get(['web-request-controller_blocklist']).then(function(result) {
      var list = result['web-request-controller_blocklist'] || [];
      var matched = false;
      for (var i = 0; i < list.length; i++) {
        try {
          if (new RegExp(list[i]).test(details.url)) {
            matched = true;
            break;
          }
        } catch(e) {}
      }
      if (matched) {
        return {cancel: true};
      }
      return {};
    });
  },
  {urls: ['<all_urls>']},
  ['blocking']
);
