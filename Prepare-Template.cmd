@echo off
setlocal
rem Keep this launcher beside Prepare-Template.ps1. No installer is needed.
set "SIMPLEVDI_PREPARE_SCRIPT=%~dp0Prepare-Template.ps1"
if not exist "%SIMPLEVDI_PREPARE_SCRIPT%" (
    echo Prepare-Template.ps1 was not found beside this launcher.
    pause
    exit /b 1
)
rem Pass the path as data, including spaces and non-ASCII characters.
rem The elevated console remains open on failure so the error can be read.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { $q=[char]34; $argsText='-NoProfile -NoExit -ExecutionPolicy Bypass -File '+$q+$env:SIMPLEVDI_PREPARE_SCRIPT+$q; $p=Start-Process -FilePath ($env:SystemRoot+'\System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argsText -Verb RunAs -PassThru -Wait -ErrorAction Stop; exit $p.ExitCode } catch { Write-Host $_.Exception.Message; exit 1 }"
if errorlevel 1 (
    echo Template preparation did not complete successfully.
    pause
    exit /b 1
)
endlocal
