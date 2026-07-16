@echo off
setlocal
chcp 65001 >nul
title Codex Dream Skin

set "ROOT=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%app\skin-manager.ps1"

echo.
echo Press any key to close this window.
pause >nul
