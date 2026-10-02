@echo off
rem Runs install.ps1 with the execution policy bypassed for this one run only.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
