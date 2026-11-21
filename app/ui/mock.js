'use strict';
// Browser preview only: when the pages are opened outside the app (npm run preview),
// this stands in for the Rust backend so the interface can be designed and checked.
// URL parameters: lang, theme, kind (eye|move), mode (full|window), page.
if (!window.__TAURI__) {
  const q = new URLSearchParams(location.search);
  const listeners = [];
  const state = {
    version: '2.0.0',
    cfg: {
      eyeInterval: 20, eyeDuration: 20, moveInterval: 30, moveDuration: 120, waterInterval: 60,
      idleReset: 5, idleDetect: true, sound: true, music: true, volume: 60,
      musicEye: '', musicMove: '', theme: q.get('theme') || 'dark', breakMode: q.get('mode') || 'full',
      lang: q.get('lang') || 'en',
    },
    stats: { date: '', work: 8100, eye: 5, move: 3, water: 2, skipped: 1 },
    eye: 700, move: 1500, water: 900, paused: false, away: false, musicOn: false,
    brk: null, toast: { tip: 3 },
  };
  if (/break\.html/.test(location.pathname)) {
    const kind = q.get('kind') || 'eye';
    const total = kind === 'eye' ? 20 : 120;
    state.brk = { kind, total, left: kind === 'eye' ? 14 : 75, mode: state.cfg.breakMode, preview: q.has('preview'), tips: kind === 'eye' ? [4] : [6, 13] };
  }
  const emit = () => listeners.forEach((cb) => cb(JSON.parse(JSON.stringify(state))));
  const defaults = { eyeInterval: 20, eyeDuration: 20, moveInterval: 30, moveDuration: 120, waterInterval: 60, idleReset: 5 };
  window.MockBackend = {
    listen: async (name, cb) => { if (name === 'state') listeners.push(cb); },
    invoke: async (cmd, args) => {
      switch (cmd) {
        case 'get_lang': {
          const base = await (await fetch('../../lang.json')).json();
          const extra = await (await fetch('../lang-extra.json')).json();
          return { order: base._order, strings: Object.assign(base.strings, extra.strings) };
        }
        case 'get_state': return JSON.parse(JSON.stringify(state));
        case 'set_cfg': state.cfg = args.cfg; break;
        case 'restore_defaults': Object.assign(state.cfg, defaults); break;
        case 'toggle_pause': state.paused = !state.paused; break;
        case 'reset_timers': state.eye = state.move = state.water = 0; break;
        case 'drink': state.stats.water++; state.water = 0; break;
        case 'get_autostart': return false;
        case 'ui_report': return;
        case 'set_autostart': return args.on;
        default: console.log('mock:', cmd, args || '');
      }
      emit();
    },
  };
  if (!q.has('still')) {
    setInterval(() => {
      if (!state.paused && !state.brk) { state.eye += 0.5; state.move += 0.5; state.water += 0.5; state.stats.work += 0.5; }
      if (state.brk && state.brk.left > 1) state.brk.left -= 0.5;
      emit();
    }, 500);
  }
}
