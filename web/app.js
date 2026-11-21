const bridge = window.chrome && window.chrome.webview;
const send = (o) => { try { bridge && bridge.postMessage(o); } catch (e) { } };
const el = (id) => document.getElementById(id);

const BAR = { w: 320, h: 72 };
const PANEL_H = 210;
const SET = { w: 440, h: 470 };

const I18N = {
  ru: {
    ready: 'Готов', listening: 'Слушаю', recognizing: 'Распознаю', done: 'Готово', noTarget: 'Нет окна',
    insert: 'Вставить', start: 'Записать', stop: 'Стоп', cont: 'Продолжить', copy: 'Копировать',
    mic: 'Микрофон', level: 'Уровень входа', model: 'Модель распознавания',
    fast: 'Быстро (small)', exact: 'Точно (medium)',
    autoReplace: 'Заменять выделенное автоматически', lang: 'Язык интерфейса',
    recLang: 'Язык распознавания', autoLang: 'Определять сам', apply: 'Готово',
    openFolder: 'Открыть папку программы', placeholder: 'Распознанный текст…', settings: 'Настройки',
    noMed: 'Файл модели medium не найден — доступна только быстрая модель',
    noModels: 'Не найдены модели распознавания. Положите ggml-*.bin в папку models\\',
    noEngine: 'Не найден движок распознавания (bin\\whisper\\whisper-cli.exe)',
    noFfmpeg: 'Не найден ffmpeg (bin\\ffmpeg.exe) — запись недоступна',
    copied: 'Текст скопирован'
  },
  en: {
    ready: 'Ready', listening: 'Listening', recognizing: 'Recognizing', done: 'Done', noTarget: 'No target',
    insert: 'Insert', start: 'Record', stop: 'Stop', cont: 'Continue', copy: 'Copy',
    mic: 'Microphone', level: 'Input level', model: 'Recognition model',
    fast: 'Fast (small)', exact: 'Accurate (medium)',
    autoReplace: 'Replace selection automatically', lang: 'Interface language',
    recLang: 'Recognition language', autoLang: 'Detect automatically', apply: 'Done',
    openFolder: 'Open program folder', placeholder: 'Recognized text…', settings: 'Settings',
    noMed: 'medium model file not found — only the fast model is available',
    noModels: 'No recognition models found. Put ggml-*.bin into the models\\ folder',
    noEngine: 'Recognition engine not found (bin\\whisper\\whisper-cli.exe)',
    noFfmpeg: 'ffmpeg not found (bin\\ffmpeg.exe) — recording is unavailable',
    copied: 'Text copied'
  },
  uk: {
    ready: 'Готово', listening: 'Слухаю', recognizing: 'Розпізнаю', done: 'Готово', noTarget: 'Нема вікна',
    insert: 'Вставити', start: 'Записати', stop: 'Стоп', cont: 'Продовжити', copy: 'Копіювати',
    mic: 'Мікрофон', level: 'Рівень входу', model: 'Модель розпізнавання',
    fast: 'Швидко (small)', exact: 'Точно (medium)',
    autoReplace: 'Замінювати виділене автоматично', lang: 'Мова інтерфейсу',
    recLang: 'Мова розпізнавання', autoLang: 'Визначати сам', apply: 'Готово',
    openFolder: 'Відкрити папку програми', placeholder: 'Розпізнаний текст…', settings: 'Налаштування',
    noMed: 'Файл моделі medium не знайдено — доступна лише швидка модель',
    noModels: 'Не знайдено моделей розпізнавання. Покладіть ggml-*.bin у папку models\\',
    noEngine: 'Не знайдено двигун розпізнавання (bin\\whisper\\whisper-cli.exe)',
    noFfmpeg: 'Не знайдено ffmpeg (bin\\ffmpeg.exe) — запис недоступний',
    copied: 'Текст скопійовано'
  }
};

let lang = 'ru';
const t = (k) => (I18N[lang] && I18N[lang][k]) || I18N.ru[k] || k;

