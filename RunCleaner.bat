@echo off
rem ============================================================
rem  DiskCleaner launcher - requests admin rights automatically
rem ============================================================
setlocal
set "PS1=%~dp0DiskCleaner.ps1"

if not exist "%PS1%" (
    echo [ERROR] DiskCleaner.ps1 was not found next to this launcher.
    echo Keep both files in the same folder.
    pause
    exit /b 1
)

rem --- Ensure the script keeps its UTF-8 BOM.
rem     PowerShell 5.1 needs the BOM to read the Chinese text correctly;
rem     some editors silently strip it and the script then fails to parse.
rem     Skipped when the file is not valid UTF-8, to avoid corrupting it. ---
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~dp0DiskCleaner.ps1'; $b=[System.IO.File]::ReadAllBytes($f); if($b.Length -ge 3 -and -not($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)){ $c=[System.IO.File]::ReadAllText($f,[System.Text.Encoding]::UTF8); if($c.IndexOf([char]0xFFFD) -lt 0){ [System.IO.File]::WriteAllText($f,$c,(New-Object System.Text.UTF8Encoding $true)); Write-Host '[launcher] UTF-8 BOM restored' } }"

net session >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
if errorlevel 1 pause
exit /b 0
