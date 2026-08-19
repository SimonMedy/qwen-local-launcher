@echo off
setlocal
set "ROOT=%~dp0"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%scripts\configure-llama.ps1"
set "SETUP_EXIT=%ERRORLEVEL%"

if not "%SETUP_EXIT%"=="0" (
    echo.
    if "%SETUP_EXIT%"=="2" (
        echo Setup cancelled.
    ) else (
        echo Qwen Local Launcher setup failed with exit code %SETUP_EXIT%.
        echo The error should also be shown in a dialog above.
        echo.
        pause
    )
    exit /b %SETUP_EXIT%
)

wscript.exe "%ROOT%scripts\launch-hidden.vbs"
