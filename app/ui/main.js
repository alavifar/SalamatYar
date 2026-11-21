'use strict';
// Main window: dashboard, settings, health guide, about.

const LANG_NAMES = { fa: 'فارسی', en: 'English', ar: 'العربية', ru: 'Русский', zh: '中文' };
const CARDS = [
  { id: 'eye', title: 'cardEye', btn: 'btnEyeNow', c: 'eye' },
  { id: 'move', title: 'cardMove', btn: 'btnMoveNow', c: 'move' },
  { id: 'water', title: 'cardWater', btn: 'btnDrank', c: 'water' },
];
const TILES = [
  ['stWork', 'tileWork', 'text'], ['stEye', 'cardEye', 'eye'], ['stMove', 'tileMove', 'move'],
  ['stWater', 'tileWater', 'water'], ['stSkip', 'tileSkipped', 'red'],
];
const SLIDERS = [
  { k: 'eyeInterval', l: 'slEyeInt', min: 10, max: 40, step: 5, u: 'unitMin', c: 'eye', box: 'slTime' },
  { k: 'eyeDuration', l: 'slEyeDur', min: 20, max: 60, step: 5, u: 'unitSec', c: 'eye', box: 'slTime' },
  { k: 'moveInterval', l: 'slMoveInt', min: 20, max: 90, step: 5, u: 'unitMin', c: 'move', box: 'slTime' },
  { k: 'moveDuration', l: 'slMoveDur', min: 60, max: 600, step: 30, u: 'unitSec', c: 'move', box: 'slTime' },
  { k: 'waterInterval', l: 'slWaterInt', min: 30, max: 120, step: 10, u: 'unitMin', c: 'water', box: 'slTime' },
  { k: 'idleReset', l: 'slIdle', min: 3, max: 15, step: 1, u: 'unitMin', c: 'violet', box: 'slIdle' },
  { k: 'volume', l: 'slVolume', min: 0, max: 100, step: 5, u: '%', c: 'violet', box: 'slSound' },
];
const GUIDE = [
  ['g1t', 'g1b', 'g1s', 'eye'], ['g2t', 'g2b', 'g2s', 'move'], ['g3t', 'g3b', 'g3s', 'violet'],
  ['g4t', 'g4b', 'g3s', 'violet'], ['g5t', 'g5b', 'g3s', 'pink'], ['g6t', 'g6b', 'g6s', 'water'],
];
const CHECKS = ['idleDetect', 'sound', 'music'];

let S = null;      // last state from the backend
let cfg = null;    // settings as shown in the controls
let lastEdit = 0;  // while the user is changing a control, the backend does not overwrite it
let tipIdx = 0, tipAt = 0, volTimer = 0;

function buildStatic() {
  $('cards').innerHTML = CARDS.map((c) => `
    <div class="card" style="--c:var(--${c.c})">
      <h3><span class="dot"></span><span data-t="${c.title}"></span></h3>
      <p class="desc" id="${c.id}Desc"></p>
      <div class="ring">
        <svg viewBox="0 0 170 170"><circle class="tr" cx="85" cy="85" r="75"/><circle class="pr" id="${c.id}Arc" cx="85" cy="85" r="75"/></svg>
        <div class="mid"><div class="time ltr" id="${c.id}Time"></div><div class="sub" data-t="untilNext"></div></div>
      </div>
      <button class="ghost block" id="${c.id}Now" data-t="${c.btn}"></button>
    </div>`).join('');
  $('tiles').innerHTML = TILES.map(([id, title, c]) => `
    <div class="tile" style="--c:var(--${c})"><b class="ltr" id="${id}">0</b><span data-t="${title}"></span></div>`).join('');
  for (const s of SLIDERS) {
    $(s.box).insertAdjacentHTML('beforeend', `
      <div class="row" style="--c:var(--${s.c})">
        <div class="top"><span data-t="${s.l}"></span><span class="val" id="v-${s.k}"></span></div>
        <input type="range" id="s-${s.k}" min="${s.min}" max="${s.max}" step="${s.step}">
      </div>`);
  }
  $('guide').innerHTML = GUIDE.map(([title, body, src, c]) => `
    <div class="card" style="--c:var(--${c})">
      <h3><span class="dot"></span><span data-t="${title}"></span></h3>
      <p data-t="${body}"></p><small data-t="${src}"></small>
    </div>`).join('');
  $('langMenu').innerHTML = Object.entries(LANG_NAMES)
    .map(([code, name]) => `<button class="ghost small" data-lang="${code}">${name}</button>`).join('');
}

