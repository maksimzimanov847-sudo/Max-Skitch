$ErrorActionPreference = 'Stop'

$appDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$appName = 'Max Skitch'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:mutex = New-Object System.Threading.Mutex($false, 'Global\MaxSkitchApp')
if (-not $script:mutex.WaitOne(0)) { exit }

# ---------------------------------------------------------------------------
# куда писать настройки, лог и временные файлы
# ---------------------------------------------------------------------------
function Test-Writable($dir) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) { return $false }
        $p = Join-Path $dir ('.w_' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($p, 'x')
        Remove-Item -LiteralPath $p -Force
        return $true
    } catch { return $false }
}

$dataDir = $appDir
if (-not (Test-Writable $appDir)) {
    $dataDir = Join-Path $env:LOCALAPPDATA 'MaxSkitch'
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
}

$log     = Join-Path $dataDir 'MaxSkitch.log'
$cfgFile = Join-Path $dataDir 'settings.json'
$webDir  = Join-Path $appDir 'web'
$libDir  = Join-Path $appDir 'lib\WebView2'
$tmpDir  = Join-Path $dataDir 'tmp'
$wav     = Join-Path $tmpDir 'rec.wav'
$outBase = Join-Path $tmpDir 'rec'

if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }

function Write-Log($m) {
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content -Path $log -Encoding UTF8
    } catch { }
}

# ---------------------------------------------------------------------------
# настройки
# ---------------------------------------------------------------------------
$script:cfg = [ordered]@{}
$script:micId = ''
$script:micVol = 60
$script:modelName = 'small'
$script:autoPaste = $true
$script:lang = 'ru'
$script:recLang = 'ru'
$script:speechDir = ''

$firstRun = -not (Test-Path -LiteralPath $cfgFile)
if (-not $firstRun) {
    try {
        $j = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.id) { $script:micId = [string]$j.id }
        if ($null -ne $j.volume) { $script:micVol = [int]$j.volume }
        if ($j.model) { $script:modelName = [string]$j.model }
        if ($null -ne $j.autoPaste) { $script:autoPaste = [bool]$j.autoPaste }
        if ($j.lang) { $script:lang = [string]$j.lang }
        if ($j.recLang) { $script:recLang = [string]$j.recLang }
        if ($j.speechDir) { $script:speechDir = [string]$j.speechDir }
    } catch { Write-Log "не удалось прочитать settings.json: $($_.Exception.Message)" }
}

if ($firstRun) {
    $uiLang = ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName)
    if (@('ru', 'en', 'uk') -contains $uiLang) {
        $script:lang = $uiLang
        $script:recLang = $uiLang
    }
}

if (@('ru', 'en', 'uk') -notcontains $script:lang) { $script:lang = 'ru' }
if (@('ru', 'en', 'uk', 'auto') -notcontains $script:recLang) { $script:recLang = $script:lang }

function Save-Cfg {
    $o = [ordered]@{
        id        = $script:micId
        volume    = [int]$script:micVol
        model     = $script:modelName
        autoPaste = [bool]$script:autoPaste
        lang      = $script:lang
        recLang   = $script:recLang
        speechDir = $script:speechDir
    }
    try { ($o | ConvertTo-Json) | Set-Content -LiteralPath $cfgFile -Encoding UTF8 } catch { Write-Log "не удалось сохранить настройки: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# поиск движков: сначала рядом с программой, потом старые места
# ---------------------------------------------------------------------------
function Find-First($paths) {
    foreach ($p in $paths) {
        if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return (Resolve-Path -LiteralPath $p).Path }
    }
    return $null
}

$rootCandidates = New-Object System.Collections.ArrayList
if ($script:speechDir) { [void]$rootCandidates.Add($script:speechDir) }
if ($env:MAXSKITCH_HOME) { [void]$rootCandidates.Add($env:MAXSKITCH_HOME) }
[void]$rootCandidates.Add($appDir)
[void]$rootCandidates.Add((Split-Path -Parent $appDir))
if ($env:USERPROFILE) { [void]$rootCandidates.Add((Join-Path $env:USERPROFILE 'SpeechLocal')) }
[void]$rootCandidates.Add('C:\Users\maks\SpeechLocal')

$ffmpegCandidates = New-Object System.Collections.ArrayList
$whisperCandidates = New-Object System.Collections.ArrayList
foreach ($r in $rootCandidates) {
    [void]$ffmpegCandidates.Add((Join-Path $r 'bin\ffmpeg.exe'))
    [void]$ffmpegCandidates.Add((Join-Path $r 'ffmpeg\ffmpeg-n8.1-latest-win64-lgpl-8.1\bin\ffmpeg.exe'))
    [void]$ffmpegCandidates.Add((Join-Path $r 'ffmpeg.exe'))
    [void]$whisperCandidates.Add((Join-Path $r 'bin\whisper\whisper-cli.exe'))
    [void]$whisperCandidates.Add((Join-Path $r 'whisper\Release\whisper-cli.exe'))
}

$script:ffmpeg = Find-First $ffmpegCandidates
$script:whisper = Find-First $whisperCandidates
if (-not $script:ffmpeg) {
    $cmd = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:ffmpeg = $cmd.Source }
}

function Resolve-Model($name) {
    $list = New-Object System.Collections.ArrayList
    foreach ($r in $rootCandidates) {
        [void]$list.Add((Join-Path $r "models\$name"))
        [void]$list.Add((Join-Path $r $name))
    }
    return Find-First $list
}

