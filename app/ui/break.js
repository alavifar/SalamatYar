'use strict';
// The break itself: either the whole screen ("full") or a small corner window ("window").

const FULL = `
  <div class="ov">
    <div class="kicker" id="kicker"></div>
    <h1 id="title"></h1>
    <p class="instr" id="instr"></p>
    <div class="ring">
      <svg viewBox="0 0 280 280"><circle class="tr" cx="140" cy="140" r="126"/><circle class="pr" id="arc" cx="140" cy="140" r="126"/></svg>
      <div class="mid"><div class="time ltr" id="time"></div><div class="sub" data-t="remaining"></div></div>
    </div>
    <div class="tips" id="tips"></div>
    <div class="acts">
      <button class="btn" data-how="done" data-t="btnDone"></button>
      <button class="ghost" data-how="later" data-t="btnLater"></button>
      <button class="ghost" data-how="skip" data-t="btnSkip"></button>
    </div>
  </div>
  <div class="ov-sig" id="sig"></div>`;

const MINI = `
  <div class="mn" id="box">
    <div class="top">
      <div><div class="kicker" id="kicker"></div><h2 id="title"></h2></div>
      <div class="time ltr" id="time"></div>
    </div>
    <div class="prog"><i id="bar"></i></div>
    <p class="instr" id="instr"></p>
    <p class="tips" id="tips"></p>
    <div class="acts">
      <button class="btn small" data-how="done" data-t="btnDone"></button>
      <button class="ghost small" data-how="later" data-t="btnLater"></button>
      <button class="ghost small" data-how="skip" data-t="btnSkip"></button>
    </div>
  </div>`;

let built = '';
let lastHeight = 0;

function render(s) {
  const b = s.brk;
  if (!b) return; // the backend closes this window
  if (s.cfg.theme !== document.documentElement.dataset.theme) setTheme(s.cfg.theme);
  const key = b.mode + s.cfg.lang;
  if (built !== key) {
    built = key;
    document.body.className = b.mode === 'full' ? 'full' : 'mini';
    $('root').innerHTML = b.mode === 'full' ? FULL : MINI;
    setLang(s.cfg.lang);
    document.querySelectorAll('[data-how]').forEach((el) =>
      el.addEventListener('click', () => backend.invoke('end_break', { how: el.dataset.how })));
    if ($('sig')) $('sig').textContent = signature();
  }
  const eye = b.kind === 'eye';
  document.body.style.setProperty('--c', `var(--${eye ? 'eye' : 'move'})`);
  const kicker = t(eye ? 'ovEyeKicker' : 'ovMoveKicker');
  $('kicker').textContent = b.preview ? `${t('previewTag')} · ${kicker}` : kicker;
  $('title').textContent = t(eye ? 'ovEyeTitle' : 'ovMoveTitle');
  $('instr').textContent = t(eye ? 'ovEyeInstr' : 'ovMoveInstr');
  $('tips').textContent = tipsText(b.kind, b.tips);
  $('time').textContent = fmt(b.left);
  // "Done" makes sense only for the longer movement break.
  document.querySelector('[data-how="done"]').hidden = eye;
  const frac = Math.max(0, Math.min(1, b.left / b.total));
  if (b.mode === 'full') {
    setRing($('arc'), frac);
  } else {
    $('bar').style.width = frac * 100 + '%';
    const h = Math.ceil($('box').getBoundingClientRect().height);
    if (Math.abs(h - lastHeight) > 1) {
      lastHeight = h;
      backend.invoke('fit_window', { height: h });
    }
  }
}

(async () => {
  render(await boot());
  backend.listen('state', render);
  report('break ready ' + document.body.className + ' title=' + ($('title') ? $('title').textContent.length : 0));
})();