function valText(s, v) {
  if (s.k === 'volume') return SY.lang === 'fa' ? fa(v) + '٪' : v + '%';
  return fa(`${v} ${t(s.u)}`);
}

function baseName(p) {
  return p.split(/[\\/]/).pop();
}

// Texts that are built from several pieces or from numbers.
function renderTexts() {
  $('btnLang').textContent = LANG_NAMES[SY.lang] + '  ▾';
  document.querySelectorAll('[data-lang]').forEach((b) => b.classList.toggle('on', b.dataset.lang === SY.lang));
  $('sig').textContent = signature();
  $('btnTelegram').textContent = `${t('aboutTelegram')} ‎@ShrAlavifar`;
  const ver = SY.lang === 'fa' ? S.version.replace(/\./g, '٫') : S.version;
  $('aboutVer').textContent = fa(fill(t('verFmt'), ver));
  $('chips').innerHTML = ['Python', 'JavaScript', 'MQL5', t('chipBot'), t('chipData'), t('chipPdf'), t('chipRtl')]
    .map((x) => `<span>${x}</span>`).join('');
  $('tipText').textContent = t('dashTip' + (tipIdx + 1));
  $('eyeDesc').textContent = fa(fill(t('descEye'), cfg.eyeInterval, cfg.eyeDuration));
  $('moveDesc').textContent = fa(fill(t('descMove'), cfg.moveInterval, cfg.moveDuration));
  $('waterDesc').textContent = fa(fill(t('descWater'), cfg.waterInterval));
  for (const s of SLIDERS) $('v-' + s.k).textContent = valText(s, cfg[s.k]);
  $('muEyeName').textContent = cfg.musicEye ? baseName(cfg.musicEye) : t('muDefCalm');
  $('muEyeName').title = cfg.musicEye;
  $('muMoveName').textContent = cfg.musicMove ? baseName(cfg.musicMove) : t('muDefActive');
  $('muMoveName').title = cfg.musicMove;
}

function loadControls() {
  for (const s of SLIDERS) $('s-' + s.k).value = cfg[s.k];
  for (const k of CHECKS) $('ck-' + k).checked = cfg[k];
  document.querySelectorAll('#segTheme .tab').forEach((b) => b.classList.toggle('on', b.dataset.v === cfg.theme));
  document.querySelectorAll('#segDisp .tab').forEach((b) => b.classList.toggle('on', b.dataset.v === cfg.breakMode));
  setTheme(cfg.theme);
  if (SY.lang !== cfg.lang) setLang(cfg.lang);
  renderTexts();
}

// Timers, statistics and status: twice a second.
function render() {
  const parts = [['eye', cfg.eyeInterval, S.eye], ['move', cfg.moveInterval, S.move], ['water', cfg.waterInterval, S.water]];
  for (const [id, mins, used] of parts) {
    setRing($(id + 'Arc'), used / (mins * 60));
    $(id + 'Time').textContent = fmt(mins * 60 - used);
  }
  const wm = Math.floor(S.stats.work / 60);
  $('stWork').textContent = fa(Math.floor(wm / 60) + ':' + String(wm % 60).padStart(2, '0'));
  $('stEye').textContent = fa(S.stats.eye);
  $('stMove').textContent = fa(S.stats.move);
  $('stWater').textContent = fa(S.stats.water);
  $('stSkip').textContent = fa(S.stats.skipped);
  const [txt, dot] = S.brk ? ['stBreak', 'water'] : S.paused ? ['stPaused', 'red'] : S.away ? ['stAway', 'move'] : ['stWorking', 'green'];
  $('statusText').textContent = t(txt);
  $('statusDot').style.setProperty('--c', `var(--${dot})`);
  $('btnPause').textContent = t(S.paused ? 'btnResume' : 'btnPause');
  if (Date.now() - tipAt > 45000) {
    tipAt = Date.now();
    tipIdx = (tipIdx + 1) % poolSize('dashTip');
    $('tipText').textContent = t('dashTip' + (tipIdx + 1));
  }
}

function onState(s) {
  S = s;
  if (Date.now() - lastEdit > 800 && JSON.stringify(s.cfg) !== JSON.stringify(cfg)) {
    cfg = s.cfg;
    loadControls();
  }
  render();
}

function pushCfg() {
  lastEdit = Date.now();
  renderTexts();
  return backend.invoke('set_cfg', { cfg });
}

function showPage(name) {
  document.querySelectorAll('#nav .tab').forEach((b) => b.classList.toggle('on', b.dataset.page === name));
  document.querySelectorAll('.page').forEach((p) => p.classList.toggle('on', p.id === 'page-' + name));
}

