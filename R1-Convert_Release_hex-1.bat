@echo off
setlocal enabledelayedexpansion

REM ==============================================================================
REM TokuchuTech Fleet Firmware Release Automation Script (Windows)
REM Project: Threaded_NC_SP
REM ==============================================================================

echo ==================================================
echo       TokuchuTech Firmware Release Manager        
echo ==================================================

REM ------------------------------------------------------------------------------
REM 1. Git Safety Checks
REM ------------------------------------------------------------------------------
git rev-parse --is-inside-work-tree >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Not inside a valid Git repository.
    echo Release aborted.
    pause
    exit /b 1
)

git remote get-url origin >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Git remote 'origin' not found.
    echo Release aborted.
    pause
    exit /b 1
)

set "VERSION_FILE=src\app_version.h"
if not exist "%VERSION_FILE%" (
    echo ERROR: Version definition file '%VERSION_FILE%' not found.
    echo Release aborted.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 2. Parse Current Version from app_version.h
REM ------------------------------------------------------------------------------
set "CURRENT_VER="
for /f "tokens=3" %%A in ('findstr /r /c:"#define  *APP_VERSION_STR" "%VERSION_FILE%"') do (
    set "CURRENT_VER=%%~A"
)

if "%CURRENT_VER%"=="" (
    echo ERROR: Could not find APP_VERSION_STR in '%VERSION_FILE%'.
    echo Release aborted.
    pause
    exit /b 1
)

REM Strict Major.Patch validation
set "PART1="
set "PART2="
set "EXTRA_PART="
for /f "tokens=1,2,3 delims=." %%A in ("%CURRENT_VER%") do (
    set "PART1=%%A"
    set "PART2=%%B"
    set "EXTRA_PART=%%C"
)

if not "%EXTRA_PART%"=="" set "CURRENT_VER_INVALID=1"
if "%PART1%"=="" set "CURRENT_VER_INVALID=1"
if "%PART2%"=="" set "CURRENT_VER_INVALID=1"

if defined CURRENT_VER_INVALID (
    echo ERROR: Current version '%CURRENT_VER%' does not follow Major.Patch format (e.g. 1.2).
    echo Release aborted.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 3. Calculate Suggested Next Version (Major.(Patch + 1))
REM ------------------------------------------------------------------------------
set "MAJOR=%PART1%"
set "PATCH=%PART2%"
set /a NEXT_PATCH=PATCH+1
set "SUGGESTED_VER=%MAJOR%.%NEXT_PATCH%"

echo Current version:        %CURRENT_VER%
echo Suggested next version: %SUGGESTED_VER%
echo.

REM ------------------------------------------------------------------------------
REM 4. Prompt Developer for Release Version (Default is Current Version)
REM ------------------------------------------------------------------------------
set "USER_INPUT="
set /p "USER_INPUT=Enter release version [%CURRENT_VER%]: "
if "%USER_INPUT%"=="" set "USER_INPUT=%CURRENT_VER%"
set "RELEASE_VER=%USER_INPUT%"

REM Validate chosen version format
set "VAL_P1="
set "VAL_P2="
set "VAL_EXTRA="
for /f "tokens=1,2,3 delims=." %%A in ("%RELEASE_VER%") do (
    set "VAL_P1=%%A"
    set "VAL_P2=%%B"
    set "VAL_EXTRA=%%C"
)

if not "%VAL_EXTRA%"=="" set "CHOSEN_VER_INVALID=1"
if "%VAL_P1%"=="" set "CHOSEN_VER_INVALID=1"
if "%VAL_P2%"=="" set "CHOSEN_VER_INVALID=1"

if defined CHOSEN_VER_INVALID (
    echo ERROR: Chosen release version '%RELEASE_VER%' is invalid. Must be Major.Patch (e.g. 1.2).
    echo Release aborted.
    pause
    exit /b 1
)

REM If user specified a different version than in app_version.h, update app_version.h
if not "%RELEASE_VER%"=="%CURRENT_VER%" (
    (
        echo #ifndef APP_VERSION_H
        echo #define APP_VERSION_H
        echo.
        echo #define APP_VERSION_MAJOR !VAL_P1!
        echo #define APP_VERSION_PATCH !VAL_P2!
        echo #define APP_VERSION_STR   "!RELEASE_VER!"
        echo.
        echo #endif /* APP_VERSION_H */
    ) > "%VERSION_FILE%"
    echo NOTE: Updated '%VERSION_FILE%' to version !RELEASE_VER!.
    echo WARNING: Ensure the compiled firmware artifacts correspond to this version.
)

REM ------------------------------------------------------------------------------
REM 5. Check if Target Git Tag Already Exists
REM ------------------------------------------------------------------------------
set "TAG_NAME=stable-release-%RELEASE_VER%"

git rev-parse -q --verify "refs/tags/%TAG_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo ERROR: Local Git tag '%TAG_NAME%' already exists.
    echo Overwriting existing release tags is strictly prohibited.
    echo Release aborted.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 6. Locate Build Artifacts (merged.hex & dfu_application.zip)
REM ------------------------------------------------------------------------------
set "HEX_SRC="
set "ZIP_SRC="

if exist "SPNC_FOTA\merged.hex" if exist "SPNC_FOTA\dfu_application.zip" (
    set "HEX_SRC=SPNC_FOTA\merged.hex"
    set "ZIP_SRC=SPNC_FOTA\dfu_application.zip"
    echo Found release artifacts in directory: SPNC_FOTA\
)

if "!HEX_SRC!"=="" if exist "build\merged.hex" if exist "build\dfu_application.zip" (
    set "HEX_SRC=build\merged.hex"
    set "ZIP_SRC=build\dfu_application.zip"
    echo Found release artifacts in directory: build\
)

if "!HEX_SRC!"=="" if exist "build\zephyr\merged.hex" if exist "build\zephyr\dfu_application.zip" (
    set "HEX_SRC=build\zephyr\merged.hex"
    set "ZIP_SRC=build\zephyr\dfu_application.zip"
    echo Found release artifacts in directory: build\zephyr\
)

if "!HEX_SRC!"=="" (
    for /d %%D in (*) do (
        if not "%%D"=="Releases" if not "%%D"=="src" if not "%%D"=="boards" if not "%%D"=="docs" (
            if exist "%%D\merged.hex" if exist "%%D\dfu_application.zip" (
                set "HEX_SRC=%%D\merged.hex"
                set "ZIP_SRC=%%D\dfu_application.zip"
                echo Found release artifacts in directory: %%D\
            )
        )
    )
)

if "!HEX_SRC!"=="" (
    echo ERROR: Required release artifacts not found.
    echo Looked for 'merged.hex' and 'dfu_application.zip'.
    echo Please build the firmware before running the release script.
    echo Release aborted.
    pause
    exit /b 1
)

echo Artifacts to package:
echo   HEX: !HEX_SRC!
echo   ZIP: !ZIP_SRC!

REM ------------------------------------------------------------------------------
REM 7. Create Release Directory & Copy Artifacts
REM ------------------------------------------------------------------------------
set "TS="
for /f %%A in ('powershell -NoProfile -Command "Get-Date -Format 'dd-MMM-yyyy-HH-mm'" 2^>nul') do set "TS=%%A"
if "%TS%"=="" call :get_fallback_ts

set "RELEASE_DIR=Releases\v%RELEASE_VER%_%TS%"
if not exist "%RELEASE_DIR%" mkdir "%RELEASE_DIR%"

echo Creating release directory: %RELEASE_DIR%\
copy /b "!HEX_SRC!" "%RELEASE_DIR%\merged.hex" >nul
copy /b "!ZIP_SRC!" "%RELEASE_DIR%\dfu_application.zip" >nul

if not exist "%RELEASE_DIR%\merged.hex" (
    echo ERROR: Failed to copy merged.hex into '%RELEASE_DIR%'.
    echo Release aborted.
    pause
    exit /b 1
)
if not exist "%RELEASE_DIR%\dfu_application.zip" (
    echo ERROR: Failed to copy dfu_application.zip into '%RELEASE_DIR%'.
    echo Release aborted.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 8. Git Staging, Commit & Release Tag
REM ------------------------------------------------------------------------------
echo Staging release files in Git...
git add "%VERSION_FILE%"
git add .gitignore
git add R1-Convert_Release_hex-1.sh
git add R1-Convert_Release_hex-1.bat
git add -f "%RELEASE_DIR%\merged.hex"
git add -f "%RELEASE_DIR%\dfu_application.zip"

echo Creating release commit...
git commit -m "release: version %RELEASE_VER%"
if %errorlevel% neq 0 (
    echo ERROR: Git commit failed.
    pause
    exit /b 1
)

echo Creating annotated Git tag: %TAG_NAME%...
git tag -a "%TAG_NAME%" -m "Release %TAG_NAME%"
if %errorlevel% neq 0 (
    echo ERROR: Failed to create Git tag '%TAG_NAME%'.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 9. Push to GitHub Remote
REM ------------------------------------------------------------------------------
echo Pushing release commit and tag to GitHub (origin)...
for /f "tokens=*" %%B in ('git rev-parse --abbrev-ref HEAD') do set "CURRENT_BRANCH=%%B"

git push origin %CURRENT_BRANCH%
if %errorlevel% neq 0 (
    echo ERROR: Failed to push commit to origin/%CURRENT_BRANCH%.
    echo Release tag not pushed.
    pause
    exit /b 1
)

git push origin "%TAG_NAME%"
if %errorlevel% neq 0 (
    echo ERROR: Failed to push tag '%TAG_NAME%' to origin.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 10. Success Summary (app_version.h is NOT modified after release)
REM ------------------------------------------------------------------------------
echo.
echo ==================================================
echo  Release %TAG_NAME% Completed Successfully!
echo ==================================================
echo Firmware Version:   %RELEASE_VER%
echo Release Directory:  %RELEASE_DIR%\
echo Release Artifacts:  merged.hex, dfu_application.zip
echo Git Tag:            %TAG_NAME%
echo Remote Push:        origin/%CURRENT_BRANCH% + %TAG_NAME%
echo ==================================================

pause
exit /b 0

REM ==============================================================================
REM Subroutine: Fallback Timestamp Generator
REM ==============================================================================
:get_fallback_ts
for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value 2^>nul') do set "LDT=%%I"
if not "%LDT%"=="" (
    set "YY=!LDT:~0,4!"
    set "MM=!LDT:~4,2!"
    set "DD=!LDT:~6,2!"
    set "HH=!LDT:~8,2!"
    set "MIN=!LDT:~10,2!"
    set "MMM=Jan"
    if "!MM!"=="02" set "MMM=Feb"
    if "!MM!"=="03" set "MMM=Mar"
    if "!MM!"=="04" set "MMM=Apr"
    if "!MM!"=="05" set "MMM=May"
    if "!MM!"=="06" set "MMM=Jun"
    if "!MM!"=="07" set "MMM=Jul"
    if "!MM!"=="08" set "MMM=Aug"
    if "!MM!"=="09" set "MMM=Sep"
    if "!MM!"=="10" set "MMM=Oct"
    if "!MM!"=="11" set "MMM=Nov"
    if "!MM!"=="12" set "MMM=Dec"
    set "TS=!DD!-!MMM!-!YY!-!HH!-!MIN!"
    exit /b 0
)
set "TS=%DATE%-%TIME:~0,2%-%TIME:~3,2%"
set "TS=%TS: =0%"
set "TS=%TS:/=-%"
exit /b 0