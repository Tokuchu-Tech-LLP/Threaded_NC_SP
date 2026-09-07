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
if errorlevel 1 (
    echo ERROR: Not inside a valid Git repository.
    echo Release aborted.
    pause
    exit /b 1
)

git remote get-url origin >nul 2>&1
if errorlevel 1 (
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
if not errorlevel 1 (
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
if not errorlevel 1 (
    echo ERROR: Remote Git tag '%TAG_NAME%' already exists on origin.
    echo If the release already reached GitHub, advance '%VERSION_FILE%' to %NEXT_VER% for the next cycle.
    echo Release aborted.
    pause
    exit /b 1
)

REM ------------------------------------------------------------------------------
REM 6. Locate Build Artifacts & Enforce Freshness (Built Today)
REM ------------------------------------------------------------------------------
for %%I in ("%CD%") do set "REPO_NAME=%%~nxI"

set "TS="
for /f %%A in ('powershell -NoProfile -Command "Get-Date -Format 'dd-MMM-yyyy-HH-mm'" 2^>nul') do set "TS=%%A"
if "%TS%"=="" call :get_fallback_ts

set "TODAY_DATE="
for /f %%A in ('powershell -NoProfile -Command "Get-Date -Format 'yyyy-MM-dd'" 2^>nul') do set "TODAY_DATE=%%A"

echo Scanning for firmware build directories...
echo Release date cutoff: Today (%TODAY_DATE%)
echo.

set "ELIGIBLE_COUNT=0"
set "STALE_COUNT=0"

for /f "tokens=1,2,3,4 delims=|" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$today = (Get-Date).Date; $repo = (Get-Item .).Name; if (!(Test-Path Releases)) { New-Item -ItemType Directory -Path Releases | Out-Null }; $candidates = @('SPNC_FOTA', 'build', 'build\zephyr', 'SPNC_FOTA\zephyr', 'bin', 'out'); $dirs = Get-ChildItem -Directory | Where-Object { $_.Name -notin @('Releases', 'src', 'boards', 'docs', 'Key', 'modules', 'zephyr', 'mcuboot', 'CMakeFiles', '.git', '.vscode', '_sysbuild') } | Select-Object -ExpandProperty Name; $allDirs = ($candidates + $dirs) | Select-Object -Unique; foreach ($d in $allDirs) { $hex = Join-Path $d 'merged.hex'; $zip = Join-Path $d 'dfu_application.zip'; if ((Test-Path $hex) -and (Test-Path $zip)) { $h = Get-Item $hex; $z = Get-Item $zip; if ($h.Length -gt 0 -and $z.Length -gt 0) { $timeStr = $h.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); $tsClean = $h.LastWriteTime.ToString('dd-MMM-yyyy-HH-mm'); if ($h.LastWriteTime.Date -eq $today) { Write-Output ('FRESH|' + $d + '|' + $timeStr) } else { $hHash = (Get-FileHash -Algorithm SHA256 $hex).Hash; $zHash = (Get-FileHash -Algorithm SHA256 $zip).Hash; $existingHashes = @(); if (Test-Path Releases) { $existingHashes = (Get-ChildItem -Recurse -File Releases | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_.FullName).Hash }) }; $savedStatus = 'Already archived in Releases/'; $safeName = $d -replace '[\\/]', '__'; if (($existingHashes -notcontains $hHash) -or ($existingHashes -notcontains $zHash)) { Copy-Item $hex (Join-Path Releases ('archived_' + $safeName + '_' + $tsClean + '_' + $repo + '_merged.hex')); Copy-Item $zip (Join-Path Releases ('archived_' + $safeName + '_' + $tsClean + '_' + $repo + '_dfu.zip')); $savedStatus = 'Archived to Releases/' }; Remove-Item -Recurse -Force $d; Write-Output ('STALE|' + $d + '|' + $timeStr + '|' + $savedStatus) } } } }" 2^>nul') do (
    if "%%A"=="FRESH" (
        set /a ELIGIBLE_COUNT+=1
        set "BUILD_DIR_!ELIGIBLE_COUNT!=%%B"
        set "BUILD_TIME_!ELIGIBLE_COUNT!=%%C"
        echo   [FRESH BUILD] Found '%%B\' (Compiled today at %%C)
    )
    if "%%A"=="STALE" (
        set /a STALE_COUNT+=1
        set "STALE_DIR_!STALE_COUNT!=%%B"
        set "STALE_TIME_!STALE_COUNT!=%%C"
        echo   [OUTDATED / ARCHIVING] '%%B\' (Compiled on %%C - not today)
        echo     -^> %%D
        echo     -^> Removed outdated build directory '%%B\'.
    )
)

