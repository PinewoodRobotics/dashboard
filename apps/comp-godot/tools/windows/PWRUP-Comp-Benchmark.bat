@echo off
rem PWRUP Comp Dashboard benchmark for the driver-station checklist. Close the
rem dashboard first. Runs the built-in benchmark (both windows on their
rem displays, an auto preview playing with the HUD mirroring it, frame rate per
rem render scale) once with Direct3D 12 and once with Vulkan, about 40 s each,
rem then opens both result files from %APPDATA%\PWRUP\CompDashboard.
setlocal
cd /d "%~dp0"
set "OUT=%APPDATA%\PWRUP\CompDashboard"
"%~dp0PWRUP-Comp.exe" --rendering-driver d3d12 -- --benchmark --benchmark-name=d3d12 --kiosk
"%~dp0PWRUP-Comp.exe" --rendering-driver vulkan -- --benchmark --benchmark-name=vulkan --kiosk
start "" notepad "%OUT%\benchmark_d3d12.txt"
start "" notepad "%OUT%\benchmark_vulkan.txt"
endlocal
