/**
 * Picobus copy of the ZHC services menu, appearance control, and cookie tray.
 * Theme cookie is ZHCTHEME_{DEV|QA|PROD}, same as the rest of the site.
 * Icons come from <bucket>/dc/icons/. This file does not load /shared/zhc-prefs.js.
 */
(function () {
  'use strict';

  var THEME_MAX_AGE = 365 * 24 * 60 * 60;
  var THEME_VALUES = { light: 1, dark: 1, system: 1 };
  var ICON = bucketPrefix() + '/dc/icons/';
  var openId = null;

  function pathBucket() {
    var p = window.location.pathname || '/';
    if (p === '/dev' || p.indexOf('/dev/') === 0) return 'dev';
    if (p === '/qa' || p.indexOf('/qa/') === 0) return 'qa';
    return 'prod';
  }
  function bucketPrefix(bucket) {
    bucket = bucket || pathBucket();
    if (bucket === 'dev') return '/dev';
    if (bucket === 'qa') return '/qa';
    return '';
  }
  function cookiePath(bucket) {
    var pre = bucketPrefix(bucket);
    return pre === '' ? '/' : pre + '/';
  }
  function sessionCookieName(bucket) {
    return 'ZHCSESS_' + (bucket || pathBucket()).toUpperCase();
  }
  function themeCookieName(bucket) {
    return 'ZHCTHEME_' + (bucket || pathBucket()).toUpperCase();
  }
  function readCookie(name) {
    var parts = String(document.cookie || '').split(';');
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].replace(/^\s+/, '');
      if (p.indexOf(name + '=') === 0) return decodeURIComponent(p.slice(name.length + 1));
    }
    return null;
  }
  function writeCookie(name, value, maxAge, path) {
    var secure = location.protocol === 'https:' ? '; Secure' : '';
    var age = typeof maxAge === 'number' ? '; Max-Age=' + maxAge : '';
    document.cookie = name + '=' + encodeURIComponent(value) + age +
      '; Path=' + (path || '/') + '; SameSite=Lax' + secure;
  }
  function deleteCookie(name, path) {
    var secure = location.protocol === 'https:' ? '; Secure' : '';
    document.cookie = name + '=; Max-Age=0; Path=' + (path || '/') + '; SameSite=Lax' + secure;
  }
  function themePref() {
    var v = readCookie(themeCookieName());
    return v && THEME_VALUES[v] ? v : 'system';
  }
  function resolvedTheme(pref) {
    pref = pref || themePref();
    if (pref === 'light' || pref === 'dark') return pref;
    try {
      if (window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches) return 'dark';
    } catch (e) {}
    return 'light';
  }
  function applyTheme(pref) {
    pref = pref || themePref();
    var resolved = resolvedTheme(pref);
    document.documentElement.setAttribute('data-zhc-theme', resolved);
    document.documentElement.setAttribute('data-zhc-theme-pref', pref);
  }
  function setTheme(pref) {
    if (!THEME_VALUES[pref]) pref = 'system';
    var bucket = pathBucket();
    writeCookie(themeCookieName(bucket), pref, THEME_MAX_AGE, cookiePath(bucket));
    applyTheme(pref);
    return pref;
  }
  function clearTheme() {
    var bucket = pathBucket();
    deleteCookie(themeCookieName(bucket), cookiePath(bucket));
    applyTheme('system');
  }
  function themeIconName(pref) {
    pref = pref || themePref();
    if (pref === 'light') return 'theme-light.svg';
    if (pref === 'dark') return 'theme-dark.svg';
    return 'theme-system.svg';
  }
  function themeLabel(pref) {
    pref = pref || themePref();
    if (pref === 'light') return 'Light';
    if (pref === 'dark') return 'Dark';
    return 'System';
  }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'text') node.textContent = attrs[k];
        else if (k === 'className') node.className = attrs[k];
        else if (k.slice(0, 2) === 'on' && typeof attrs[k] === 'function') {
          node.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
        } else if (attrs[k] !== undefined && attrs[k] !== null) {
          node.setAttribute(k, attrs[k]);
        }
      });
    }
    (children || []).forEach(function (c) {
      if (c == null) return;
      node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
    });
    return node;
  }
  function ico(file) {
    return el('span', {
      className: 'zhc-ico',
      'aria-hidden': 'true',
      style: '--ico:url(' + ICON + file + ')'
    });
  }

  function catalog() {
    var bucket = pathBucket();
    var sessName = sessionCookieName(bucket);
    var themeName = themeCookieName(bucket);
    var themePresent = readCookie(themeName) !== null;
    return [
      {
        id: 'session',
        icon: 'cookie.svg',
        short: 'Session',
        name: sessName,
        purpose:
          'First-party only (this site). No ad trackers. Keeps you signed in across ZHC services in this environment. ' +
          'Stores only a random session id; account data lives on the server.',
        legalBasis: 'Strictly necessary for the service you request (login / security).',
        expires: 'Ends when the browser session ends, or immediately on Sign out / Delete.',
        renew: 'On each successful sign-in the session id is rotated. There is no multi-year tracking renewal.',
        httpOnly: true,
        necessary: true,
        readable: false,
        valueNote: 'HttpOnly — the browser does not expose the value to page scripts.',
        path: cookiePath(bucket),
        sameSite: 'Lax',
        secure: location.protocol === 'https:',
        deleteEffect: 'Signs you out of ZHC services in this environment until you sign in again.'
      },
      {
        id: 'theme',
        icon: 'cookie.svg',
        short: 'Theme',
        name: themeName,
        present: themePresent,
        purpose:
          'First-party only (this site). No ad trackers. Remembers light / dark / system appearance for this environment. ' +
          'Not tied to your account. Delete it to return to the system setting.',
        legalBasis: 'Preference you set (first-party, not advertising). Optional; default is system.',
        expires: '1 year from last change (Max-Age).',
        renew: 'Each theme change resets Max-Age to 1 year. Delete anytime.',
        httpOnly: false,
        necessary: false,
        readable: true,
        value: themePresent ? readCookie(themeName) : null,
        path: cookiePath(bucket),
        sameSite: 'Lax',
        secure: location.protocol === 'https:',
        deleteEffect: 'Appearance falls back to the system setting for this environment.'
      }
    ];
  }

  function servicesCatalog() {
    var bucket = pathBucket();
    var pre = bucketPrefix(bucket);
    var homeMatch = function (p) {
      return p === pre + '/' || p === pre || p === '/' || p === '';
    };
    var core = [
      { href: pre + '/', label: 'Home', match: homeMatch },
      { href: pre + '/whoami/', label: 'Whoami', match: function (p) { return p.indexOf('/whoami') >= 0; } },
      { href: pre + '/dns/', label: 'DNS Health', match: function (p) { return p.indexOf('/dns') >= 0; } },
      { href: pre + '/account/', label: 'Account', match: function (p) { return p.indexOf('/account') >= 0 || p.indexOf('/auth') >= 0; } }
    ];
    core.push({
      href: pre + '/dc/',
      label: pre + '/dc/',
      match: function (p) {
        var base = pre + '/dc';
        return p === base || p.indexOf(base + '/') === 0;
      }
    });
    core.push(
      { href: pre + '/support/', label: 'Support / APIs', match: function (p) { return p.indexOf('/support') >= 0; } },
      { href: pre + '/behaviorbucks/', label: 'Behavior Bucks', match: function (p) { return p.indexOf('/behaviorbucks') >= 0; } }
    );
    var experiments = [
      { href: pre + '/robots/', label: 'robots / llms', match: function (p) { return p.indexOf('/robots') >= 0; } },
      { href: pre + '/cron/', label: 'Cron', match: function (p) { return p.indexOf('/cron') >= 0; } },
      { href: pre + '/rate/', label: 'Rate limits', match: function (p) { return p.indexOf('/rate') >= 0; } },
      { href: pre + '/dkim/', label: 'DKIM archive', match: function (p) { return p.indexOf('/dkim') >= 0; } }
    ];
    var legal = [
      { href: pre + '/legal/terms.html', label: 'Terms', match: function (p) { return p.indexOf('/legal/terms') >= 0; } },
      { href: pre + '/legal/privacy.html', label: 'Privacy', match: function (p) { return p.indexOf('/legal/privacy') >= 0; } }
    ];
    if (bucket === 'prod') return core.concat(legal);
    return core.concat(experiments).concat(legal);
  }

  function signOutSession() {
    var url = bucketPrefix() + '/account/api.php?action=signout';
    return fetch(url, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action: 'signout' })
    }).then(function (r) {
      return r.json().catch(function () { return { ok: r.ok }; });
    }).catch(function () {
      return { ok: false };
    }).then(function (res) {
      deleteCookie(sessionCookieName(), cookiePath());
      return res;
    });
  }

  function closePanel() {
    openId = null;
    var panel = document.getElementById('zhc-cookie-panel');
    var bd = document.getElementById('zhc-cookie-panel-backdrop');
    if (panel) {
      panel.classList.remove('open');
      panel.classList.remove('zhc-legal-panel');
    }
    if (bd) bd.classList.remove('open');
  }
  function showMsg(panel, text, kind) {
    var m = panel.querySelector('.zhc-msg');
    if (!m) return;
    m.textContent = text || '';
    m.className = 'zhc-msg' + (kind ? ' ' + kind : '');
  }
  function openPanel(cookieId) {
    var item = catalog().filter(function (c) { return c.id === cookieId; })[0];
    if (!item) return;
    openId = cookieId;
    var panel = document.getElementById('zhc-cookie-panel');
    var bd = document.getElementById('zhc-cookie-panel-backdrop');
    if (!panel || !bd) return;
    panel.innerHTML = '';
    panel.appendChild(el('button', {
      type: 'button', className: 'zhc-close', 'aria-label': 'Close', text: '\u00d7', onClick: closePanel
    }));
    panel.appendChild(el('h2', { text: item.short + ' \u00b7 ' + item.name }));
    panel.appendChild(el('p', {
      className: 'zhc-why',
      text: 'Why: ' + item.purpose + ' Legal/practical basis: ' + item.legalBasis
    }));
    panel.appendChild(el('dl', null, [
      el('dt', { text: 'Name' }), el('dd', { text: item.name }),
      el('dt', { text: 'Path' }), el('dd', { text: item.path }),
      el('dt', { text: 'Expires' }), el('dd', { text: item.expires }),
      el('dt', { text: 'Renewal' }), el('dd', { text: item.renew }),
      el('dt', { text: 'HttpOnly' }), el('dd', { text: item.httpOnly ? 'yes (not readable by scripts)' : 'no (readable by this page)' }),
      el('dt', { text: 'Secure' }), el('dd', { text: item.secure ? 'yes (HTTPS only)' : 'no' }),
      el('dt', { text: 'SameSite' }), el('dd', { text: item.sameSite || 'Lax' }),
      el('dt', { text: 'Necessary' }), el('dd', { text: item.necessary ? 'yes' : 'no (optional preference)' }),
      el('dt', { text: 'Value' }), el('dd', {
        text: item.readable ? (item.value != null ? String(item.value) : '(not set - using default)') : item.valueNote
      }),
      el('dt', { text: 'If deleted' }), el('dd', { text: item.deleteEffect })
    ]));
    if (item.id === 'theme') {
      panel.appendChild(el('p', { text: 'Appearance for this environment:', style: 'margin:0 0 0.25rem;font-weight:600' }));
      var pref = themePref();
      var opts = el('div', { className: 'zhc-theme-opts' });
      ['light', 'dark', 'system'].forEach(function (v) {
        var label = v === 'system' ? 'System' : v.charAt(0).toUpperCase() + v.slice(1);
        opts.appendChild(el('button', {
          type: 'button',
          className: pref === v ? 'active' : '',
          text: label,
          onClick: function () {
            setTheme(v);
            refreshThemeBar();
            openPanel('theme');
            refreshTray();
          }
        }));
      });
      panel.appendChild(opts);
    }
    var actions = el('div', { className: 'zhc-panel-actions' });
    actions.appendChild(el('button', {
      type: 'button',
      className: 'danger',
      text: item.id === 'session' ? 'Delete cookie (sign out)' : 'Delete cookie',
      onClick: function () {
        showMsg(panel, 'Working...', '');
        if (item.id === 'theme') {
          clearTheme();
          refreshThemeBar();
          showMsg(panel, 'Theme cookie deleted. Using system default.', 'ok');
          refreshTray();
          setTimeout(function () { openPanel('theme'); }, 200);
          return;
        }
        if (item.id === 'session') {
          signOutSession().then(function (res) {
            if (res && res.ok === false) {
              showMsg(panel, 'Sign-out request failed; try Sign out on the account page.', 'err');
              return;
            }
            showMsg(panel, 'Session ended. Reload pages that showed you as signed in.', 'ok');
            refreshTray();
          });
        }
      }
    }));
    actions.appendChild(el('button', { type: 'button', text: 'Close', onClick: closePanel }));
    panel.appendChild(actions);
    panel.appendChild(el('p', { className: 'zhc-msg' }));
    panel.classList.add('open');
    bd.classList.add('open');
  }

  function openLegalDoc(kind) {
    var path = kind === 'privacy' ? '/privacy.html' : '/terms.html';
    var title = kind === 'privacy' ? 'Privacy Policy' : 'Terms of Service';
    var url = bucketPrefix() + '/legal' + path;
    var panel = document.getElementById('zhc-cookie-panel');
    var bd = document.getElementById('zhc-cookie-panel-backdrop');
    if (!panel || !bd) return;
    openId = 'legal-' + kind;
    panel.innerHTML = '';
    panel.classList.add('zhc-legal-panel');
    panel.appendChild(el('button', {
      type: 'button', className: 'zhc-close', 'aria-label': 'Close', text: '\u00d7', onClick: closePanel
    }));
    panel.appendChild(el('h2', { text: title }));
    panel.appendChild(el('p', {
      className: 'zhc-legal-split-hint',
      text: 'Left = official words. Right = super-simple translation. They scroll together; only the left side is binding.'
    }));
    var body = el('div', { className: 'zhc-legal-body', text: 'Loading\u2026', role: 'region', 'aria-label': title });
    panel.appendChild(body);
    panel.appendChild(el('div', { className: 'zhc-panel-actions' }, [
      el('a', { href: url, className: 'zhc-legal-open', target: '_blank', rel: 'noopener', text: 'Open full page' }),
      el('button', { type: 'button', text: 'Close', onClick: closePanel })
    ]));
    panel.classList.add('open');
    bd.classList.add('open');
    fetch(url, { credentials: 'same-origin' }).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.text();
    }).then(function (html) {
      var doc = new DOMParser().parseFromString(html, 'text/html');
      var art = doc.getElementById('legal-content');
      body.textContent = '';
      if (art) body.appendChild(art);
      else body.textContent = 'Could not find document body.';
    }).catch(function () {
      body.textContent = 'Could not load document. Try Open full page.';
    });
  }

  function refreshTray() {
    var icons = document.querySelector('#zhc-cookie-tray .zhc-tray-icons');
    if (!icons) return;
    while (icons.firstChild) icons.removeChild(icons.firstChild);
    catalog().forEach(function (c) {
      var absent = c.id === 'theme' && !c.present;
      icons.appendChild(el('button', {
        type: 'button',
        className: 'zhc-cookie-chip' + (absent ? ' absent' : ''),
        title: c.name + ' - details / delete',
        'aria-label': 'Cookie details: ' + c.short + ' (' + c.name + ')',
        onClick: function () { openPanel(c.id); }
      }, [ico(c.icon), el('span', { text: c.short })]));
    });
    icons.appendChild(el('button', {
      type: 'button',
      className: 'zhc-cookie-chip zhc-legal-chip',
      title: 'Terms of Service',
      'aria-label': 'Terms of Service',
      onClick: function () { openLegalDoc('terms'); }
    }, [ico('terms.svg'), el('span', { text: 'TOS' })]));
    icons.appendChild(el('button', {
      type: 'button',
      className: 'zhc-cookie-chip zhc-legal-chip',
      title: 'Privacy Policy',
      'aria-label': 'Privacy Policy',
      onClick: function () { openLegalDoc('privacy'); }
    }, [ico('privacy.svg'), el('span', { text: 'PP' })]));
  }

  function closeServicesMenu() {
    var wrap = document.getElementById('zhc-services-menu');
    if (!wrap) return;
    wrap.classList.remove('open');
    var btn = wrap.querySelector('.zhc-services-toggle');
    var panel = wrap.querySelector('.zhc-services-panel');
    if (btn) btn.setAttribute('aria-expanded', 'false');
    if (panel) panel.hidden = true;
  }
  function mountServicesMenu() {
    if (document.getElementById('zhc-services-menu')) return;
    var path = location.pathname || '/';
    var links = servicesCatalog().map(function (svc) {
      var active = false;
      try { active = !!svc.match(path); } catch (e) {}
      return el('a', {
        href: svc.href,
        className: 'zhc-services-link' + (active ? ' current' : ''),
        'aria-current': active ? 'page' : undefined,
        text: svc.label
      });
    });
    var panel = el('div', {
      className: 'zhc-services-panel',
      role: 'menu',
      'aria-label': 'ZHC services',
      hidden: 'hidden'
    }, links);
    var toggle = el('button', {
      type: 'button',
      className: 'zhc-services-toggle',
      'aria-haspopup': 'true',
      'aria-expanded': 'false',
      'aria-label': 'Services menu',
      title: 'All ZHC services',
      onClick: function (ev) {
        ev.stopPropagation();
        var wrap = document.getElementById('zhc-services-menu');
        if (!wrap) return;
        var open = !wrap.classList.contains('open');
        if (open) {
          wrap.classList.add('open');
          toggle.setAttribute('aria-expanded', 'true');
          panel.hidden = false;
        } else {
          closeServicesMenu();
        }
      }
    }, [ico('menu.svg'), el('span', { className: 'zhc-services-lab', text: 'Menu' })]);
    var wrap = el('div', { id: 'zhc-services-menu', className: 'zhc-services-menu' }, [toggle, panel]);
    var bar = document.getElementById('zhc-theme-bar');
    if (!bar) {
      bar = el('div', { id: 'zhc-theme-bar', 'aria-label': 'ZHC chrome' });
      document.body.insertBefore(bar, document.body.firstChild);
    }
    bar.insertBefore(wrap, bar.firstChild);
    document.addEventListener('click', function (ev) {
      var m = document.getElementById('zhc-services-menu');
      if (!m || !m.classList.contains('open')) return;
      if (m.contains(ev.target)) return;
      closeServicesMenu();
    });
    document.addEventListener('keydown', function (ev) {
      if (ev.key === 'Escape') closeServicesMenu();
    });
  }

  function refreshThemeBar() {
    var btn = document.getElementById('zhc-theme-toggle');
    if (!btn) return;
    var pref = themePref();
    var icoEl = btn.querySelector('.zhc-theme-ico');
    var lab = btn.querySelector('.zhc-theme-lab');
    if (icoEl) icoEl.setAttribute('style', '--ico:url(' + ICON + themeIconName(pref) + ')');
    if (lab) lab.textContent = themeLabel(pref);
    var msg = 'Appearance: ' + themeLabel(pref) + '. Click to change. Stored in ' + themeCookieName() + '.';
    btn.title = msg;
    btn.setAttribute('aria-label', msg);
  }
  function cycleTheme() {
    var order = ['system', 'light', 'dark'];
    var cur = themePref();
    var i = order.indexOf(cur);
    setTheme(order[(i + 1) % order.length]);
    refreshThemeBar();
    refreshTray();
  }
  function mountThemeControl() {
    if (document.getElementById('zhc-theme-toggle')) {
      refreshThemeBar();
      return;
    }
    var toggle = el('button', { type: 'button', id: 'zhc-theme-toggle', onClick: cycleTheme }, [
      el('span', { className: 'zhc-ico zhc-theme-ico', 'aria-hidden': 'true' }),
      el('span', { className: 'zhc-theme-lab', text: themeLabel() })
    ]);
    var slot = document.getElementById('zhc-theme-slot');
    if (!slot) {
      slot = el('div', { id: 'zhc-theme-slot' });
      var bar = document.getElementById('zhc-theme-bar');
      if (!bar) {
        bar = el('div', { id: 'zhc-theme-bar', 'aria-label': 'ZHC chrome' });
        document.body.insertBefore(bar, document.body.firstChild);
      }
      bar.appendChild(slot);
    }
    slot.appendChild(toggle);
    refreshThemeBar();
  }

  function fitChrome() {
    var app = document.querySelector('.app');
    if (!app) return;
    var bar = document.getElementById('zhc-theme-bar');
    var tray = document.getElementById('zhc-cookie-tray');
    var top = bar ? Math.ceil(bar.getBoundingClientRect().height) + 6 : 52;
    var bottom = tray ? Math.ceil(tray.getBoundingClientRect().height) + 8 : 56;
    app.style.paddingTop = top + 'px';
    app.style.paddingBottom = bottom + 'px';
  }

  function mount() {
    applyTheme();
    mountThemeControl();
    mountServicesMenu();
    if (!document.getElementById('zhc-cookie-tray')) {
      document.body.appendChild(el('div', {
        id: 'zhc-cookie-tray', role: 'contentinfo', 'aria-label': 'Cookies'
      }, [el('div', { className: 'zhc-tray-icons' })]));
      document.body.appendChild(el('div', { id: 'zhc-cookie-panel-backdrop', onClick: closePanel }));
      document.body.appendChild(el('div', {
        id: 'zhc-cookie-panel', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Cookie details'
      }));
    }
    refreshTray();
    fitChrome();
    window.addEventListener('resize', fitChrome);
    try {
      if (window.matchMedia) {
        matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
          if (themePref() === 'system') {
            applyTheme('system');
            refreshThemeBar();
          }
        });
      }
    } catch (e) {}
  }

  applyTheme();
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mount);
  else mount();
})();
