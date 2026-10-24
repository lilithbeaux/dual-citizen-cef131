// User-Agent Switcher - content script (UA handled via background webRequest)
(function() {
  'use strict';
  if (window.top === window) {
    console.log('[User-Agent Switcher] Active UA:', navigator.userAgent);
  }
})();
