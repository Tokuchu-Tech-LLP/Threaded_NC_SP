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
REM 3. Determine Release Version & Calculate Next Version
REM ------------------------------------------------------------------------------
set "RELEASE_VER=%CURRENT_VER%"
set "MAJOR=%PART1%"
set "PATCH=%PART2%"
set /a NEXT_PATCH=PATCH+1
set "NEXT_VER=%MAJOR%.%NEXT_PATCH%"

echo Releasing firmware version: %RELEASE_VER%
echo Next development version:   %NEXT_VER% (will be set after release completes)
echo.

REM ------------------------------------------------------------------------------
REM 5. Check if Target Git Tag Already Exists
REM ------------------------------------------------------------------------------
set "TAG_NAME=stable-release-%RELEASE_VER%"

git rev-parse -q --verify "refs/tags/%TAG_NAME%" >nul 2>&1
if %errorlevel% equ 0 (
    echo ERROR: Local Git tag '%TAG_NAME%' already exists.
    echo If a previous release partially succeeded or network dropped during confirmation, check:
    echo   git ls-remote --tags origin refs/tags/%TAG_NAME%
    echo To proceed with a new release cycle, advance '%VERSION_FILE%' to %NEXT_VER%.
    echo Overwriting existing release tags is strictly prohibited.
    echo Release aborted.
    pause
    exit /b 1
)

