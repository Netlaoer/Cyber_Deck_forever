@echo off
chcp 65001 >nul
cd /d "%~dp0.."

set "PYEXE="
set "PYARG="

rem try every python.exe on PATH, skipping the broken Microsoft Store stub
for /f "delims=" %%i in ('where python 2^>nul') do (
    if not defined PYEXE (
        "%%i" -c "import sys" >nul 2>&1 && set "PYEXE=%%i"
    )
)

rem fallback to the py launcher
if not defined PYEXE (
    py -3 -c "import sys" >nul 2>&1 && set "PYEXE=py.exe" && set "PYARG=-3"
)

if not defined PYEXE (
    echo [ERROR] Python not found. Install Python 3.10+ and add it to PATH.
    pause
    exit /b 1
)

echo [INFO] Python: %PYEXE% %PYARG%
"%PYEXE%" %PYARG% pack\打包exe.py %*
if errorlevel 1 pause
