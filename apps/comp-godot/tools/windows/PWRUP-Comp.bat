@echo off
rem PWRUP Comp Dashboard launcher for the driver station.
rem Starts PWRUP-Comp.exe in kiosk mode and restarts it whenever it exits with
rem an error (a crash or a GPU driver reset). A normal quit ends the loop.
rem Arguments are passed to the dashboard, e.g.  PWRUP-Comp.bat --nt-host=10.47.65.2
rem PWRUP_ENGINE_ARGS adds engine arguments, e.g. --rendering-driver vulkan.
rem After 3 crashes within 30 s of starting, the rest of the session uses Vulkan
rem instead of Direct3D 12; after 3 more, the Compatibility renderer (OpenGL ES
rem through ANGLE on Direct3D 11), the emergency fallback.
setlocal EnableExtensions EnableDelayedExpansion
cd /d "%~dp0"
set "EXE=%~dp0PWRUP-Comp.exe"
set "LOGDIR=%APPDATA%\PWRUP\CompDashboard"
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set "LOG=%LOGDIR%\launcher.log"
set "ENGINE_ARGS=%PWRUP_ENGINE_ARGS%"
set FAST_CRASHES=0
if not exist "%EXE%" (
  echo PWRUP-Comp.exe not found next to this launcher.
  pause
  exit /b 1
)

:loop
call :now START_S
>>"%LOG%" echo [%DATE% %TIME%] start: PWRUP-Comp.exe !ENGINE_ARGS! -- --kiosk %*
"%EXE%" !ENGINE_ARGS! -- --kiosk %*
set CODE=!ERRORLEVEL!
if "!CODE!"=="0" goto :done
call :now END_S
set /a RAN=END_S-START_S
if !RAN! lss 0 set /a RAN+=86400
>>"%LOG%" echo [%DATE% %TIME%] exit code !CODE! after !RAN! s, restarting
if !RAN! lss 30 (set /a FAST_CRASHES+=1) else (set FAST_CRASHES=0)
if !FAST_CRASHES! geq 3 call :fallback
timeout /t 2 /nobreak >nul
goto :loop

:done
>>"%LOG%" echo [%DATE% %TIME%] clean exit
endlocal
exit /b 0

rem Next renderer after 3 fast crashes; a PWRUP_ENGINE_ARGS choice is kept.
:fallback
set FAST_CRASHES=0
if "!ENGINE_ARGS!"=="" (
  set "ENGINE_ARGS=--rendering-driver vulkan"
  >>"%LOG%" echo [%DATE% %TIME%] 3 fast crashes in a row: switching to Vulkan
  exit /b 0
)
if "!ENGINE_ARGS!"=="--rendering-driver vulkan" (
  set "ENGINE_ARGS=--rendering-method gl_compatibility --rendering-driver opengl3_angle"
  >>"%LOG%" echo [%DATE% %TIME%] 3 more fast crashes: switching to the Compatibility renderer
)
exit /b 0

rem Seconds since midnight from %TIME% (H:MM:SS.cc; the hour may have a leading
rem space, and the 1xx-100 trick avoids octal parsing of 08 and 09).
:now
set "T=%TIME: =0%"
for /f "tokens=1-3 delims=:.," %%a in ("%T%") do set /a "%1=(1%%a-100)*3600+(1%%b-100)*60+(1%%c-100)"
exit /b 0
