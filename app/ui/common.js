'use strict';
// Shared helpers for every window: backend calls, texts, digits, theme.

const TAURI = window.__TAURI__;
const backend = TAURI
  ? {
      invoke: (cmd, args) => TAURI.core.invoke(cmd, args),
      listen: (name, cb) => TAURI.event.listen(name, (e) => cb(e.payload)),
    }
  : window.MockBackend; // browser preview, see mock.js

const SY = { L: { order: [], strings: {} }, lang: 'en' };
const $ = (id) => document.getElementById(id);

function t(key) {
  const v = SY.L.strings[key];
  if (!v) return `[${key}]`;
  return v[Math.max(0, SY.L.order.indexOf(SY.lang))];
}

// Persian digits only in Persian.
function fa(s) {
  s = String(s);
  return SY.lang === 'fa' ? s.replace(/\d/g, (d) => '۰۱۲۳۴۵۶۷۸۹'[d]) : s;
}

function fmt(sec) {
  const n = Math.max(0, Math.ceil(sec));
  return fa(String(Math.floor(n / 60)).padStart(2, '0') + ':' + String(n % 60).padStart(2, '0'));
}

function fill(tpl, ...args) {
  return tpl.replace(/\{(\d)\}/g, (_, i) => args[i]);
}

function poolSize(prefix) {
  let n = 0;
  while (SY.L.strings[prefix + (n + 1)]) n++;
  return n;
}

function tipsText(kind, tips) {
  const a = tips.map((i) => t(`${kind}Tip${i}`));
  return a.length > 1 ? a.map((s) => '• ' + s).join('\n') : a[0] || '';
}

function signature() {
  return `${t('sigPrefix')} ${t('authorName')} — Telegram: ‎@ShrAlavifar`;
}

// Elements carry their text key in data-t (text) or data-tip (tooltip).
function setLang(code) {
  SY.lang = code;
  const h = document.documentElement;
  h.lang = code;
  h.dir = code === 'fa' || code === 'ar' ? 'rtl' : 'ltr';
  document.querySelectorAll('[data-t]').forEach((el) => (el.textContent = t(el.dataset.t)));
  document.querySelectorAll('[data-tip]').forEach((el) => (el.title = t(el.dataset.tip)));
}

function setTheme(theme) {
  document.documentElement.dataset.theme = theme;
}

function setRing(circle, frac) {
  const c = 2 * Math.PI * circle.r.baseVal.value;
  circle.style.strokeDasharray = c;
  circle.style.strokeDashoffset = c * (1 - Math.min(1, Math.max(0, frac)));
}

async function boot() {
  SY.L = await backend.invoke('get_lang');
  const s = await backend.invoke('get_state');
  setTheme(s.cfg.theme);
  setLang(s.cfg.lang);
  return s;
}

// Each window tells the backend when it is drawn, and reports script errors (used by --selfcheck).
function report(info) {
  backend.invoke('ui_report', { info: String(info) }).catch(() => {});
}
window.addEventListener('error', (e) => report('ERROR ' + e.message + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno));
window.addEventListener('unhandledrejection', (e) => report('ERROR ' + (e.reason && e.reason.message ? e.reason.message : e.reason)));

if (TAURI) window.addEventListener('contextmenu', (e) => e.preventDefault());