git ls-remote --tags origin "refs/tags/%TAG_NAME%" 2>nul | findstr /c:"%TAG_NAME%" >nul
if %errorlevel% equ 0 (
    echo ERROR: Remote Git tag '%TAG_NAME%' already exists on origin.
    echo If the release already reached GitHub, advance '%VERSION_FILE%' to %NEXT_VER% for the next cycle.
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

for %%F in ("!HEX_SRC!") do (
    if %%~zF equ 0 (
        echo ERROR: Artifact '!HEX_SRC!' is empty (0 bytes).
        echo Release aborted.
        pause
        exit /b 1
    )
)
for %%F in ("!ZIP_SRC!") do (
    if %%~zF equ 0 (
        echo ERROR: Artifact '!ZIP_SRC!' is empty (0 bytes).
        echo Release aborted.
        pause
        exit /b 1
    )
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
if not exist "%RELEASE_DIR%" (
    mkdir "%RELEASE_DIR%"
    if %errorlevel% neq 0 (
        echo ERROR: Failed to create release directory '%RELEASE_DIR%'.
        echo Release aborted.
        pause
        exit /b 1
    )
)

echo Creating release directory: %RELEASE_DIR%\
copy /b "!HEX_SRC!" "%RELEASE_DIR%\merged.hex" >nul
if %errorlevel% neq 0 (
    echo ERROR: Failed to copy merged.hex into '%RELEASE_DIR%'.
    echo Release aborted.
    pause
    exit /b 1
)

copy /b "!ZIP_SRC!" "%RELEASE_DIR%\dfu_application.zip" >nul
if %errorlevel% neq 0 (
    echo ERROR: Failed to copy dfu_application.zip into '%RELEASE_DIR%'.
    echo Release aborted.
    pause
    exit /b 1
)

if not exist "%RELEASE_DIR%\merged.hex" (
    echo ERROR: Target artifact '%RELEASE_DIR%\merged.hex' not found after copy.
    echo Release aborted.
    pause
    exit /b 1
)
if not exist "%RELEASE_DIR%\dfu_application.zip" (
    echo ERROR: Target artifact '%RELEASE_DIR%\dfu_application.zip' not found after copy.
    echo Release aborted.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 8. Git Staging, Commit & Release Tag
REM ------------------------------------------------------------------------------
echo Staging release files in Git...
git add "%VERSION_FILE%"
if %errorlevel% neq 0 goto :git_add_failed

git add .gitignore
if %errorlevel% neq 0 goto :git_add_failed

git add R1-Convert_Release_hex-1.sh
if %errorlevel% neq 0 goto :git_add_failed

git add R1-Convert_Release_hex-1.bat
if %errorlevel% neq 0 goto :git_add_failed

git add -f "%RELEASE_DIR%\merged.hex"
if %errorlevel% neq 0 goto :git_add_failed

git add -f "%RELEASE_DIR%\dfu_application.zip"
if %errorlevel% neq 0 goto :git_add_failed

git ls-files --error-unmatch "%VERSION_FILE%" >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: '%VERSION_FILE%' is not tracked or staged.
    pause
    exit /b 1
)

set "GIT_RELEASE_DIR=%RELEASE_DIR:\=/%"
git diff --cached --name-only | findstr /x /c:"!GIT_RELEASE_DIR!/merged.hex" >nul
if %errorlevel% neq 0 (
    echo ERROR: '!GIT_RELEASE_DIR!/merged.hex' is not staged.
    pause
    exit /b 1
)
git diff --cached --name-only | findstr /x /c:"!GIT_RELEASE_DIR!/dfu_application.zip" >nul
if %errorlevel% neq 0 (
    echo ERROR: '!GIT_RELEASE_DIR!/dfu_application.zip' is not staged.
    pause
    exit /b 1
)

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
REM 9. Verify Tag Integrity (git ls-tree -r with Exact Path Matching)
REM ------------------------------------------------------------------------------
echo Verifying release tag integrity (git ls-tree -r refs/tags/%TAG_NAME%)...

set "TAG_COMMIT="
for /f "tokens=*" %%C in ('git rev-list -n 1 "%TAG_NAME%" 2^>nul') do set "TAG_COMMIT=%%C"
if "!TAG_COMMIT!"=="" (
    echo INTEGRITY ERROR: Tag '%TAG_NAME%' could not be resolved to a commit SHA.
    pause
    exit /b 1
)

git cat-file -e "!TAG_COMMIT!^{commit}" 2>nul
if %errorlevel% neq 0 (
    echo INTEGRITY ERROR: Resolved SHA '!TAG_COMMIT!' for tag '%TAG_NAME%' is not a valid commit object.
    pause
    exit /b 1
)

set "GIT_VERSION_FILE=%VERSION_FILE:\=/%"
set "EXPECTED_HEX=!GIT_RELEASE_DIR!/merged.hex"
set "EXPECTED_ZIP=!GIT_RELEASE_DIR!/dfu_application.zip"

git ls-tree -r --name-only "!TAG_COMMIT!" -- "%GIT_VERSION_FILE%" | findstr /x /c:"%GIT_VERSION_FILE%" >nul
if %errorlevel% neq 0 (
    echo INTEGRITY ERROR: Exact file path '%GIT_VERSION_FILE%' is missing from release tag commit (!TAG_COMMIT!).
    pause
    exit /b 1
)

git ls-tree -r --name-only "!TAG_COMMIT!" -- "!EXPECTED_HEX!" | findstr /x /c:"!EXPECTED_HEX!" >nul
if %errorlevel% neq 0 (
    echo INTEGRITY ERROR: Exact artifact path '!EXPECTED_HEX!' is missing from release tag commit (!TAG_COMMIT!).
    pause
    exit /b 1
)

git ls-tree -r --name-only "!TAG_COMMIT!" -- "!EXPECTED_ZIP!" | findstr /x /c:"!EXPECTED_ZIP!" >nul
if %errorlevel% neq 0 (
    echo INTEGRITY ERROR: Exact artifact path '!EXPECTED_ZIP!' is missing from release tag commit (!TAG_COMMIT!).
    pause
    exit /b 1
)

echo Release tag integrity verified: exact source + firmware artifacts confirmed.

REM ------------------------------------------------------------------------------
REM 10. Push to GitHub Remote
REM ------------------------------------------------------------------------------
echo Pushing release commit and tag to GitHub (origin)...
for /f "tokens=*" %%B in ('git rev-parse --abbrev-ref HEAD') do set "CURRENT_BRANCH=%%B"

git push origin %CURRENT_BRANCH%
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Failed to push commit to origin/%CURRENT_BRANCH%.
    echo Push status could not be confirmed. Verify the remote branch before retrying:
    echo   git log origin/%CURRENT_BRANCH% -n 1
    echo   git ls-remote --tags origin refs/tags/%TAG_NAME%
    echo Release aborted. '%VERSION_FILE%' was NOT modified and remains at %RELEASE_VER%.
    pause
    exit /b 1
)

git push origin "%TAG_NAME%"
if %errorlevel% neq 0 (
    echo.
    echo ERROR: Failed to push tag '%TAG_NAME%' to origin.
    echo Push status could not be confirmed. Verify the remote tag before retrying:
    echo   git ls-remote --tags origin refs/tags/%TAG_NAME%
    echo Release aborted. '%VERSION_FILE%' was NOT modified and remains at %RELEASE_VER%.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 11. Advance to Next Development Version (Local Only & Verified)
REM ------------------------------------------------------------------------------
echo.
echo Advancing '%VERSION_FILE%' locally to %NEXT_VER% for next development cycle...
(
    echo #ifndef APP_VERSION_H
    echo #define APP_VERSION_H
    echo.
    echo #define APP_VERSION_MAJOR %MAJOR%
    echo #define APP_VERSION_PATCH %NEXT_PATCH%
    echo #define APP_VERSION_STR   "%NEXT_VER%"
    echo.
    echo #endif /* APP_VERSION_H */
) > "%VERSION_FILE%"

if not exist "%VERSION_FILE%" (
    echo ERROR: Failed to write to '%VERSION_FILE%'.
    pause
    exit /b 1
)

for %%F in ("%VERSION_FILE%") do (
    if %%~zF equ 0 (
        echo ERROR: Version definition file '%VERSION_FILE%' is empty after write.
        pause
        exit /b 1
    )
)

set "WRITTEN_VER="
for /f "tokens=3" %%A in ('findstr /r /c:"#define  *APP_VERSION_STR" "%VERSION_FILE%"') do (
    set "WRITTEN_VER=%%~A"
)

if not "!WRITTEN_VER!"=="!NEXT_VER!" (
    echo ERROR: Version verification failed after writing '%VERSION_FILE%'.
    echo Expected: !NEXT_VER!, found: !WRITTEN_VER!
    pause
    exit /b 1
)
echo Verified: '%VERSION_FILE%' successfully set to %NEXT_VER% for next development cycle.

REM ------------------------------------------------------------------------------
REM 12. Success Summary
REM ------------------------------------------------------------------------------
echo.
echo ==================================================
echo  Release %TAG_NAME% Completed Successfully!
echo ==================================================
echo Firmware Released:  %RELEASE_VER%
echo Release Directory:  %RELEASE_DIR%\
echo Release Artifacts:  merged.hex, dfu_application.zip
echo Git Release Tag:    %TAG_NAME%
echo Next Version Set:   %NEXT_VER% in %VERSION_FILE% (local only)
echo ==================================================

pause
exit /b 0

REM ==============================================================================
REM Error Handler: Git Staging Failure
REM ==============================================================================
:git_add_failed
echo ERROR: Failed to stage release files in Git.
echo Release aborted.
pause
exit /b 1

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