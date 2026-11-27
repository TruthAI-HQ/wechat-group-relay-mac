@echo off
setlocal
cd /d "%~dp0"
set "VENV_PY=.venv\Scripts\python.exe"
set "CHECK_PY=import struct,sys; sys.exit(not (sys.platform == 'win32' and sys.version_info[:2] == (3,12) and struct.calcsize('P') == 8))"

if exist "%VENV_PY%" goto check_venv
py -3.12 -c "%CHECK_PY%" >nul 2>nul
if not errorlevel 1 goto create_with_launcher
python -c "%CHECK_PY%" >nul 2>nul
if errorlevel 1 goto missing_python
python -m venv .venv
if errorlevel 1 goto failed
goto check_venv

:create_with_launcher
py -3.12 -m venv .venv
if errorlevel 1 goto failed

:check_venv
"%VENV_PY%" -c "%CHECK_PY%" >nul 2>nul
if errorlevel 1 goto bad_venv
"%VENV_PY%" -c "import tkinter, uiautomation; from mss import MSS; from rapidocr_onnxruntime import RapidOCR" >nul 2>nul
if not errorlevel 1 goto run
"%VENV_PY%" -m pip install --only-binary=:all: -r requirements.txt
if errorlevel 1 goto failed

:run
"%VENV_PY%" wechat_group_relay.py
if errorlevel 1 goto failed
exit /b 0

:missing_python
echo Install 64-bit Python 3.12 from https://www.python.org/downloads/windows/ and try again.
goto failed

:bad_venv
echo The .venv folder has an incompatible Python. Rename it, then start again.

:failed
echo Windows relay did not finish. Check the message above.
pause
exit /b 1