function wire() {
  $('nav').addEventListener('click', (e) => e.target.dataset.page && showPage(e.target.dataset.page));
  $('btnLang').addEventListener('click', (e) => { e.stopPropagation(); $('langMenu').hidden = !$('langMenu').hidden; });
  document.addEventListener('click', () => ($('langMenu').hidden = true));
  $('langMenu').addEventListener('click', (e) => {
    const code = e.target.dataset.lang;
    if (!code || code === SY.lang) return;
    cfg.lang = code;
    setLang(code);
    pushCfg();
    render();
  });

  $('eyeNow').addEventListener('click', () => backend.invoke('start_break', { kind: 'eye' }));
  $('moveNow').addEventListener('click', () => backend.invoke('start_break', { kind: 'move' }));
  $('waterNow').addEventListener('click', () => backend.invoke('drink'));
  $('btnPause').addEventListener('click', () => backend.invoke('toggle_pause'));
  // Restarting the timers asks first, because the button is easy to hit by mistake.
  $('btnReset').addEventListener('click', () => { $('confirm').hidden = false; $('cfNo').focus(); });
  $('cfNo').addEventListener('click', () => ($('confirm').hidden = true));
  $('cfYes').addEventListener('click', () => { $('confirm').hidden = true; backend.invoke('reset_timers'); });
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { $('confirm').hidden = true; $('langMenu').hidden = true; } });

  for (const s of SLIDERS) {
    $('s-' + s.k).addEventListener('input', (e) => {
      cfg[s.k] = Number(e.target.value);
      pushCfg();
      // Preview: shortly after the volume slider settles, the chime plays at that volume.
      if (s.k === 'volume' && !S.musicOn) {
        clearTimeout(volTimer);
        volTimer = setTimeout(() => backend.invoke('play_fx', { kind: 'notify' }), 350);
      }
    });
  }
  for (const k of CHECKS) {
    $('ck-' + k).addEventListener('change', async (e) => {
      cfg[k] = e.target.checked;
      await pushCfg();
      // Preview: switching a sound option on plays a sample of that sound.
      if (k === 'sound' && cfg.sound) backend.invoke('play_fx', { kind: 'notify' });
      if (k === 'music' && cfg.music) backend.invoke('play_sample', { slot: 'calm', seconds: 6 });
    });
  }
  $('segTheme').addEventListener('click', (e) => {
    if (!e.target.dataset.v) return;
    cfg.theme = e.target.dataset.v;
    loadControls();
    pushCfg();
  });
  $('segDisp').addEventListener('click', async (e) => {
    if (!e.target.dataset.v) return;
    cfg.breakMode = e.target.dataset.v;
    loadControls();
    await pushCfg();
    // Preview: a short sample break in the chosen style.
    backend.invoke('preview_break');
  });
  $('btnDefaults').addEventListener('click', () => { lastEdit = 0; backend.invoke('restore_defaults'); });
  $('btnTestChime').addEventListener('click', () => backend.invoke('play_fx', { kind: 'start' }));
  document.querySelectorAll('[data-play]').forEach((b) => b.addEventListener('click', () => backend.invoke('toggle_sample', { slot: b.dataset.play })));
  document.querySelectorAll('[data-pick]').forEach((b) => b.addEventListener('click', () => { lastEdit = 0; backend.invoke('pick_music', { key: b.dataset.pick }); }));
  document.querySelectorAll('[data-clear]').forEach((b) => b.addEventListener('click', () => { lastEdit = 0; backend.invoke('clear_music', { key: b.dataset.clear }); }));
  $('ckAuto').addEventListener('change', async (e) => {
    e.target.checked = await backend.invoke('set_autostart', { on: e.target.checked });
  });
  $('btnTelegram').addEventListener('click', () => backend.invoke('open_author'));
  $('sig').addEventListener('click', () => backend.invoke('open_author'));
}

(async () => {
  buildStatic();
  S = await boot();
  cfg = S.cfg;
  tipIdx = Math.floor(Math.random() * poolSize('dashTip'));
  tipAt = Date.now();
  setLang(cfg.lang); // again, for the parts that buildStatic added
  loadControls();
  wire();
  render();
  $('ckAuto').checked = await backend.invoke('get_autostart');
  const page = new URLSearchParams(location.search).get('page');
  if (page) showPage(page);
  backend.listen('state', onState);
  report('main ready ' + SY.lang + ' cards=' + document.querySelectorAll('#cards .card').length);
})();
