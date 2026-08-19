@echo off
setlocal
set "ROOT=%~dp0"
title Qwen Local Launcher - Setup

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\configure-llama.ps1"
set "SETUP_EXIT=%ERRORLEVEL%"
if not "%SETUP_EXIT%"=="0" (
    echo.
    if "%SETUP_EXIT%"=="2" (echo Setup cancelled.) else (echo Qwen Local Launcher setup failed with exit code %SETUP_EXIT%. & pause)
    exit /b %SETUP_EXIT%
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\build-launcher.ps1"
if errorlevel 1 (
    echo.
    echo Could not create the Windows launcher executable or shortcuts.
    pause
    exit /b 1
)

start "" "%ROOT%dist\Qwen Local Launcher.exe"
exit /b 0
