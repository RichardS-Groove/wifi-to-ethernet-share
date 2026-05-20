@echo off
:: ============================================================
::  Sharing Wi-Fi to Ethernet  -  Lanzador Principal
::  Arquitecto: Auto-elevacion + Motor PowerShell
:: ============================================================
title Sharing Wi-Fi to Ethernet

:: ── Comprobacion de privilegios de Administrador ──────────────
net session >nul 2>&1
if %errorLevel% == 0 goto :ELEVATED

:: ── Auto-elevacion sin intervencion del usuario ───────────────
echo  Solicitando privilegios de Administrador...
powershell -NoProfile -Command ^
  "Start-Process -FilePath '%~f0' -Verb RunAs -WindowStyle Normal"
exit /b

:ELEVATED
:: ── Pasar el control al motor PowerShell ─────────────────────
powershell.exe -NoProfile -ExecutionPolicy Bypass ^
  -File "%~dp0Engine_ICS.ps1"

:: Si PowerShell falla, mostramos el error y esperamos
if %errorLevel% neq 0 (
    echo.
    echo  [ERROR] El motor PowerShell termino con codigo %errorLevel%.
    echo  Revisa Engine_ICS.ps1 y asegurate de tenerlo en la misma carpeta.
    pause
)
exit /b
