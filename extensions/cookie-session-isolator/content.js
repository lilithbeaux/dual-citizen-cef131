// Content script for session isolation
(function() {
  'use strict';
  document.documentElement.setAttribute('data-session-isolated', 'true');
  console.log('[Extension] Session isolation active on', window.location.hostname);
})();
