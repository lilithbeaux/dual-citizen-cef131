// Header Injector - popup controller
document.addEventListener('DOMContentLoaded', function() {
  var btn = document.getElementById('btn');
  var status = document.getElementById('status');
  btn.addEventListener('click', function() {
    chrome.tabs.query({active: true, currentWindow: true}, function(tabs) {
      chrome.runtime.sendMessage({action: 'activate'}, function(response) {
        status.textContent = response ? response.status : 'Done';
      });
    });
  });
  chrome.runtime.sendMessage({action: 'status'}, function(response) {
    if (response && response.status) status.textContent = response.status;
  });
});
