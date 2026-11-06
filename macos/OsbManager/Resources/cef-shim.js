(function (post) {
  const listeners = new Set();
  const webview = Object.freeze({
    postMessage: message => {
      const json = JSON.stringify(message);
      if (typeof json === 'string') post(json);
    },
    addEventListener: (type, listener) => { if (type === 'message' && typeof listener === 'function') listeners.add(listener); },
    removeEventListener: (type, listener) => { listeners.delete(listener); },
  });
  window.chrome = window.chrome || {};
  Object.defineProperty(window.chrome, 'webview', { value: webview });
  return json => {
    let data;
    try { data = JSON.parse(json); } catch (error) { return; }
    for (const listener of [...listeners]) {
      try { listener({ data }); } catch (error) { setTimeout(() => { throw error; }); }
    }
  };
})