const st = { state: 'idle', text: '', level: -90, panel: false, view: 'bar' };

const bar = el('bar'), mic = el('mic'), gear = el('gear'), info = el('info');
const stateEl = el('state'), fill = el('meterFill');
const panel = el('panel'), ta = el('ta');
const bMain = el('bMain'), bCont = el('bCont'), bCopy = el('bCopy');
const settings = el('settings');

/* ---------------- layout ---------------- */

function layout() {
  let h;
  if (st.view === 'settings') {
    send({ cmd: 'resize', w: SET.w, h: SET.h });
    return;
  }
  h = BAR.h + (st.panel ? PANEL_H : 0);
  send({ cmd: 'resize', w: BAR.w, h: h });
}

function setPanel(on) {
  st.panel = !!on;
  panel.classList.toggle('open', st.panel);
  document.body.classList.toggle('panel-open', st.panel);
  layout();
  if (st.panel) setTimeout(() => { try { ta.focus(); } catch (e) { } }, 30);
}

/* ---------------- render ---------------- */

function applyLang() {
  document.documentElement.lang = lang;
  document.querySelectorAll('[data-i18n]').forEach((n) => {
    const k = n.getAttribute('data-i18n');
    if (I18N[lang] && I18N[lang][k]) n.textContent = I18N[lang][k];
  });
  mic.title = t('start') + ' (Win+Ё)';
  gear.title = t('settings');
  ta.placeholder = t('placeholder');
  render();
}

function render() {
  const s = st.state;
  const has = st.text.trim().length > 0;

  mic.classList.toggle('on', s === 'recording');
  mic.classList.toggle('busy', s === 'recognizing');
  stateEl.classList.toggle('rec', s === 'recording');
  stateEl.classList.toggle('busy', s === 'recognizing');

  if (s === 'recording') stateEl.textContent = t('listening');
  else if (s === 'recognizing') stateEl.textContent = t('recognizing');
  else if (st.status) stateEl.textContent = st.status;
  else stateEl.textContent = has ? t('done') : t('ready');

  if (s === 'recording') {
    const pct = Math.max(0, Math.min(100, ((st.level + 60) / 55) * 100));
    fill.style.width = pct.toFixed(1) + '%';
  } else {
    fill.style.width = '0%';
  }

  if (s === 'recording') {
    bMain.textContent = t('stop');
    bMain.classList.add('danger');
    bMain.disabled = false;
    bCont.disabled = true;
  } else if (s === 'recognizing') {
    bMain.textContent = '…';
    bMain.classList.remove('danger');
    bMain.disabled = true;
    bCont.disabled = true;
  } else {
    bMain.textContent = has ? t('insert') : t('start');
    bMain.classList.remove('danger');
    bMain.disabled = false;
    bCont.disabled = !has;
  }
}

function setText(v) {
  if (typeof v !== 'string') return;
  st.text = v;
  if (document.activeElement !== ta && ta.value !== v) ta.value = v;
  render();
}

/* ---------------- settings ---------------- */

let cfg = { devices: [], micIndex: 0, volume: 60, model: 'small', autoPaste: true, recLang: 'ru', models: {}, paths: {} };