echo.

if !ELIGIBLE_COUNT! equ 0 (
    echo ==================================================
    echo Outdated build directory cleanup complete.
    echo No fresh firmware builds compiled today were found.
    echo Today's date: %TODAY_DATE%
    echo ==================================================
    if !STALE_COUNT! gtr 0 (
        echo Processed and removed outdated build directories:
        for /l %%I in (1,1,!STALE_COUNT!) do (
            echo   - !STALE_DIR_%%I!\ (Built: !STALE_TIME_%%I!)
        )
        echo.
    )
    echo Please build the firmware (e.g. via 'west build') and re-run this script to release.
    echo Release aborted.
    pause
    exit /b 1
)

echo Eligible builds to package (!ELIGIBLE_COUNT! build(s)):
for /l %%I in (1,1,!ELIGIBLE_COUNT!) do (
    echo   %%I. !BUILD_DIR_%%I!\
)
echo.

REM ------------------------------------------------------------------------------
REM 7. Create Releases Directory & Package Artifacts
REM ------------------------------------------------------------------------------
set "RELEASE_BASE=Releases"
if not exist "%RELEASE_BASE%" (
    mkdir "%RELEASE_BASE%"
    if errorlevel 1 (
        echo ERROR: Failed to create or access '%RELEASE_BASE%' directory.
        echo Release aborted.
        pause
        exit /b 1
    )
)

echo Packaging release artifacts into '%RELEASE_BASE%\'...

for /l %%I in (1,1,!ELIGIBLE_COUNT!) do (
    set "RAW_DIR=!BUILD_DIR_%%I!"
    set "SAFE_NAME=!RAW_DIR:\=__!"
    set "SAFE_NAME=!SAFE_NAME:/=__!"

    set "TARGET_HEX_NAME=!SAFE_NAME!_v%RELEASE_VER%_%TS%_%REPO_NAME%_merged.hex"
    set "TARGET_ZIP_NAME=!SAFE_NAME!_v%RELEASE_VER%_%TS%_%REPO_NAME%_dfu.zip"

    set "TARGET_HEX_PATH=%RELEASE_BASE%\!TARGET_HEX_NAME!"
    set "TARGET_ZIP_PATH=%RELEASE_BASE%\!TARGET_ZIP_NAME!"

    set "HEX_NAME_%%I=!TARGET_HEX_NAME!"
    set "ZIP_NAME_%%I=!TARGET_ZIP_NAME!"
    set "HEX_PATH_%%I=!TARGET_HEX_PATH!"
    set "ZIP_PATH_%%I=!TARGET_ZIP_PATH!"

    echo Packaging build '!RAW_DIR!\':
    echo   HEX -^> !TARGET_HEX_PATH!
    copy /b "!RAW_DIR!\merged.hex" "!TARGET_HEX_PATH!" >nul
    if errorlevel 1 (
        echo ERROR: Failed to copy '!RAW_DIR!\merged.hex' to '!TARGET_HEX_PATH!'.
        echo Release aborted.
        pause
        exit /b 1
    )

    echo   ZIP -^> !TARGET_ZIP_PATH!
    copy /b "!RAW_DIR!\dfu_application.zip" "!TARGET_ZIP_PATH!" >nul
    if errorlevel 1 (
        echo ERROR: Failed to copy '!RAW_DIR!\dfu_application.zip' to '!TARGET_ZIP_PATH!'.
        echo Release aborted.
        pause
        exit /b 1
    )

    if not exist "!TARGET_HEX_PATH!" (
        echo ERROR: Target artifact '!TARGET_HEX_PATH!' not found after copy.
        echo Release aborted.
        pause
        exit /b 1
    )
    if not exist "!TARGET_ZIP_PATH!" (
        echo ERROR: Target artifact '!TARGET_ZIP_PATH!' not found after copy.
        echo Release aborted.
        pause
        exit /b 1
    )
)

echo.
echo Successfully packaged !ELIGIBLE_COUNT! build(s) into '%RELEASE_BASE%\'.
echo.

REM ------------------------------------------------------------------------------
REM 8. Git Staging, Commit & Release Tag
REM ------------------------------------------------------------------------------
echo Staging release files in Git...
git add "%VERSION_FILE%"
if errorlevel 1 goto :git_add_failed

git add .gitignore
if errorlevel 1 goto :git_add_failed

git add R1-Convert_Release_hex-1.sh
if errorlevel 1 goto :git_add_failed

