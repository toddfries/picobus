/**
 * picobus chrome: theme cookie {prefix}_THEME_* + toggle in #zhc-theme-slot.
 * Prefix comes from <meta name="picobus-cookie">. Default PICOBUS.
 * Visual selectors stay ZHC-shaped (data-zhc-theme) so zhc-prefs.css applies.
 */
(function () {
  'use strict';
  var THEME_MAX_AGE = 365 * 24 * 60 * 60;
  var THEME_VALUES = { light: 1, dark: 1, system: 1 };

  function pathBucket() {
    var p = window.location.pathname || '/';
    if (p === '/dev' || p.indexOf('/dev/') === 0) return 'dev';
    if (p === '/qa' || p.indexOf('/qa/') === 0) return 'qa';
    return 'prod';
  }
  function cookiePath(bucket) {
    var b = bucket || pathBucket();
    if (b === 'dev') return '/dev/';
    if (b === 'qa') return '/qa/';
    return '/';
  }
  function cookiePrefix() {
    var m = document.querySelector('meta[name="picobus-cookie"]');
    var p = m && m.getAttribute('content');
    return (p && /^[A-Za-z0-9_]+$/.test(p)) ? p : 'PICOBUS';
  }
  function themeCookieName(bucket) {
    return cookiePrefix() + '_THEME_' + (bucket || pathBucket()).toUpperCase();
  }
  function readCookie(name) {
    var parts = String(document.cookie || '').split(';');
    for (var i = 0; i < parts.length; i++) {
      var p = parts[i].replace(/^\s+/, '');
      if (p.indexOf(name + '=') === 0) {
        return decodeURIComponent(p.slice(name.length + 1));
      }
    }
    return null;
  }
  function writeCookie(name, value, maxAge, path) {
    var secure = location.protocol === 'https:' ? '; Secure' : '';
    var age = typeof maxAge === 'number' ? '; Max-Age=' + maxAge : '';
    document.cookie =
      name + '=' + encodeURIComponent(value) + age +
      '; Path=' + (path || '/') + '; SameSite=Lax' + secure;
  }
  function themePref() {
    var v = readCookie(themeCookieName());
    return v && THEME_VALUES[v] ? v : 'system';
  }
  function resolvedTheme(pref) {
    pref = pref || themePref();
    if (pref === 'light' || pref === 'dark') return pref;
    try {
      return matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    } catch (e) {
      return 'light';
    }
  }
  function applyTheme(pref) {
    pref = pref && THEME_VALUES[pref] ? pref : themePref();
    var resolved = resolvedTheme(pref);
    document.documentElement.setAttribute('data-zhc-theme', resolved);
    document.documentElement.setAttribute('data-zhc-theme-pref', pref);
    writeCookie(themeCookieName(), pref, THEME_MAX_AGE, cookiePath());
  }
  function themeLabel(pref) {
    pref = pref || themePref();
    if (pref === 'light') return 'Light';
    if (pref === 'dark') return 'Dark';
    return 'System';
  }
  function cycleTheme() {
    var cur = themePref();
    var next = cur === 'system' ? 'light' : cur === 'light' ? 'dark' : 'system';
    applyTheme(next);
    var lab = document.querySelector('#zhc-theme-toggle .zhc-theme-lab');
    if (lab) lab.textContent = themeLabel(next);
  }
  function mountToggle() {
    if (document.getElementById('zhc-theme-toggle')) return;
    var slot = document.getElementById('zhc-theme-slot');
    if (!slot) {
      var chrome = document.querySelector('.zhc-app-chrome');
      if (chrome) {
        slot = document.createElement('div');
        slot.id = 'zhc-theme-slot';
        chrome.appendChild(slot);
      }
    }
    if (!slot) return;
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.id = 'zhc-theme-toggle';
    btn.setAttribute('aria-label', 'Appearance');
    btn.innerHTML =
      '<span class="zhc-theme-ico" aria-hidden="true">◐</span>' +
      '<span class="zhc-theme-lab"></span>';
    btn.querySelector('.zhc-theme-lab').textContent = themeLabel();
    btn.addEventListener('click', cycleTheme);
    slot.appendChild(btn);
  }
  applyTheme(themePref());
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', mountToggle);
  } else {
    mountToggle();
  }
})();
