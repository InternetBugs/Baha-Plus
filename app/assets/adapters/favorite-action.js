
  (function() {
    if (location.origin !== 'https://ani.gamer.com.tw') return;
    var login = window.User?.Login;
    var owner = typeof login?.getUserid === 'function' ? login.getUserid() : null;
    var loggedIn = typeof login?.getUserid === 'function'
      ? typeof owner === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(owner) && owner.toLowerCase() !== 'guest'
      : !!document.querySelector('.btn-logout');
    if (!loggedIn) {
      bahaPostJSON(JSON.stringify({type:'account-guest'})); return;
    }
    var pattern = new RegExp('toggleGather\\(\\d+,\\s*%ANIME_ID%\\s*,');
    var button = Array.from(document.querySelectorAll('[onclick*="toggleGather"]')).find(function(control) {
      return pattern.test(control.getAttribute('onclick') || '');
    });
    if (!button) {
      bahaPostJSON(JSON.stringify({type:'favorite-error',id:'%ANIME_ID%'})); return;
    }
    var action = button.getAttribute('onclick') || '';
    var selectedClass = action.includes('btn-is-active') ? 'btn-is-active' : 'ordered';
    var desired = __BAHA_DESIRED__;
    function check() {
      if (button.classList.contains(selectedClass) === desired && !button.classList.contains('actionLock')) {
        bahaPostJSON(JSON.stringify({type:'favorite-complete',id:'%ANIME_ID%',saved:desired}));
        return true;
      }
      return false;
    }
    if (check()) return;
    var observer = new MutationObserver(function() { if (check()) observer.disconnect(); });
    observer.observe(button,{attributes:true,attributeFilter:['class']});
    setTimeout(function(){observer.disconnect();},30000);
    button.click();
  })(); true;