git add R1-Convert_Release_hex-1.bat
if errorlevel 1 goto :git_add_failed

for /l %%I in (1,1,!ELIGIBLE_COUNT!) do (
    git add -f "!HEX_PATH_%%I!"
    if errorlevel 1 goto :git_add_failed

    git add -f "!ZIP_PATH_%%I!"
    if errorlevel 1 goto :git_add_failed
)

git ls-files --error-unmatch "%VERSION_FILE%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: '%VERSION_FILE%' is not tracked or staged.
    pause
    exit /b 1
)

for /l %%I in (1,1,!ELIGIBLE_COUNT!) do (
    set "GIT_HEX_PATH=!HEX_PATH_%%I:\=/!"
    set "GIT_ZIP_PATH=!ZIP_PATH_%%I:\=/!"

    git diff --cached --name-only | findstr /x /c:"!GIT_HEX_PATH!" >nul
    if errorlevel 1 (
        echo ERROR: '!GIT_HEX_PATH!' is not staged.
        pause
        exit /b 1
    )
    git diff --cached --name-only | findstr /x /c:"!GIT_ZIP_PATH!" >nul
    if errorlevel 1 (
        echo ERROR: '!GIT_ZIP_PATH!' is not staged.
        pause
        exit /b 1
    )
)

echo Creating release commit...
git commit -m "release: version %RELEASE_VER% (!ELIGIBLE_COUNT! build variant(s))"
if errorlevel 1 (
    echo ERROR: Git commit failed.
    pause
    exit /b 1
)

echo Creating annotated Git tag: %TAG_NAME%...
set "TAG_MSG=Release %TAG_NAME% (%TS%)"
git tag -a "%TAG_NAME%" -m "%TAG_MSG%"
if errorlevel 1 (
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
if errorlevel 1 (
    echo INTEGRITY ERROR: Resolved SHA '!TAG_COMMIT!' for tag '%TAG_NAME%' is not a valid commit object.
    pause
    exit /b 1
)

set "GIT_VERSION_FILE=%VERSION_FILE:\=/%"
git ls-tree -r --name-only "!TAG_COMMIT!" -- "%GIT_VERSION_FILE%" | findstr /x /c:"%GIT_VERSION_FILE%" >nul
if errorlevel 1 (
    echo INTEGRITY ERROR: Exact file path '%GIT_VERSION_FILE%' is missing from release tag commit (!TAG_COMMIT!).
    pause
    exit /b 1
)

for /l %%I in (1,1,!ELIGIBLE_COUNT!) do (
    set "GIT_HEX_PATH=!HEX_PATH_%%I:\=/!"
    set "GIT_ZIP_PATH=!ZIP_PATH_%%I:\=/!"

    git ls-tree -r --name-only "!TAG_COMMIT!" -- "!GIT_HEX_PATH!" | findstr /x /c:"!GIT_HEX_PATH!" >nul
    if errorlevel 1 (
        echo INTEGRITY ERROR: Exact artifact path '!GIT_HEX_PATH!' is missing from release tag commit (!TAG_COMMIT!).
        pause
        exit /b 1
    )
    git ls-tree -r --name-only "!TAG_COMMIT!" -- "!GIT_ZIP_PATH!" | findstr /x /c:"!GIT_ZIP_PATH!" >nul
    if errorlevel 1 (
        echo INTEGRITY ERROR: Exact artifact path '!GIT_ZIP_PATH!' is missing from release tag commit (!TAG_COMMIT!).
        pause
        exit /b 1
    )
)

echo Release tag integrity verified: exact source + all firmware artifacts confirmed.

REM ------------------------------------------------------------------------------
REM 10. Push to GitHub Remote
REM ------------------------------------------------------------------------------
echo Pushing release commit and tag to GitHub (origin)...
for /f "tokens=*" %%B in ('git rev-parse --abbrev-ref HEAD') do set "CURRENT_BRANCH=%%B"

git push origin %CURRENT_BRANCH%
if errorlevel 1 (
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
if errorlevel 1 (
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
echo Firmware Project:   %REPO_NAME%
echo Firmware Released:  %RELEASE_VER%
echo Release Directory:  %RELEASE_BASE%\
echo Git Release Tag:    %TAG_NAME%
echo Build Variants Packaged (!ELIGIBLE_COUNT!):
for /l %%I in (1,1,!ELIGIBLE_COUNT!) do (
    echo   - [!BUILD_DIR_%%I!]
    echo       HEX: !HEX_NAME_%%I!
    echo       ZIP: !ZIP_NAME_%%I!
)
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