# Max Skitch

**English** · [Русский](README.ru.md) · [Українська](README.uk.md)

Offline voice typing for Windows. Press `Win + Ё`, speak, and the recognised text
lands in whatever window you were working in. Recognition runs locally on
whisper.cpp — nothing is sent to the cloud, no account, no API key.

![status](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D4)
![status](https://img.shields.io/badge/engine-whisper.cpp-4C8DFD)
![status](https://img.shields.io/badge/UI-WebView2%20%2B%20HTML%2FJS-6DB33F)

---

## Features

- **Local recognition** — `whisper.cpp` with `ggml-small` or `ggml-medium` models.
- **Web UI** — the card, text panel and settings are HTML/CSS/JS rendered in WebView2.
- **Insert anywhere** — text goes to the window that was active before you started.
- **Portable** — engines and models live inside the folder; move or rename it freely.
- **Three languages** — Russian, Ukrainian and English interface, and the same three
  (plus auto-detect) for speech recognition.
- **Auto-stop** — recording ends by itself after a pause in speech.
- **Level meter** — live input level straight from the audio stream.

## Requirements

| Component | Notes |
|---|---|
| Windows 10 / 11 | x64 |
| PowerShell 5.1 | ships with Windows |
| Microsoft Edge WebView2 Runtime | already present on systems with Edge |
| `bin\ffmpeg.exe` | bundled |
| `bin\whisper\whisper-cli.exe` + DLLs | bundled |
| `models\ggml-*.bin` | bundled, ~1 GB total |

## Quick start

1. Download or clone the folder (keep `bin\`, `models\`, `lib\`, `web\` next to the script).
2. Double-click **`Max Skitch.cmd`**.
3. Press `Win + Ё`, say a phrase, press `Win + Ё` again (or just pause — it stops by itself).

A rounded card appears at the bottom of the screen and an icon appears in the
notification area. First run detects the interface language from the Windows locale.

## Hotkeys

| Keys | Action |
|---|---|
| `Win + Ё` (`Win + \`` on a US layout) | start / stop recording |
| `Esc` | collapse the text panel, then hide the card |
| `Ctrl + Enter` | insert the text into the previous window |
| click the status line | expand / collapse the text panel |

In the settings you can also set the microphone, its input level, the recognition
model, automatic replacement of the selection, the interface language and the
recognition language.

## How it works

### Two halves

The program is a thin native shell plus a web front end:

```
┌───────────────────────────────┐        ┌──────────────────────────────┐
│  WebView2 window              │        │  PowerShell 5.1 process      │
│  web/index.html + app.js + css│◄──────►│  MaxSkitch.ps1               │
│  (card, text panel, settings) │ JSON   │  state machine, recording,   │
└───────────────────────────────┘        │  whisper, tray, hotkey, paste│
                                          └──────────────┬───────────────┘
                                                         │
                          ffmpeg.exe ──► rec.wav ──► whisper-cli.exe ──► rec.txt
```

- The window is borderless, always on top, DPI-scaled and clipped to a rounded
  region. Its size is driven by the page: the JS side asks for `320×72`
  (bar), `320×282` (bar + text panel) or `440×470` (settings).
- The page is served from the `web\` folder through WebView2 virtual host
  mapping (`https://app.local/index.html`) — no HTTP server, no ports.
- Backend and page talk over `window.chrome.webview.postMessage` /
  `PostWebMessageAsJson`. The protocol is described below.

### Recognition pipeline

1. **Capture.** `ffmpeg -f dshow -i "audio=@device_cm_{...}wave_{GUID}" -f s16le -ar 16000 -ac 1 -`
   reads the microphone and streams raw 16 kHz mono PCM to stdout.
2. **Store + measure.** A small C# class (`PcmRecorder`) writes the stream into a
   WAV file (44-byte header rewritten on stop) and computes RMS for every chunk,
   so the UI can draw the level meter without a second `ffmpeg` instance.
3. **Auto-stop.** Every 70 ms the timer compares the level with `-42 dB`. If speech
   lasted at least 280 ms and silence lasted 1600 ms, recording stops by itself.
4. **Transcribe.** `whisper-cli -m models\ggml-medium-q5_0.bin -f rec.wav -l ru -nt -otxt -of rec -t 6`
   writes `rec.txt`; output is redirected to `rec.log` for diagnostics.
5. **Deliver.** The text goes to the page with a mode: `set` (new text), `append`
   (continue), or `edit` (replace the selection inside the text panel). With
   auto-replace enabled, the page immediately asks the backend to paste.

### Insertion

The backend remembers the foreground window HWND that was active before the card
got focus. On paste it puts the text into the clipboard, hides the card, brings
that window back to the foreground, sends `Ctrl+V`, and restores the previous
clipboard contents. If the target window is gone, the text panel opens instead.

### State machine

`idle → recording → recognizing → idle` (plus a short `busy` state while the
recorder flushes). The hotkey toggles `recording`; the timer and whisper process
drive the rest. A second copy of the program is blocked by the named mutex
`Global\MaxSkitchApp`.

## Project structure

```
Max Skitch 2.0/
├─ Max Skitch.cmd            launcher (uses %~dp0, so the folder can be renamed)
├─ MaxSkitch.ps1             the whole backend: UI host, audio, whisper, tray
├─ Create-Shortcut.ps1       creates a fresh desktop shortcut for this location
├─ Создать ярлык.cmd         double-click wrapper for the line above
├─ README.md / .ru.md / .uk.md
├─ README.txt                short portable copy for offline reading
├─ web/
│  ├─ index.html             card + text panel + settings markup
│  ├─ style.css              dark theme, rounded card, transitions
│  └─ app.js                 all UI logic and the message bridge
├─ lib/WebView2/             Microsoft.Web.WebView2.Core.dll, WinForms.dll, Loader.dll
├─ bin/
│  ├─ ffmpeg.exe             microphone capture
│  └─ whisper/               whisper-cli.exe + whisper.dll + ggml*.dll
├─ models/
│  ├─ ggml-small.bin         fast model (~0.45 GB)
│  └─ ggml-medium-q5_0.bin   accurate model (~0.5 GB)
├─ settings.json             created on first save
├─ MaxSkitch.log             runtime journal (paths, errors, recognised text)
├─ tmp/                      rec.wav, rec.txt, rec.log
└─ .webview/                 WebView2 user data (cache, profile)
```

## Key files

| File | What it is responsible for |
|---|---|
| `Max Skitch.cmd` | Starts PowerShell hidden with `-File "%~dp0MaxSkitch.ps1"`. Relative path — survives moving the folder. |
| `MaxSkitch.ps1` | Everything native: resolves engine paths, loads WebView2, hosts the window, records, launches whisper, drives the tray, registers the hotkey, pastes text, applies settings. |
| `web/index.html` | Single-page UI: bar with mic button, expandable text area, settings sheet. Strict CSP, no inline scripts. |
| `web/app.js` | Renders state, keeps the textarea in sync, owns the settings form, handles drag by reporting pointer deltas to the backend, and implements the message protocol. |
| `web/style.css` | Theme, layout sizes, mic pulse animation, switches and segmented controls. |
| `lib/WebView2/*.dll` | .NET wrapper and native loader for the embedded browser. |
| `bin/whisper/whisper-cli.exe` | The recogniser itself. Needs `whisper.dll`, `ggml.dll`, `ggml-base.dll` and `ggml-cpu-*.dll` from the same folder. |
| `bin/ffmpeg.exe` | Captures DirectShow audio and converts it to 16 kHz mono PCM. |
| `settings.json` | User settings, see below. |

## Message protocol

Page → backend (`{ "cmd": ... }`):

| Command | Payload | Meaning |
|---|---|---|
| `ready` | — | page loaded, backend sends `init` |
| `toggle` | — | start / stop recording |
| `toggleAppend` | — | continue the current text |
| `stop` | — | stop and transcribe |
| `paste` | `value` | insert the given text into the target window |
| `copy` | `value` | put the text into the clipboard |
| `text` | `value` | textarea content changed |
| `textFocus` | `focused` | whether the textarea is focused (enables in-panel editing) |
| `resize` | `w`, `h` | requested window size in CSS pixels |
| `save` | `micIndex`, `volume`, `model`, `autoPaste`, `lang`, `recLang` | save settings |
| `lang` | `lang`, `recLang` | language changed live |
| `hide`, `quit`, `openFolder` | — | hide card, exit, open program folder |
| `dragBegin`, `dragMove`, `dragEnd` | `dx`, `dy` | window dragging |

Backend → page (`{ "t": ... }`):

| Message | Contents |
|---|---|
| `init` | devices, selected mic, volume, model, models availability, paths, language, current text |
| `state` | `state`, `level` (dB), `status` |
| `result` | recognised `value`, `mode` (`set`/`append`/`edit`), `paste` flag |
| `text` | replace the textarea (`mode: set`) |
| `panel` | force the text panel open/closed |
| `settings` | updated values after saving from the tray |
| `openSettings` | open the settings sheet from the tray |
| `toast` | short status line |

## Settings

`settings.json`, created on first save:

```json
{
  "id": "{0.0.1.00000000}.{...}",
  "volume": 60,
  "model": "medium",
  "autoPaste": true,
  "lang": "ru",
  "recLang": "uk",
  "speechDir": "C:\\Path\\To\\Max Skitch 2.0"
}
```

| Field | Meaning |
|---|---|
| `id` | DirectShow endpoint id of the selected microphone |
| `volume` | Input level, 0–100 |
| `model` | `small` or `medium` |
| `autoPaste` | Replace the selection in the previous window automatically |
| `lang` | Interface language: `ru`, `en`, `uk` |
| `recLang` | Recognition language: `ru`, `en`, `uk`, `auto` |
| `speechDir` | Optional override for the folder with engines and models |

## Portable usage

All paths are derived from the folder that contains `MaxSkitch.ps1`, so the program
can be renamed, moved to another disk or copied to a USB stick. Engines are looked up
in this order:

1. `speechDir` from `settings.json`, or `MAXSKITCH_HOME`;
2. the program folder;
3. its parent folder;
4. `%USERPROFILE%\SpeechLocal`;
5. `C:\Users\maks\SpeechLocal` (legacy location, kept for compatibility).

If the folder is read-only, `settings.json`, the log and temporary files go to
`%LOCALAPPDATA%\MaxSkitch` instead.

The `.lnk` shortcut contains an absolute path and breaks after moving the folder —
run `Создать ярлык.cmd` (`Create-Shortcut.ps1`) to make a new one.

## Languages

- Interface: Russian, Ukrainian, English (switchable live in the settings).
- Recognition: Russian, Ukrainian, English, or automatic detection.
- Changing the interface language also moves the recognition language along, unless
  you picked one explicitly.
- On the first run the language is taken from the Windows display language.

## Troubleshooting

- **Nothing happens on the hotkey** — the combination may be taken by another app;
  the log records `Win+Ё зарегистрирована: False`.
- **No text appears** — check `MaxSkitch.log`: it writes the resolved paths to
  `ffmpeg`, `whisper-cli` and the models, the whisper exit code and the recognised text.
- **Silence produces garbage** — single dashes and ellipses from whisper are dropped
  automatically; real text is never overwritten by them.
- **Virtual devices** — loopback sources like Stereo Mix or VB-Audio Cable are excluded
  from the microphone list on purpose.

## Publishing to GitHub

Binaries and models are large, so keep them out of the repository and attach them to a
release instead. A sensible `.gitignore`:

```gitignore
bin/
models/
lib/WebView2/
.webview/
tmp/
MaxSkitch.log
settings.json
```

That leaves the small, readable part of the project: `MaxSkitch.ps1`, `web/`, the
launchers and the documentation. Add the ~1 GB `bin` + `models` bundle to a release
asset so users can just unpack and run.

## Tech stack and credits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — local speech recognition.
- [FFmpeg](https://ffmpeg.org/) — audio capture and conversion.
- [Microsoft Edge WebView2](https://learn.microsoft.com/microsoft-edge/webview2/) — embedded browser.
- Windows Forms, WASAPI interop and Win32 hotkeys from PowerShell via `Add-Type`.