function fillSettings(init) {
  if (init && init.devices) {
    const sel = el('selMic');
    sel.innerHTML = '';
    init.devices.forEach((name, i) => {
      const o = document.createElement('option');
      o.value = String(i);
      o.textContent = name;
      sel.appendChild(o);
    });
    cfg.devices = init.devices;
  }
  if (init) cfg = Object.assign({}, cfg, init);
  el('selMic').selectedIndex = Math.max(0, Math.min(cfg.devices.length - 1, cfg.micIndex | 0));
  el('rngVol').value = String(cfg.volume | 0);
  el('lblVol').textContent = (cfg.volume | 0) + '%';
  el('chkAuto').checked = !!cfg.autoPaste;
  el('selLang').value = lang;
  el('selRec').value = cfg.recLang || 'ru';

  document.querySelectorAll('#segModel button').forEach((b) => {
    const m = b.dataset.model;
    const ok = m === 'small' ? cfg.models.small !== false : !!cfg.models.medium;
    b.disabled = !ok;
    b.classList.toggle('sel', cfg.model === m);
  });

  const hint = el('hintModel');
  const missing = [];
  if (!cfg.models.small && !cfg.models.medium) missing.push(t('noModels'));
  else if (!cfg.models.medium) missing.push(t('noMed'));
  hint.textContent = missing.join(' ');
  hint.classList.toggle('err', !cfg.models.small);

  const p = cfg.paths || {};
  el('paths').textContent = [p.engines, p.app].filter(Boolean).join('  ·  ');
}

function openSettings() {
  st.view = 'settings';
  document.body.classList.add('settings-view');
  settings.hidden = false;
  fillSettings(null);
  layout();
  send({ cmd: 'settingsOpen' });
}

function closeSettings() {
  st.view = 'bar';
  document.body.classList.remove('settings-view');
  settings.hidden = true;
  layout();
  send({ cmd: 'settingsClose' });
}

function saveSettings() {
  const sel = el('selMic');
  const modelBtn = document.querySelector('#segModel button.sel');
  send({
    cmd: 'save',
    micIndex: sel.selectedIndex,
    volume: parseInt(el('rngVol').value, 10) || 0,
    model: modelBtn ? modelBtn.dataset.model : 'small',
    autoPaste: el('chkAuto').checked,
    lang: el('selLang').value,
    recLang: el('selRec').value
  });
  closeSettings();
}

/* ---------------- events ---------------- */

mic.addEventListener('click', () => send({ cmd: 'toggle' }));
gear.addEventListener('click', () => (st.view === 'settings' ? closeSettings() : openSettings()));
stateEl.addEventListener('click', () => {
  if (st.view === 'settings') return;
  setPanel(!st.panel);
});

bMain.addEventListener('click', () => {
  if (st.state === 'recording') { send({ cmd: 'stop' }); return; }
  if (st.state === 'recognizing') return;
  if (st.text.trim().length) send({ cmd: 'insert' });
  else send({ cmd: 'toggle' });
});
bCont.addEventListener('click', () => {
  if (st.state === 'recognizing') return;
  send({ cmd: 'toggleAppend' });
});
bCopy.addEventListener('click', () => send({ cmd: 'copy' }));

let textTimer = null;
function pushText() {
  send({ cmd: 'text', value: ta.value });
}
ta.addEventListener('input', () => {
  st.text = ta.value;
  clearTimeout(textTimer);
  textTimer = setTimeout(pushText, 120);
  render();
});
ta.addEventListener('focus', () => send({ cmd: 'textFocus', focused: true }));
ta.addEventListener('blur', () => { pushText(); send({ cmd: 'textFocus', focused: false }); });

el('rngVol').addEventListener('input', (e) => { el('lblVol').textContent = e.target.value + '%'; });
let prevLang = lang;
el('selLang').addEventListener('change', () => {
  const next = el('selLang').value;
  const rec = el('selRec');
  if (rec.value === prevLang) rec.value = next;
  prevLang = next;
  lang = next;
  applyLang();
  send({ cmd: 'lang', lang: next, recLang: rec.value });
});
document.querySelectorAll('#segModel button').forEach((b) => {
  b.addEventListener('click', () => {
    if (b.disabled) return;
    document.querySelectorAll('#segModel button').forEach((x) => x.classList.remove('sel'));
    b.classList.add('sel');
  });
});
el('bApply').addEventListener('click', saveSettings);
el('bFolder').addEventListener('click', () => send({ cmd: 'openFolder' }));

