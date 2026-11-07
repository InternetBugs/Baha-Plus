(async function () {
  // Executed with callAsyncJavaScript in the session-owned official document.
  // Only these projections leave WebView; cookies and CSRF tokens stay here.
  const request = __BAHA_COMMUNITY_REQUEST__;
  const { action, args } = request;
  const readOnly = ['comments', 'replies', 'notifications', 'notification-target'].includes(action);
  const ticket = window.__bahaDocumentNonce;
  const documentURL = location.href;
  const origin = 'https://ani.gamer.com.tw';
  const id = value => /^\d{1,20}$/.test(String(value ?? ''));
  const videoId = value => /^\d{1,10}$/.test(String(value ?? ''));
  const fail = code => { throw Object.assign(new Error(code), { code }); };
  const owner = () => {
    const login = window.User?.Login;
    const value = typeof login?.getUserid === 'function' ? login.getUserid() :
      document.querySelector('a.user-info .user-id')?.textContent.trim() || '';
    return /^[A-Za-z0-9_-]{1,64}$/.test(value) && value.toLowerCase() !== 'guest' ? value : '';
  };
  const initialOwner = owner().toLowerCase();
  const live = () => {
    if (location.origin !== origin || location.href !== documentURL ||
        (!readOnly && window.__bahaDocumentNonce !== ticket) ||
        owner().toLowerCase() !== initialOwner) fail('stale');
  };
  const login = () => {
    live();
    if (!initialOwner ||
        (typeof window.User?.Login?.getUserid !== 'function' && !document.querySelector('.btn-logout')) ||
        (args.owner && args.owner.toLowerCase() !== initialOwner)) fail('login');
  };
  const allowed = new Set([
    `${origin}/ajax/getCSRFToken.php`, `${origin}/ajax/danmuSet.php`,
    `${origin}/animeVideo.php`,
    'https://wall.gamer.com.tw/app/v2/comment_detail.php',
    'https://wall.gamer.com.tw/app/v1/reply_detail.php',
    'https://wall.gamer.com.tw/app/v1/comment_new.php',
    'https://wall.gamer.com.tw/app/v1/comment_like.php',
    'https://wall.gamer.com.tw/app/v1/comment_like_del.php',
    'https://api.gamer.com.tw/ajax/common/topBar.php'
  ]);
  const text = (value, max) => {
    if (typeof value !== 'string' || value.length > max) fail('format');
    return value;
  };
  function image(value) {
    if (!value) return null;
    const uri = new URL(value, origin);
    return uri.protocol === 'https:' && uri.hostname.endsWith('.bahamut.com.tw') &&
      !uri.username && !uri['pass' + 'word'] && (!uri.port || uri.port === '443') ? uri.href : null;
  }
  async function fetchOfficial(url, options = {}, asText = false) {
    live();
    const target = new URL(url);
    if (!allowed.has(target.origin + target.pathname) ||
        target.username || target['pass' + 'word']) fail('endpoint');
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), 12000);
    try {
      const response = await fetch(target.href, {
        ...options, credentials: 'include', signal: abort.signal
      });
      live();
      const finalURL = new URL(response.url);
      if (!response.ok || finalURL.origin !== target.origin ||
          finalURL.pathname !== target.pathname) fail('network');
      const raw = await response.text();
      live();
      if (new TextEncoder().encode(raw).byteLength > 2000000) fail('format');
      return asText ? raw : JSON.parse(raw);
    } finally { clearTimeout(timer); }
  }
  function comments(raw) {
    if (!Array.isArray(raw) || raw.length > 200) fail('format');
    return raw.map(item => {
      if (!id(item.id)) fail('format');
      return {
        id: String(item.id), name: text(item.name, 200), userId: String(item.userid),
        text: text(item.text || '', 20000), time: String(item.time || ''),
        avatar: image(item.propic), image: image(item.image?.B),
        likes: Number(item.likeCount || 0), dislikes: Number(item.dislikeCount || 0),
        replies: Number(item.commentCount || item.children || 0),
        vote: Math.sign(Number(item.isLike || 0)), folded: item.isFolded === true
      };
    });
  }
  function csrf() {
    login();
    if (!window.Bahamut?.Csrf) fail('unavailable');
    const token = new window.Bahamut.Csrf();
    token.setCookie();
    return token.getJqueryHeaders();
  }
  const locks = window.__bahaCommunityLocks ||= new Set();
  let lock;
  try {
    live();
    if (action === 'notification-target') {
      if (!videoId(args.videoId)) fail('input');
      const url = new URL('/animeVideo.php', origin);
      url.searchParams.set('sn', args.videoId);
      const doc = new DOMParser().parseFromString(await fetchOfficial(url, {}, true), 'text/html');
      const sn = doc.querySelector('.anime_name button[onclick*="toggleGather"]')
        ?.getAttribute('onclick')?.match(/toggleGather\(\d+,\s*(\d+)/)?.[1];
      const img = doc.querySelector('.data-img');
      const cover = image(img?.getAttribute('data-src') || img?.getAttribute('src'));
      const title = doc.querySelector('.anime_name h1')?.textContent.trim()
        .replace(/\s*\[[^\]]+\]\s*$/, '');
      if (!videoId(sn) || !cover || !title) fail('unavailable');
      return { ok: true, anime: {
        id: sn, title, cover, poster: cover, latestVideoId: args.videoId, sections: []
      } };
    }
    if (action === 'comments') {
      if (!videoId(args.videoId) || ![0, 1].includes(args.order) ||
          !Number.isInteger(args.page) || args.page < 0 || args.page > 100000000) fail('input');
      const url = new URL('https://wall.gamer.com.tw/app/v2/comment_detail.php');
      url.search = new URLSearchParams({
        service: '4', serviceId: args.videoId, order: String(args.order),
        ...(args.page ? { nextPage: String(args.page) } : {})
      });
      const result = await fetchOfficial(url);
      if (!id(result.messageId) || !Array.isArray(result.comments)) fail('unavailable');
      return { ok: true, messageId: String(result.messageId),
        total: Number(result.commentCount), nextPage: Number(result.nextPage || 0),
        comments: comments(result.comments).reverse() };
    }
    if (action === 'replies') {
      if (!id(args.commentId)) fail('input');
      const url = new URL('https://wall.gamer.com.tw/app/v1/reply_detail.php');
      url.searchParams.set('commentId', args.commentId);
      const result = await fetchOfficial(url);
      return { ok: true, comments: comments(result.comments) };
    }
    if (action === 'notifications') {
      login();
      const pages = await Promise.all(['light_0', 'light_1'].map(async type => {
        const url = new URL('https://api.gamer.com.tw/ajax/common/topBar.php');
        url.searchParams.set('type', type);
        return fetchOfficial(url, {}, true);
      }));
      const items = new Map();
      for (const html of pages) {
        const doc = new DOMParser().parseFromString(html, 'text/html');
        doc.querySelectorAll('a[href]').forEach(anchor => {
          let url;
          try { url = new URL(anchor.getAttribute('href'), origin); } catch (_) { return; }
          if (url.origin !== origin || url.pathname !== '/animeVideo.php' ||
              !videoId(url.searchParams.get('sn'))) return;
          const row = anchor.closest('li') || anchor.parentElement;
          const titleNode = anchor.cloneNode(true);
          titleNode.querySelectorAll('img,small,.time,.date').forEach(node => node.remove());
          const title = titleNode.textContent.replace(/\s+/g, ' ').trim() ||
            anchor.getAttribute('title') || '';
          if (!title || title.length > 500) return;
          const sn = url.searchParams.get('sn');
          const key = `episode:${sn}`;
          const time = row?.querySelector('.time,.date,small')?.textContent.trim() ||
            row?.textContent.match(/(?:\d+\s*(?:秒|分|分鐘|小時|天|日)前|昨天|今天)/)?.[0] || '';
          const img = row?.querySelector('img');
          items.set(key, { id: key, title, videoId: sn, time,
            cover: image(img?.getAttribute('data-src') || img?.getAttribute('src')) });
        });
      }
      return { ok: true, owner: initialOwner, items: [...items.values()].slice(0, 200) };
    }
    if (!['comment-send', 'comment-vote', 'danmaku-send'].includes(action)) fail('input');
    login();
    lock = action === 'danmaku-send' ? action : `comment:${args.messageId || args.commentId}`;
    if (locks.has(lock)) { lock = null; fail('busy'); }
    locks.add(lock);
    if (action === 'comment-send') {
      if (!id(args.messageId) || (args.commentId && !id(args.commentId)) ||
          typeof args.text !== 'string' || !args.text.trim() ||
          [...args.text].length > 2000) fail('input');
      // Recheck the episode -> message relationship before any write.
      if (!videoId(args.videoId)) fail('input');
      const boardURL = new URL('https://wall.gamer.com.tw/app/v2/comment_detail.php');
      boardURL.search = new URLSearchParams({ service: '4', serviceId: args.videoId, order: '1' });
      const board = await fetchOfficial(boardURL);
      if (String(board.messageId) !== args.messageId) fail('stale');
      const form = new FormData();
      form.set('messageId', args.messageId);
      if (args.commentId) form.set('commentId', args.commentId);
      form.set('message', args.text.trim());
      const result = await fetchOfficial('https://wall.gamer.com.tw/app/v1/comment_new.php',
        { method: 'POST', headers: csrf(), body: form });
      if (!id(result.commentId) || result.message || result.error) fail('rejected');
      return { ok: true, id: String(result.commentId) };
    }
    if (action === 'comment-vote') {
      if (!id(args.commentId) || ![1, 2].includes(args.type) ||
          typeof args.remove !== 'boolean') fail('input');
      const form = new URLSearchParams({ commentId: args.commentId, type: String(args.type) });
      const endpoint = args.remove ? 'comment_like_del.php' : 'comment_like.php';
      const result = await fetchOfficial(`https://wall.gamer.com.tw/app/v1/${endpoint}`,
        { method: 'POST', headers: csrf(), body: form });
      if (result.message || result.error) fail('rejected');
      return { ok: true };
    }
    function content() {
      live(); login();
      const root = document.querySelector('#video-container');
      const player = root?.querySelector('#ani_video,video-js,.video-js')?.player;
      const core = player?.usingPlugin?.('m3u8') ? player.m3u8() : null;
      const media = root?.querySelector('video');
      if (window.__bahaMediaSuspended || location.pathname !== '/animeVideo.php' ||
          new URL(location.href).searchParams.get('sn') !== args.videoId ||
          core?.state?.playingVideo !== true || core.state.playingAd === true ||
          String(core.state.videoSn) !== args.videoId ||
          !media || !(media.duration > 0)) fail('unavailable');
      const controls = player?.usingPlugin?.('animePlayer') ? player.animePlayer() : null;
      return { media, manager: controls?.danmuManager };
    }
    if (!videoId(args.videoId) || typeof args.text !== 'string' ||
        !args.text.trim() || new TextEncoder().encode(args.text.trim()).byteLength > 60 ||
        !/^#[0-9a-f]{6}$/i.test(args.color) ||
        ![0, 1, 2].includes(args.position) || ![0, 1, 2].includes(args.size)) fail('input');
    content();
    const token = await fetchOfficial(`${origin}/ajax/getCSRFToken.php`, {}, true);
    if (!token.trim() || token.length > 500 || /[<>\r\n]/.test(token)) fail('unavailable');
    const c = content(); // Age/ad/document state can change while retrieving CSRF.
    const time = Math.floor(c.media.currentTime * 10);
    const form = new URLSearchParams({ sn: args.videoId, content: args.text.trim(),
      color: args.color, position: String(args.position), size: String(args.size),
      time: String(time), token });
    const result = await fetchOfficial(`${origin}/ajax/danmuSet.php`,
      { method: 'POST', body: form });
    if (result.nologin) fail('login');
    if (result.error || !id(result.sn)) fail('rejected');
    const span = document.createElement('span');
    span.textContent = args.text.trim();
    const danmu = { sn: result.sn, text: span.outerHTML, color: args.color,
      position: args.position, size: args.size, time, userid: owner() };
    // A display refresh is best effort after the server has acknowledged.
    try {
      const current = content();
      const manager = current.manager;
      if (manager) manager.buildDanmu(manager.danmuPush(danmu));
    } catch (_) {}
    return { ok: true, id: String(result.sn) };
  } catch (error) {
    return { ok: false, code: ['login', 'stale', 'input', 'busy', 'rejected',
      'unavailable', 'format', 'endpoint'].includes(error.code) ? error.code : 'network' };
  } finally {
    if (lock) locks.delete(lock);
  }
})()
