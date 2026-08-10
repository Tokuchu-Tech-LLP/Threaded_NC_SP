@echo off
setlocal enabledelayedexpansion

REM -------------------------------------------------
REM Detect Application Root and Name
REM -------------------------------------------------
set ROOT_DIR=%cd%
for %%I in ("%ROOT_DIR%") do set APP_NAME=%%~nxI

REM -------------------------------------------------
REM Create Releases folder
REM -------------------------------------------------
set DEST_DIR=%ROOT_DIR%\Releases
if not exist "%DEST_DIR%" mkdir "%DEST_DIR%"

echo.
echo Application : %APP_NAME%
echo.

REM =================================================
REM LOOP THROUGH ALL SUBFOLDERS
REM =================================================
for /d %%D in (*) do (

    set FOLDER=%%D
    set FOLDER_PATH=%ROOT_DIR%\%%D

    set ZIP_SRC=!FOLDER_PATH!\dfu_application.zip
    set HEX_SRC=!FOLDER_PATH!\merged.hex

    echo ----------------------------------------
    echo Checking folder: !FOLDER!
    echo ----------------------------------------

    REM ==============================
    REM ZIP Handling
    REM ==============================
    if exist "!ZIP_SRC!" (

        call :get_ts "!ZIP_SRC!"
        set DEST=!DEST_DIR!\%APP_NAME%-!FOLDER!-dfu-!TS!.zip

        copy "!ZIP_SRC!" "!DEST!" >nul
        echo Stored ZIP:
        echo !DEST!
    ) else (
        echo ZIP not found in !FOLDER!
    )

    REM ==============================
    REM HEX Handling
    REM ==============================
    if exist "!HEX_SRC!" (

        call :get_ts "!HEX_SRC!"
        set DEST=!DEST_DIR!\%APP_NAME%-!FOLDER!-merged-!TS!.hex

        copy "!HEX_SRC!" "!DEST!" >nul
        echo Stored HEX:
        echo !DEST!
    ) else (
        echo HEX not found in !FOLDER!
    )

    echo.
)

echo ========================================
echo All release files stored in:
echo %DEST_DIR%
echo ========================================

pause
exit /b


REM =================================================
REM FUNCTION: Extract timestamp from file
REM =================================================
:get_ts

set FILE=%~1

for %%F in ("%FILE%") do set FILE_TS=%%~tF

REM Example FILE_TS: 10-03-2026 19:42

for /f "tokens=1-3 delims=/-. " %%a in ("%FILE_TS%") do (
    set DD=%%a
    set MM=%%b
    set YY=%%c
)

for /f "tokens=2 delims= " %%a in ("%FILE_TS%") do set TIMEPART=%%a

for /f "tokens=1-2 delims=: " %%h in ("%TIMEPART%") do (
    set HH=%%h
    set MIN=%%i
)

REM Month conversion
set MMM=Jan
if "!MM!"=="02" set MMM=Feb
if "!MM!"=="03" set MMM=Mar
if "!MM!"=="04" set MMM=Apr
if "!MM!"=="05" set MMM=May
if "!MM!"=="06" set MMM=Jun
if "!MM!"=="07" set MMM=Jul
if "!MM!"=="08" set MMM=Aug
if "!MM!"=="09" set MMM=Sep
if "!MM!"=="10" set MMM=Oct
if "!MM!"=="11" set MMM=Nov
if "!MM!"=="12" set MMM=Dec

set TS=!DD!-!MMM!-!YY!-!HH!-!MIN!

exit /b