$modelSmall  = Resolve-Model 'ggml-small.bin'
$modelMedium = Resolve-Model 'ggml-medium-q5_0.bin'

$script:speechDir = if ($script:ffmpeg) { Split-Path -Parent (Split-Path -Parent $script:ffmpeg) } else { $appDir }
if (-not $modelSmall -and $modelMedium) { $modelSmall = $null }

$script:modelPath = $modelSmall
if ($script:modelName -eq 'medium' -and $modelMedium) {
    $script:modelPath = $modelMedium
} else {
    $script:modelName = 'small'
    $script:modelPath = $modelSmall
}

Write-Log "--- запуск ---"
Write-Log "папка программы: $appDir"
Write-Log "ffmpeg: $(if ($script:ffmpeg) { $script:ffmpeg } else { 'НЕ НАЙДЕН' })"
Write-Log "whisper: $(if ($script:whisper) { $script:whisper } else { 'НЕ НАЙДЕН' })"
Write-Log "модели: small=$(if ($modelSmall) { 'да' } else { 'нет' }), medium=$(if ($modelMedium) { 'да' } else { 'нет' })"

# ---------------------------------------------------------------------------
# строки для меню в трее
# ---------------------------------------------------------------------------
$script:strings = @{
    ru = @{
        open = 'Открыть'; settings = 'Настройки'; autoReplace = 'Заменять выделенное автоматически'; exit = 'Выход'
        trayTip = 'Max Skitch - голосовой ввод (Win+Ё)'; copied = 'Текст скопирован'
        noTarget = 'Нет окна для вставки'; noFfmpeg = 'Не найден ffmpeg (bin\ffmpeg.exe)'; noMic = 'Не выбран микрофон'
        noWhisper = 'Не найден whisper-cli (bin\whisper\whisper-cli.exe)'; noModels = 'Не найдены модели (models\ggml-*.bin)'
    }
    en = @{
        open = 'Open'; settings = 'Settings'; autoReplace = 'Replace selection automatically'; exit = 'Exit'
        trayTip = 'Max Skitch - voice input (Win+`)'; copied = 'Text copied'
        noTarget = 'No target window'; noFfmpeg = 'ffmpeg not found (bin\ffmpeg.exe)'; noMic = 'No microphone selected'
        noWhisper = 'whisper-cli not found (bin\whisper\whisper-cli.exe)'; noModels = 'No models found (models\ggml-*.bin)'
    }
    uk = @{
        open = 'Відкрити'; settings = 'Налаштування'; autoReplace = 'Замінювати виділене автоматично'; exit = 'Вихід'
        trayTip = 'Max Skitch - голосове введення (Win+Ё)'; copied = 'Текст скопійовано'
        noTarget = 'Нема вікна для вставлення'; noFfmpeg = 'Не знайдено ffmpeg (bin\\ffmpeg.exe)'; noMic = 'Не вибрано мікрофон'
        noWhisper = 'Не знайдено whisper-cli (bin\\whisper\\whisper-cli.exe)'; noModels = 'Не знайдено моделей (models\\ggml-*.bin)'
    }
}

function T($key) {
    $table = $script:strings[$script:lang]
    if ($table -and $table.ContainsKey($key)) { return $table[$key] }
    return $script:strings['ru'][$key]
}

# ---------------------------------------------------------------------------
# библиотеки WebView2
# ---------------------------------------------------------------------------
$wvCore  = Join-Path $libDir 'Microsoft.Web.WebView2.Core.dll'
$wvForms = Join-Path $libDir 'Microsoft.Web.WebView2.WinForms.dll'
$wvLoad  = Join-Path $libDir 'WebView2Loader.dll'

if (-not (Test-Path -LiteralPath $wvCore) -or -not (Test-Path -LiteralPath $wvForms) -or -not (Test-Path -LiteralPath $wvLoad)) {
    Write-Log 'ОШИБКА: не найдены библиотеки WebView2 в lib\WebView2'
    [void][System.Windows.Forms.MessageBox]::Show("Не найдены библиотеки WebView2:`n$libDir`n`nПереустановите программу или положите файлы DLL на место.", $appName)
    exit
}

$env:PATH = "$libDir;$env:PATH"
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $dataDir '.webview'
try {
    [void][System.Reflection.Assembly]::LoadFrom($wvCore)
    [void][System.Reflection.Assembly]::LoadFrom($wvForms)
} catch {
    Write-Log "ОШИБКА загрузки WebView2: $($_.Exception.Message)"
    [void][System.Windows.Forms.MessageBox]::Show("Не удалось загрузить WebView2:`n$($_.Exception.Message)", $appName)
    exit
}

