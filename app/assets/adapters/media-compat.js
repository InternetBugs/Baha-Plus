(function () {
  if (location.origin !== 'https://ani.gamer.com.tw' || window.__bahaMediaCompatibility) return;
  window.__bahaMediaCompatibility = true;
  const original = new WeakMap();
  const attributes = ['crossorigin', 'playsinline', 'webkit-playsinline'];
  function prepare(media, source) {
    if (media?.tagName !== 'VIDEO') return;
    const raw = source ?? (media.getAttribute('src') ||
      media.querySelector('source[src]')?.getAttribute('src'));
    let hls = false;
    try {
      const url = new URL(raw || '', location.href);
      hls = url.origin === 'https://bahamut.akamaized.net' &&
        /\.m3u8$/i.test(url.pathname);
    } catch (_) {}
    if (!hls) {
      const saved = original.get(media);
      if (saved) {
        attributes.forEach((name, index) => {
          if (saved[index] === null) media.removeAttribute(name);
          else media.setAttribute(name, saved[index]);
        });
        original.delete(media);
      }
      return;
    }
    if (!original.has(media)) {
      original.set(media, attributes.map(name => media.getAttribute(name)));
    }
    // Native iOS HLS requests otherwise receive 403 for these official streams.
    // Apply before source assignment so the first request uses CORS media mode.
    media.setAttribute('crossorigin', 'anonymous');
    media.setAttribute('playsinline', '');
    media.setAttribute('webkit-playsinline', '');
  }
  const prototype = HTMLMediaElement.prototype;
  const source = Object.getOwnPropertyDescriptor(prototype, 'src');
  if (source?.set && source.configurable) {
    Object.defineProperty(prototype, 'src', {
      ...source,
      set(value) {
        prepare(this, value);
        return source.set.call(this, value);
      }
    });
  }
  const load = prototype.load;
  prototype.load = function (...args) {
    prepare(this);
    return Reflect.apply(load, this, args);
  };
  function scan(node) {
    if (node?.tagName === 'SOURCE') prepare(node.parentElement);
    else prepare(node);
    node?.querySelectorAll?.('video')?.forEach(media => prepare(media));
  }
  new MutationObserver(records => {
    for (const record of records) {
      if (record.type === 'attributes') scan(record.target);
      else record.addedNodes.forEach(scan);
    }
  }).observe(document, {childList: true, subtree: true, attributes: true, attributeFilter: ['src']});
  document.querySelectorAll('video').forEach(media => prepare(media));
})();
