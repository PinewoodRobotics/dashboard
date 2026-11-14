@echo off
rem PWRUP Comp Dashboard, plan B from the driver-station checklist: the HUD and
rem the touchscreen as two processes, each in its own restart loop
rem (PWRUP-Comp.bat), for laptops where touch input does not reach the second
rem window of one process. Only the touchscreen process publishes robot
rem requests. Arguments are passed to both, e.g.
rem   PWRUP-Comp-TwoProcess.bat --nt-host=10.47.65.2
setlocal
cd /d "%~dp0"
start "PWRUP HUD" /min cmd /c ""%~dp0PWRUP-Comp.bat" --screen=hud %*"
start "PWRUP Touch" /min cmd /c ""%~dp0PWRUP-Comp.bat" --screen=touch %*"
endlocal