# ---------------------------------------------------------------------------
# нативный слой
# ---------------------------------------------------------------------------
$src = @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public static class Ui {
    public static GraphicsPath RoundRect(Rectangle r, int rad) {
        GraphicsPath p = new GraphicsPath();
        int d = rad * 2;
        if (d <= 0 || r.Width <= d || r.Height <= d) { p.AddRectangle(r); return p; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

public class SkitchForm : Form {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

    public event EventHandler HotkeyPressed;
    public bool HotkeyOk = false;
    private IntPtr _hkHwnd = IntPtr.Zero;

    public SkitchForm() {
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.None;
        BackColor = Color.FromArgb(22, 22, 26);
        KeyPreview = true;
    }

    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ClassStyle |= 0x00020000;
            return cp;
        }
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        if (_hkHwnd == Handle) { return; }
        if (_hkHwnd != IntPtr.Zero) { try { UnregisterHotKey(_hkHwnd, 1); } catch { } }
        _hkHwnd = Handle;
        HotkeyOk = RegisterHotKey(Handle, 1, 0x0008, 0xC0);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0312) {
            EventHandler h = HotkeyPressed;
            if (h != null) { try { h(this, EventArgs.Empty); } catch { } }
            return;
        }
        base.WndProc(ref m);
    }

    protected override void Dispose(bool disposing) {
        try { UnregisterHotKey(Handle, 1); } catch { }
        base.Dispose(disposing);
    }
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms, System.Drawing

$audioSrc = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorComObject { }

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    int OpenPropertyStore(int access, out IntPtr store);
    int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    int GetState(out int state);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    int GetCount(out int count);
    int Item(int index, out IMMDevice device);
}

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    int EnumAudioEndpoints(int flow, int mask, out IMMDeviceCollection col);
    int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
    int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice dev);
    int RegisterEndpointNotificationCallback(IntPtr cb);
    int UnregisterEndpointNotificationCallback(IntPtr cb);
}

[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr p);
    int UnregisterControlChangeNotify(IntPtr p);
    int GetChannelCount(out uint c);
    int SetMasterVolumeLevel(float level, ref Guid ctx);
    int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    int GetMasterVolumeLevel(out float level);
    int GetMasterVolumeLevelScalar(out float level);
}

public class AudioDev {
    public string Name;
    public string Id;
    public float Volume;
}

public static class AudioApi {
    static IMMDeviceEnumerator E() { return (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject(); }

    public static List<AudioDev> CaptureDevices() {
        var list = new List<AudioDev>();
        IMMDeviceCollection col;
        if (E().EnumAudioEndpoints(1, 1, out col) != 0) return list;
        int n; col.GetCount(out n);
        for (int i = 0; i < n; i++) {
            IMMDevice d; col.Item(i, out d);
            string id; d.GetId(out id);
            var dev = new AudioDev();
            dev.Id = id;
            dev.Name = id;
            var iid = typeof(IAudioEndpointVolume).GUID;
            object o;
            if (d.Activate(ref iid, 23, IntPtr.Zero, out o) == 0) {
                var vol = (IAudioEndpointVolume)o;
                float v; if (vol.GetMasterVolumeLevelScalar(out v) == 0) dev.Volume = v;
            }
            list.Add(dev);
        }
        return list;
    }

    public static string DefaultCapture() {
        IMMDevice d;
        if (E().GetDefaultAudioEndpoint(1, 0, out d) != 0) return "";
        string id; d.GetId(out id);
        return id;
    }

    public static int SetVolume(string id, float scalar) {
        IMMDevice d;
        if (E().GetDevice(id, out d) != 0) return -1;
        var iid = typeof(IAudioEndpointVolume).GUID;
        object o;
        if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return -2;
        var vol = (IAudioEndpointVolume)o;
        Guid ctx = Guid.Empty;
        return vol.SetMasterVolumeLevelScalar(scalar, ref ctx);
    }

    public static float GetVolume(string id) {
        IMMDevice d;
        if (E().GetDevice(id, out d) != 0) return -1;
        var iid = typeof(IAudioEndpointVolume).GUID;
        object o;
        if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return -1;
        var vol = (IAudioEndpointVolume)o;
        float v; vol.GetMasterVolumeLevelScalar(out v);
        return v;
    }
}
'@

Add-Type -TypeDefinition $audioSrc -Language CSharp -ErrorAction Stop

$recSrc = @'
using System;
using System.IO;
using System.Threading;

public class PcmRecorder {
    public static volatile float LastDb = -90f;
    private Stream _in;
    private FileStream _out;
    private Thread _t;
    private volatile bool _run;
    private long _dataBytes;
    private const int Rate = 16000;
    private const short Channels = 1;
    private const short Bits = 16;

    public void Start(Stream input, string path) {
        LastDb = -90f;
        _dataBytes = 0;
        _out = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        WriteHeader();
        _in = input;
        _run = true;
        _t = new Thread(Loop);
        _t.IsBackground = true;
        _t.Start();
    }

    private void WriteHeader() {
        int blockAlign = Channels * Bits / 8;
        int byteRate = Rate * blockAlign;
        int dataLen = (int)_dataBytes;
        byte[] h = new byte[44];
        System.Text.Encoding.ASCII.GetBytes("RIFF").CopyTo(h, 0);
        BitConverter.GetBytes(36 + dataLen).CopyTo(h, 4);
        System.Text.Encoding.ASCII.GetBytes("WAVE").CopyTo(h, 8);
        System.Text.Encoding.ASCII.GetBytes("fmt ").CopyTo(h, 12);
        BitConverter.GetBytes(16).CopyTo(h, 16);
        BitConverter.GetBytes((short)1).CopyTo(h, 20);
        BitConverter.GetBytes(Channels).CopyTo(h, 22);
        BitConverter.GetBytes(Rate).CopyTo(h, 24);
        BitConverter.GetBytes(byteRate).CopyTo(h, 28);
        BitConverter.GetBytes((short)blockAlign).CopyTo(h, 32);
        BitConverter.GetBytes(Bits).CopyTo(h, 34);
        System.Text.Encoding.ASCII.GetBytes("data").CopyTo(h, 36);
        BitConverter.GetBytes(dataLen).CopyTo(h, 40);
        _out.Position = 0;
        _out.Write(h, 0, 44);
        _out.Position = 44 + _dataBytes;
    }

