(function() {
  if (location.origin !== 'https://ani.gamer.com.tw') return;
  // Only login identity crosses this bridge. Account collections and
  // history are fetched independently by the native HTTP client.
  window.__bahaAccountSync?.dispose();
  const ticket = window.__bahaDocumentNonce, source = location.href;
  const watch = __BAHA_WATCH_ACCOUNT__;
  let disposed = false, observer, interval, lastIdentity;
  const watcher = {dispose() {
    disposed = true;
    observer?.disconnect();
    clearInterval(interval);
    window.removeEventListener('message', loginFinished);
    window.removeEventListener('pagehide', watcher.dispose);
  }};
  window.__bahaAccountSync = watcher;
  function live() {
    return !disposed && location.href === source &&
      window.__bahaDocumentNonce === ticket && window.__bahaAccountSync === watcher;
  }
  function post(value) { if (live()) bahaPostJSON(JSON.stringify(value)); }
  function check() {
    if (!live()) { watcher.dispose(); return; }
    const login = window.User?.Login;
    const user = document.querySelector('a.user-info');
    const id = typeof login?.getUserid === 'function' ? login.getUserid() :
      user?.querySelector('.user-id')?.textContent.trim();
    const guest = typeof login?.getUserid === 'function' ?
      !id || String(id).toLowerCase() === 'guest' :
      !id && !!document.querySelector('a[href*="user.gamer.com.tw/login.php"]');
    if (!id && !guest) {
      if (!watch) post({type:'account-error'});
      return;
    }
    const key = guest ? 'guest' : String(id).toLowerCase();
    if (key === lastIdentity) return;
    lastIdentity = key;
    if (guest) {
      post({type:'account-guest'});
      return;
    }
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) {
      post({type:'account-error'});
      return;
    }
    let details;
    try { details = login?.getUser?.(); } catch (_) {}
    if (details?.userid && String(details.userid).toLowerCase() !== key) {
      lastIdentity = undefined;
      post({type:'account-error'});
      return;
    }
    const image = user?.querySelector('.avatar img');
    const raw = details?.avatarUrl?.big || details?.avatarUrl?.small ||
      image?.getAttribute('data-src') || image?.getAttribute('src');
    let avatar;
    try {
      const uri = new URL(raw, location.origin);
      if (uri.protocol === 'https:' && uri.hostname.endsWith('.bahamut.com.tw') &&
          !uri.username && !uri.password && (!uri.port || uri.port === '443')) {
        avatar = uri.href;
      }
    } catch (_) {}
    post({type:'account-authenticated', profile:{
      id, displayName:details?.nickname ||
        user?.querySelector('.user-name')?.textContent.trim() || id,
      ...(avatar ? {avatar} : {})
    }});
    watcher.dispose();
  }
  function loginFinished(event) {
    if (event.origin === 'https://user.gamer.com.tw' && event.data === 'LoginFinish' &&
        Array.from(document.querySelectorAll('iframe')).some(frame => frame.contentWindow === event.source)) {
      check();
    }
  }
  if (watch) {
    observer = new MutationObserver(check);
    observer.observe(document.documentElement,{childList:true,subtree:true,characterData:true});
    interval = setInterval(check,500);
    window.addEventListener('message',loginFinished);
    window.addEventListener('pagehide',watcher.dispose);
  }
  check();
  if (!watch) watcher.dispose();
})(); true;
