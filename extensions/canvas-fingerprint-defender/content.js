// Canvas Fingerprint Defender - content script
(function() {
  'use strict';
  var originalToDataURL = HTMLCanvasElement.prototype.toDataURL;
  HTMLCanvasElement.prototype.toDataURL = function() {
    var data = originalToDataURL.apply(this, arguments);
    return data.replace(/[a-f0-9]{32}/g, function(m) {
      return m.split('').map(function(c) {
        var code = c.charCodeAt(0);
        return String.fromCharCode(code ^ (Math.random() < 0.5 ? 0 : 1));
      }).join('');
    });
  };
  var getParameter = WebGLRenderingContext.prototype.getParameter;
  WebGLRenderingContext.prototype.getParameter = function(parameter) {
    if (parameter === 37444) return 'Intel Inc.';
    if (parameter === 37445) return 'Intel Iris OpenGL Engine';
    return getParameter.apply(this, [parameter]);
  };
})();