    private void Loop() {
        byte[] buf = new byte[8192];
        try {
            while (_run) {
                int n = _in.Read(buf, 0, buf.Length);
                if (n <= 0) break;
                _out.Write(buf, 0, n);
                _dataBytes += n;
                float sum = 0; int cnt = 0;
                for (int i = 0; i + 1 < n; i += 2) {
                    short v = BitConverter.ToInt16(buf, i);
                    sum += (float)v * v;
                    cnt++;
                }
                if (cnt > 0) {
                    float rms = (float)Math.Sqrt(sum / cnt);
                    float db = rms < 0.5f ? -90f : (float)(20.0 * Math.Log10(rms / 32768.0));
                    LastDb = db;
                }
            }
        } catch { }
    }

    public void Stop() {
        _run = false;
        try { if (_t != null) _t.Join(2000); } catch { }
        try {
            if (_out != null) {
                WriteHeader();
                _out.Flush();
                _out.Close();
                _out = null;
            }
        } catch { }
    }
}
'@

Add-Type -TypeDefinition $recSrc -Language CSharp -ErrorAction Stop

try { [void][SkitchForm]::SetProcessDPIAware() } catch { }

# ---------------------------------------------------------------------------
# устройства
# ---------------------------------------------------------------------------
function Get-DshowName($endpointId) {
    $g = $endpointId.Substring($endpointId.LastIndexOf('.') + 1).ToUpper()
    return "audio=@device_cm_{33D9A762-90C8-11D0-BD43-00A0C911CE86}\wave_$g"
}

function Get-DevName($endpointId) {
    $g = $endpointId.Substring($endpointId.LastIndexOf('.') + 1)
    $k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture\$g\Properties"
    $n = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    if ($n) { return "$n" }
    return $g
}

function Get-DevDesc($endpointId) {
    $g = $endpointId.Substring($endpointId.LastIndexOf('.') + 1)
    $k = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture\$g\Properties"
    $n = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    if ($n) { return "$n" }
    return ''
}

$script:loopbackPatterns = @(
    'stereo mix', 'стерео микшер', 'стереомикшер', 'stereomix',
    'wave out mix', 'waveout mix', 'what u hear', 'what you hear',
    'loopback', 'cable output', 'vb-audio', 'virtual cable', 'voicemeeter',
    'monitor of', 'суммарный сигнал'
)

function Test-LoopbackDevice($endpointId) {
    if (-not $endpointId) { return $false }
    $text = ((Get-DevName $endpointId) + ' ' + (Get-DevDesc $endpointId)).ToLowerInvariant()
    foreach ($p in $script:loopbackPatterns) {
        if ($text.Contains($p)) { return $true }
    }
    return $false
}

$script:allDevices = [AudioApi]::CaptureDevices()
$deviceList = New-Object System.Collections.ArrayList
$script:excluded = New-Object System.Collections.ArrayList
foreach ($d in $script:allDevices) {
    if (Test-LoopbackDevice $d.Id) {
        [void]$script:excluded.Add("$(Get-DevName $d.Id) ($(Get-DevDesc $d.Id))")
    } else {
        [void]$deviceList.Add($d)
    }
}

if (-not $script:micId) { $script:micId = [AudioApi]::DefaultCapture() }
if (Test-LoopbackDevice $script:micId) { $script:micId = '' }
$found = $false
foreach ($d in $deviceList) { if ($d.Id -eq $script:micId) { $found = $true } }
if (-not $found -and $deviceList.Count -gt 0) { $script:micId = $deviceList[0].Id }
$script:micDshow = if ($script:micId) { Get-DshowName $script:micId } else { '' }

# ---------------------------------------------------------------------------
# окно
# ---------------------------------------------------------------------------
$script:scale = 1.0
$script:CSS_BAR = @{ w = 320; h = 72 }
$script:bottomGap = 28

$form = New-Object SkitchForm
$form.Width = 320
$form.Height = 72
$form.ShowInTaskbar = $false

$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$wv.Dock = [System.Windows.Forms.DockStyle]::Fill
try { $wv.DefaultBackgroundColor = [System.Drawing.Color]::FromArgb(22, 22, 26) } catch { }
$form.Controls.Add($wv)

$null = $form.Handle
try {
    $gfx = [System.Drawing.Graphics]::FromHwnd($form.Handle)
    $script:scale = [double]$gfx.DpiX / 96.0
    $gfx.Dispose()
} catch { $script:scale = 1.0 }
if ($script:scale -le 0.1) { $script:scale = 1.0 }

function Apply-Region {
    try {
        if ($form.Width -le 0 -or $form.Height -le 0) { return }
        $old = $form.Region
        $form.Region = New-Object System.Drawing.Region ([Ui]::RoundRect((New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height), [int](12 * $script:scale)))
        if ($old) { $old.Dispose() }
    } catch { }
}

function Set-FormSize([int]$cssW, [int]$cssH) {
    try {
        $w = [int][Math]::Round($cssW * $script:scale)
        $h = [int][Math]::Round($cssH * $script:scale)
        if ($w -lt 120) { $w = 120 }
        if ($h -lt 40) { $h = 40 }
        if ($form.Width -eq $w -and $form.Height -eq $h) { return }

        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $bottom = $form.Top + $form.Height
        $centerX = $form.Left + [int]($form.Width / 2)

        $form.Size = New-Object System.Drawing.Size($w, $h)
        $form.Left = [int]($centerX - $w / 2)
        $form.Top = [int]($bottom - $h)

        if ($form.Top -lt $wa.Y) { $form.Top = [int]$wa.Y }
        if ($form.Bottom -gt $wa.Bottom) { $form.Top = [int]($wa.Bottom - $h) }
        if ($form.Right -gt $wa.Right) { $form.Left = [int]($wa.Right - $w) }
        if ($form.Left -lt $wa.X) { $form.Left = [int]$wa.X }

        Apply-Region
        $form.Invalidate()
    } catch {
        Write-Log "ОШИБКА размера окна: $($_.Exception.Message)"
    }
}

$wa0 = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$w0 = [int][Math]::Round($script:CSS_BAR.w * $script:scale)
$h0 = [int][Math]::Round($script:CSS_BAR.h * $script:scale)
$form.Size = New-Object System.Drawing.Size($w0, $h0)
$form.Left = [int]($wa0.X + ($wa0.Width - $w0) / 2)
$form.Top = [int]($wa0.Bottom - $h0 - ($script:bottomGap * $script:scale))
Apply-Region

# ---------------------------------------------------------------------------
# мост web <-> powershell
# ---------------------------------------------------------------------------
$script:core = $null
$script:uiReady = $false
$script:state = 'idle'
$script:text = ''
$script:status = ''
$script:inAppEdit = $false
$script:appendMode = $false
$script:targetHwnd = [IntPtr]::Zero
$script:targetPid = 0
$script:dragStart = $null
$script:settingsOpen = $false
$script:proc = $null
$script:wproc = $null
$script:wstart = $null
$script:rec = $null
$script:speechMs = 0
$script:silentMs = 0
$script:autoStop = $false
$script:vadThr = -42
$script:silenceLimit = 1600

function Send-Json($obj) {
    if (-not $script:core) { return }
    try {
        $json = $obj | ConvertTo-Json -Depth 6 -Compress
        $script:core.PostWebMessageAsJson($json)
    } catch { Write-Log "не удалось отправить сообщение в UI: $($_.Exception.Message)" }
}

function Get-UiError {
    if (-not $script:whisper) { return (T 'noWhisper') }
    if (-not $modelSmall -and -not $modelMedium) { return (T 'noModels') }
    if (-not $script:ffmpeg) { return (T 'noFfmpeg') }
    return ''
}

function Send-Init {
    $names = @()
    foreach ($d in $deviceList) { $names += (Get-DevName $d.Id) }
    $idx = 0
    for ($i = 0; $i -lt $deviceList.Count; $i++) { if ($deviceList[$i].Id -eq $script:micId) { $idx = $i } }

    Send-Json @{
        t         = 'init'
        lang      = $script:lang
        micIndex  = $idx
        volume    = [int]$script:micVol
        model     = $script:modelName
        autoPaste = [bool]$script:autoPaste
        recLang   = $script:recLang
        devices   = $names
        models    = @{ small = [bool]$modelSmall; medium = [bool]$modelMedium }
        paths     = @{ app = $appDir; engines = (Split-Path -Parent (Split-Path -Parent $script:ffmpeg)) }
        text      = $script:text
        error     = (Get-UiError)
    }
}

function Send-State {
    $level = -90
    try { $level = [double][PcmRecorder]::LastDb } catch { }
    Send-Json @{ t = 'state'; state = $script:state; level = [Math]::Round($level, 1); status = $script:status }
}

function Send-TextSet([string]$value) {
    $script:text = $value
    Send-Json @{ t = 'text'; mode = 'set'; value = $value }
}

function Show-Bar {
    try {
        if (-not $form.Visible) { $form.Show() }
        $form.Activate()
        $form.BringToFront()
    } catch { }
}

function Show-SettingsFromTray {
    Show-Bar
    Send-Json @{ t = 'openSettings' }
}

# ---------------------------------------------------------------------------
# запись и распознавание
# ---------------------------------------------------------------------------
function Start-Rec {
    if (-not $script:ffmpeg) {
        $script:status = (T 'noFfmpeg'); Send-State
        Write-Log 'запись невозможна: нет ffmpeg'
        return
    }
    if (Test-LoopbackDevice $script:micId) {
        Write-Log "ЗАПИСЬ ОТКЛОНЕНА: устройство '$(Get-DevName $script:micId)' является системным источником"
        return
    }
    if (-not $script:micDshow) { $script:micDshow = Get-DshowName $script:micId }
    if (-not $script:micDshow) {
        $script:status = (T 'noMic')
        Send-State
        return
    }

    try { if (Test-Path -LiteralPath $wav) { Remove-Item -LiteralPath $wav -Force } } catch { }

    $ffArgs = "-hide_banner -loglevel error -f dshow -i `"$($script:micDshow)`" -map 0:a:0 -f s16le -ar 16000 -ac 1 -"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:ffmpeg
    $psi.Arguments = $ffArgs
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $script:proc = [System.Diagnostics.Process]::Start($psi)

    $script:rec = New-Object PcmRecorder
    $script:rec.Start($script:proc.StandardOutput.BaseStream, $wav)
    $script:state = 'recording'
    $script:speechMs = 0
    $script:silentMs = 0
    $script:autoStop = $false
    $script:status = ''
    Send-State
    Write-Log "запись начата: '$((Get-DevName $script:micId))' ($($script:micDshow))"
}

function Stop-Rec {
    if ($null -eq $script:proc) { return }
    $procId = $script:proc.Id
    try { $script:proc.StandardInput.WriteLine('q'); $script:proc.StandardInput.Flush() } catch { }
    $script:proc.WaitForExit(6000) | Out-Null
    if (-not $script:proc.HasExited) {
        try { & taskkill.exe /PID $procId /F 2>&1 | Out-Null } catch { }
        try { $script:proc.Kill() } catch { }
    }
    try { if ($script:rec) { $script:rec.Stop() } } catch { }
    try { $script:proc.Dispose() } catch { }
    $script:proc = $null
    $script:state = 'busy'
    Send-State
    Write-Log "запись остановлена (pid $procId)"
}

function Start-Text {
    if (-not $script:whisper) {
        $script:state = 'idle'; $script:status = (T 'noWhisper'); Send-State; return
    }
    if (-not $script:modelPath) {
        $script:state = 'idle'; $script:status = (T 'noModels'); Send-State; return
    }
    if (-not (Test-Path -LiteralPath $wav)) {
        $script:state = 'idle'; Write-Log 'нет файла записи'; Send-State; return
    }
    $len = (Get-Item -LiteralPath $wav).Length
    Write-Log "размер записи: $len байт"
    if ($len -lt 20000) {
        $script:state = 'idle'; Write-Log 'слишком короткая запись'; Send-State; return
    }
    if (Test-Path -LiteralPath "$outBase.txt") { Remove-Item -LiteralPath "$outBase.txt" -Force -ErrorAction SilentlyContinue }

    $langArg = if ($script:recLang -and $script:recLang -ne 'auto') { $script:recLang } else { 'auto' }
    Write-Log "модель: $($script:modelName), язык: $langArg"
    $cmdArgs = '/c ""' + $script:whisper + '" -m "' + $script:modelPath + '" -f "' + $wav + '" -l ' + $langArg + ' -nt -otxt -of "' + $outBase + '" -t 6 > "' + $outBase + '.log" 2>&1"'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = $cmdArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $script:wproc = [System.Diagnostics.Process]::Start($psi)
    $script:wstart = Get-Date
    $script:state = 'recognizing'
    $script:status = ''
    Send-State
    Write-Log 'распознавание запущено'
}

function Finish-Text {
    $code = -1
    try { $code = $script:wproc.ExitCode } catch { }
    try { $script:wproc.Dispose() } catch { }
    $script:wproc = $null
    Write-Log "whisper код: $code"

    $t = $null
    if (Test-Path -LiteralPath "$outBase.txt") {
        try { $t = (Get-Content -LiteralPath "$outBase.txt" -Raw -Encoding UTF8).Trim() } catch { }
    }
    if ($t -and $t -match '^[\s\-–—\.…,;:!?]+$') { Write-Log "отброшен мусор распознавания: '$t'"; $t = $null }
    $script:state = 'idle'
    $script:status = ''

    if ($t) {
        if ($script:inAppEdit) {
            $mode = 'edit'
            $paste = $false
        } elseif ($script:appendMode) {
            $mode = 'append'
            $paste = $false
        } else {
            $mode = 'set'
            $paste = [bool]$script:autoPaste
        }
        $script:text = $t
        Send-Json @{ t = 'result'; value = $t; mode = $mode; paste = $paste }
        Write-Log "распознано ($mode): $t"
    } else {
        Write-Log 'не распознано'
        if ($script:inAppEdit) { Send-Json @{ t = 'text'; mode = 'set'; value = $script:text } }
    }
    Send-State
}

function Invoke-Toggle([switch]$Append) {
    try {
        if ($script:state -eq 'recognizing') { return }
        if ($script:state -eq 'recording') { Stop-Rec; Start-Text; return }

        if (-not $form.Visible) { Show-Bar }
        $script:appendMode = [bool]$Append
        if (-not $Append -and -not $script:inAppEdit) { $script:text = ''; Send-Json @{ t = 'text'; mode = 'set'; value = '' } }
        Start-Rec
    } catch {
        Write-Log "ОШИБКА запуска записи: $($_.Exception.Message)"
        $script:state = 'idle'
        Send-State
    }
}

# ---------------------------------------------------------------------------
# вставка в активное окно
# ---------------------------------------------------------------------------
function Update-Target {
    try {
        $fg = [SkitchForm]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero -or $fg -eq $form.Handle) { return }
        if (-not [SkitchForm]::IsWindow($fg)) { return }
        $procId = [uint32]0
        [void][SkitchForm]::GetWindowThreadProcessId($fg, [ref]$procId)
        if ($procId -eq $PID) { return }
        $script:targetHwnd = $fg
        $script:targetPid = [int]$procId
    } catch { }
}

function Paste-ToTarget([string]$value) {
    if (-not $value) { return $false }
    $h = [IntPtr]$script:targetHwnd
    if ($h -eq [IntPtr]::Zero -or $h -eq $form.Handle -or -not [SkitchForm]::IsWindow($h)) {
        Write-Log "вставка отменена: окно-получатель недоступно (hwnd $h)"
        $script:status = (T 'noTarget')
        Send-Json @{ t = 'panel'; on = $true }
        Send-State
        return $false
    }

    $oldClip = $null
    $hadText = $false
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $oldClip = [System.Windows.Forms.Clipboard]::GetText()
            $hadText = $true
        }
    } catch { }

    try { Set-Clipboard -Value $value } catch { Write-Log "буфер: $($_.Exception.Message)" }
    $form.Hide()
    Start-Sleep -Milliseconds 80
    [void][SkitchForm]::ShowWindow($h, 9)
    $ok = [SkitchForm]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 200
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 350
    if ($hadText) { try { Set-Clipboard -Value $oldClip } catch { } }
    $script:state = 'idle'
    Write-Log "текст вставлен в окно $h (фокус возвращён: $ok)"
    Send-State
    return $true
}

# ---------------------------------------------------------------------------
# настройки из UI
# ---------------------------------------------------------------------------
function Apply-Settings($m) {
    try {
        $idx = [int]$m.micIndex
        if ($idx -ge 0 -and $idx -lt $deviceList.Count) {
            $script:micId = $deviceList[$idx].Id
            $script:micDshow = Get-DshowName $script:micId
        }
        $script:micVol = [int]$m.volume
        if ($script:micId) { [void][AudioApi]::SetVolume($script:micId, [single]($script:micVol / 100.0)) }

        if ($m.model -eq 'medium' -and $modelMedium) {
            $script:modelName = 'medium'
            $script:modelPath = $modelMedium
        } else {
            $script:modelName = 'small'
            $script:modelPath = $modelSmall
        }

        $script:autoPaste = [bool]$m.autoPaste
        if ($m.recLang) { $script:recLang = [string]$m.recLang }
        if ($m.lang -and $script:strings.ContainsKey([string]$m.lang)) { $script:lang = [string]$m.lang }

        Save-Cfg
        Apply-MenuText
        Send-Json @{ t = 'settings'; values = @{
                micIndex = $idx; volume = $script:micVol; model = $script:modelName
                autoPaste = $script:autoPaste; lang = $script:lang; recLang = $script:recLang
            }
        }
        Write-Log "настройки сохранены: $($script:micId) / $($script:micVol)% / $($script:modelName) / автозамена $($script:autoPaste) / язык $($script:lang)"
    } catch {
        Write-Log "ОШИБКА сохранения настроек: $($_.Exception.Message)"
    }
}

function Apply-MenuText {
    try {
        $tOpen.Text = (T 'open')
        $tSettings.Text = (T 'settings')
        $tAuto.Text = (T 'autoReplace')
        $tExit.Text = (T 'exit')
        $tray.Text = (T 'trayTip')
    } catch { }
}

# ---------------------------------------------------------------------------
# обработка сообщений из web
# ---------------------------------------------------------------------------
function Handle-Message($json) {
    $m = $null
    try { $m = $json | ConvertFrom-Json } catch { return }
    if (-not $m -or -not $m.cmd) { return }
    if ($m.cmd -in @('ready', 'toggle', 'save', 'quit', 'hide', 'paste', 'lang')) { Write-Log "UI: $($m.cmd)" }

    switch ([string]$m.cmd) {
        'ready' {
            $script:uiReady = $true
            Send-Init
        }
        'toggle' { Invoke-Toggle }
        'toggleAppend' { Invoke-Toggle -Append }
        'stop' { if ($script:state -eq 'recording') { Stop-Rec; Start-Text } }
        'paste' { [void](Paste-ToTarget ([string]$m.value)) }
        'copy' {
            try { Set-Clipboard -Value ([string]$m.value); $script:status = (T 'copied'); Send-Json @{ t = 'toast'; text = $script:status } } catch { }
        }
        'text' { $script:text = [string]$m.value }
        'textFocus' { $script:inAppEdit = [bool]$m.focused }
        'resize' {
            if ($script:uiReady) { Set-FormSize ([int]$m.w) ([int]$m.h) }
        }
        'save' { Apply-Settings $m }
        'lang' {
            if ($m.lang -and $script:strings.ContainsKey([string]$m.lang)) { $script:lang = [string]$m.lang }
            if ($m.recLang) { $script:recLang = [string]$m.recLang }
            Save-Cfg
            Apply-MenuText
            Write-Log "язык: интерфейс $($script:lang), распознавание $($script:recLang)"
        }
        'openSettings' { $script:settingsOpen = $true }
        'settingsOpen' { $script:settingsOpen = $true }
        'settingsClose' { $script:settingsOpen = $false }
        'hide' {
            if ($script:state -eq 'recording') { Stop-Rec; Start-Text }
            $form.Hide()
        }
        'openFolder' { try { Start-Process explorer.exe -ArgumentList "`"$appDir`"" } catch { } }
        'quit' { Exit-App }
        'dragBegin' { $script:dragStart = $form.Location }
        'dragMove' {
            if ($script:dragStart) {
                $nx = [int]($script:dragStart.X + $m.dx * $script:scale)
                $ny = [int]($script:dragStart.Y + $m.dy * $script:scale)
                $form.Location = New-Object System.Drawing.Point($nx, $ny)
            }
        }
        'dragEnd' { $script:dragStart = $null }
        'log' { Write-Log "JS: $($m.text)" }
    }
}