document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (st.view === 'settings') { closeSettings(); return; }
    if (st.panel) { setPanel(false); return; }
    send({ cmd: 'hide' });
  }
  if (e.ctrlKey && e.key === 'Enter') {
    e.preventDefault();
    if (st.text.trim().length) send({ cmd: 'insert' });
  }
});

/* drag */
let drag = null;
bar.addEventListener('pointerdown', (e) => {
  if (e.button !== 0 || e.target.closest('button')) return;
  drag = { x: e.screenX, y: e.screenY };
  send({ cmd: 'dragBegin' });
  try { bar.setPointerCapture(e.pointerId); } catch (err) { }
});
window.addEventListener('pointermove', (e) => {
  if (!drag) return;
  const dx = Math.round(e.screenX - drag.x);
  const dy = Math.round(e.screenY - drag.y);
  if (dx || dy) send({ cmd: 'dragMove', dx: dx, dy: dy });
});
window.addEventListener('pointerup', () => {
  if (!drag) return;
  drag = null;
  send({ cmd: 'dragEnd' });
});

/* ---------------- bridge ---------------- */

function onMessage(e) {
  const m = e.data;
  if (!m || !m.t) return;
  switch (m.t) {
    case 'init':
      lang = m.lang || 'ru';
      cfg = Object.assign(cfg, {
        devices: m.devices || [], micIndex: m.micIndex || 0, volume: m.volume || 60,
        model: m.model || 'small', autoPaste: !!m.autoPaste, recLang: m.recLang || 'ru',
        models: m.models || {}, paths: m.paths || {}
      });
      st.text = m.text || '';
      ta.value = st.text;
      applyLang();
      fillSettings(null);
      if (m.error) { st.status = m.error; render(); }
      break;
    case 'state':
      st.state = m.state || 'idle';
      st.level = typeof m.level === 'number' ? m.level : -90;
      st.status = m.status || '';
      if (typeof m.text === 'string') setText(m.text);
      render();
      break;
    case 'text':
      if (m.mode === 'replace') {
        const v = ta.value;
        const s = Math.max(0, Math.min(v.length, m.start | 0));
        const l = Math.max(0, Math.min(v.length - s, m.len | 0));
        ta.value = v.slice(0, s) + m.value + v.slice(s + l);
        ta.selectionStart = ta.selectionEnd = s + m.value.length;
        setText(ta.value);
        pushText();
      } else if (m.mode === 'append') {
        const v = ta.value.trimEnd();
        ta.value = v.length ? v + ' ' + m.value : m.value;
        setText(ta.value);
        pushText();
      } else if (m.mode === 'set') {
        ta.value = m.value;
        setText(m.value);
      }
      break;
    case 'result': {
      const v = typeof m.value === 'string' ? m.value : '';
      if (!v) break;
      if (m.mode === 'edit') {
        const base = ta.value;
        const s = Math.max(0, Math.min(base.length, ta.selectionStart | 0));
        const e = Math.max(s, Math.min(base.length, ta.selectionEnd | 0));
        ta.value = base.slice(0, s) + v + base.slice(e);
        ta.selectionStart = ta.selectionEnd = s + v.length;
        setText(ta.value);
        pushText();
        setPanel(true);
      } else if (m.mode === 'append') {
        const base = ta.value.trimEnd();
        ta.value = base.length ? base + ' ' + v : v;
        setText(ta.value);
        pushText();
        setPanel(true);
      } else {
        setText(v);
        if (m.paste) send({ cmd: 'paste', value: v });
        else setPanel(true);
      }
      st.state = 'idle';
      render();
      break;
    }
    case 'panel':
      setPanel(!!m.on);
      break;
    case 'toast':
      st.status = m.text || '';
      render();
      break;
    case 'settings':
      cfg = Object.assign(cfg, m.values || {});
      if (m.values && m.values.lang) lang = m.values.lang;
      fillSettings(null);
      applyLang();
      break;
  }
}

if (bridge) bridge.addEventListener('message', onMessage);

render();
applyLang();
layout();
send({ cmd: 'ready' });
