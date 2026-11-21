$ErrorActionPreference = 'Stop'

$appDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$target = Join-Path $appDir 'Max Skitch.cmd'

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "Не найден файл запуска: $target"
    Write-Host 'Положите Create-Shortcut.ps1 в папку программы.'
    exit 1
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnk = Join-Path $desktop 'Max Skitch.lnk'

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($lnk)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $appDir
$shortcut.Description = 'Max Skitch - голосовой ввод (Win+Ё)'
try { $shortcut.IconLocation = 'C:\Windows\System32\SndVol.exe,0' } catch { }
$shortcut.Save()

Write-Host "Ярлык создан: $lnk"
Write-Host "Он указывает на: $target"