# ---------------------------------------------------------------------------
# инициализация WebView2
# ---------------------------------------------------------------------------
$wv.add_CoreWebView2InitializationCompleted({
    param($sender, $e)
    try {
        if (-not $e.IsSuccess) {
            Write-Log "WebView2 не инициализировался: $($e.InitializationException)"
            [void][System.Windows.Forms.MessageBox]::Show("Не удалось запустить встроенный браузер WebView2.`nУстановите компонент «Microsoft Edge WebView2 Runtime».`n`n$($e.InitializationException)", $appName)
            return
        }
        $core = $sender.CoreWebView2
        $script:core = $core
        try {
            $core.SetVirtualHostNameToFolderMapping('app.local', $webDir, [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
        } catch { Write-Log "не удалось привязать папку web: $($_.Exception.Message)" }

        try {
            $core.Settings.AreDefaultContextMenusEnabled = $false
            $core.Settings.AreDevToolsEnabled = $false
            $core.Settings.IsStatusBarEnabled = $false
            $core.Settings.AreBrowserAcceleratorKeysEnabled = $false
            $core.Settings.IsZoomControlEnabled = $false
            $core.Settings.IsSwipeNavigationEnabled = $false
            $core.Settings.IsGeneralAutofillEnabled = $false
        } catch { }

        $core.add_WebMessageReceived({ param($s2, $e2) try { Handle-Message $e2.WebMessageAsJson } catch { Write-Log "ОШИБКА обработки сообщения: $($_.Exception.Message)" } })
        $core.add_NavigationCompleted({ param($s3, $e3) Write-Log "навигация: $($e3.IsSuccess) $($s3.Source)" })
        $core.Navigate('https://app.local/index.html')
        Write-Log 'WebView2 запущен'
    } catch {
        Write-Log "ОШИБКА инициализации WebView2: $($_.Exception.Message)"
    }
})

try { [void]$wv.EnsureCoreWebView2Async() } catch { Write-Log "ОШИБКА запуска WebView2: $($_.Exception.Message)" }

# ---------------------------------------------------------------------------
# таймер
# ---------------------------------------------------------------------------
$script:lastStateSent = [datetime]::MinValue

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 70
$timer.add_Tick({
    try {
        if ($script:state -eq 'recording') {
            $db = [PcmRecorder]::LastDb
            if ($db -gt $script:vadThr) { $script:speechMs += 70; $script:silentMs = 0 }
            else { $script:silentMs += 70 }
            if ($script:speechMs -ge 280 -and $script:silentMs -ge $script:silenceLimit) { $script:autoStop = $true }
            if (((Get-Date) - $script:lastStateSent).TotalMilliseconds -ge 90) {
                $script:lastStateSent = Get-Date
                Send-State
            }
        }
        if ($script:autoStop) {
            $script:autoStop = $false
            Write-Log "автостоп по тишине (речь $($script:speechMs) мс, тишина $($script:silentMs) мс)"
            Stop-Rec
            Start-Text
        }
        if ($script:state -eq 'recognizing' -and $script:wproc) {
            if ($script:wproc.HasExited) {
                Finish-Text
            } elseif ($script:wstart -and ((Get-Date) - $script:wstart).TotalSeconds -gt 900) {
                try { $script:wproc.Kill() } catch { }
                Write-Log 'распознавание прервано по таймауту'
                Finish-Text
            }
        }
        Update-Target
    } catch {
        Write-Log "ОШИБКА таймера: $($_.Exception.Message)"
    }
})
$timer.Start()

# ---------------------------------------------------------------------------
# выход, трей, горячая клавиша
# ---------------------------------------------------------------------------
function Exit-App {
    try { if ($script:proc) { Stop-Rec } } catch { }
    try { $timer.Stop() } catch { }
    try { $tray.Visible = $false; $tray.Dispose() } catch { }
    Write-Log 'выход'
    try { $wv.Dispose() } catch { }
    try { $form.Close() } catch { }
    [System.Windows.Forms.Application]::Exit()
}

$tray = New-Object System.Windows.Forms.NotifyIcon
try { $tray.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon('C:\Windows\System32\SndVol.exe') } catch { }
if (-not $tray.Icon) { $tray.Icon = [System.Drawing.SystemIcons]::Application }
$tray.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$tOpen = $trayMenu.Items.Add('')
$tSettings = $trayMenu.Items.Add('')
$tAuto = $trayMenu.Items.Add('')
$tAuto.CheckOnClick = $true
$tAuto.Checked = [bool]$script:autoPaste
$trayMenu.Items.Add('-') | Out-Null
$tExit = $trayMenu.Items.Add('')
$tray.ContextMenuStrip = $trayMenu

$tOpen.add_Click({ Show-Bar })
$tSettings.add_Click({ Show-SettingsFromTray })
$tAuto.add_Click({
    $script:autoPaste = [bool]$tAuto.Checked
    Save-Cfg
    Send-Json @{ t = 'settings'; values = @{ autoPaste = $script:autoPaste } }
    Write-Log "автозамена выделенного: $($script:autoPaste)"
})
$tExit.add_Click({ Exit-App })
$tray.add_DoubleClick({ Show-Bar })
$tray.add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Bar } })

$form.add_HotkeyPressed({
    try { Invoke-Toggle } catch { Write-Log "ОШИБКА хоткея: $($_.Exception.Message)" }
})

Apply-MenuText
$form.Show()
try { $form.Activate() } catch { }
Write-Log ("окно: {0}x{1} в {2},{3}, видимо: {4}" -f $form.Width, $form.Height, $form.Left, $form.Top, $form.Visible)

Write-Log "источник записи: $(if ($script:micId) { Get-DevName $script:micId } else { 'не найден' })"
if ($script:excluded.Count -gt 0) {
    Write-Log "исключены системные/виртуальные источники: $($script:excluded -join '; ')"
}
Write-Log "Win+Ё зарегистрирована: $($form.HotkeyOk)"
if (-not $form.HotkeyOk) { Write-Log 'ВНИМАНИЕ: сочетание Win+Ё занято' }
Write-Log "DPI-масштаб: $($script:scale)"

[System.Windows.Forms.Application]::Run()
