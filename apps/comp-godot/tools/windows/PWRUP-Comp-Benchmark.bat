@echo off
rem PWRUP Comp Dashboard benchmark for the driver-station checklist. Close the
rem dashboard first. Runs the built-in benchmark (both windows on their
rem displays, an auto preview playing with the HUD mirroring it, frame rate per
rem render scale) once with the native OpenGL driver and once with ANGLE
rem (Direct3D 11), about 40 s each, then opens both result files from
rem %APPDATA%\PWRUP\CompDashboard.
setlocal
cd /d "%~dp0"
set "OUT=%APPDATA%\PWRUP\CompDashboard"
"%~dp0PWRUP-Comp.exe" -- --benchmark --benchmark-name=native --kiosk
"%~dp0PWRUP-Comp.exe" --rendering-driver opengl3_angle -- --benchmark --benchmark-name=angle --kiosk
start "" notepad "%OUT%\benchmark_native.txt"
start "" notepad "%OUT%\benchmark_angle.txt"
endlocal
