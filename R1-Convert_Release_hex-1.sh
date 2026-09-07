#!/usr/bin/env bash
# ==============================================================================
# TokuchuTech Fleet Firmware Release Automation Script (Linux/macOS)
# Project: Threaded_NC_SP
# ==============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=================================================="
echo "      TokuchuTech Firmware Release Manager        "
echo "=================================================="

# ------------------------------------------------------------------------------
# 1. Git Safety Checks
# ------------------------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: Not inside a valid Git repository."
    echo "Release aborted."
    exit 1
fi

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ERROR: Git remote 'origin' not found."
    echo "Release aborted."
    exit 1
fi

VERSION_FILE="src/app_version.h"
if [[ ! -f "$VERSION_FILE" ]]; then
    echo "ERROR: Version definition file '$VERSION_FILE' not found."
    echo "Release aborted."
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Parse Current Version from app_version.h
# ------------------------------------------------------------------------------
RAW_VER_LINE=$(grep -E '^[[:space:]]*#[[:space:]]*define[[:space:]]+APP_VERSION_STR[[:space:]]+' "$VERSION_FILE" || true)
if [[ -z "$RAW_VER_LINE" ]]; then
    echo "ERROR: Could not find APP_VERSION_STR in '$VERSION_FILE'."
    echo "Release aborted."
    exit 1
fi

CURRENT_VER=$(echo "$RAW_VER_LINE" | sed -E 's/.*APP_VERSION_STR[[:space:]]+"([^"]+)".*/\1/')

# Strict Major.Patch validation
if [[ ! "$CURRENT_VER" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Current version '$CURRENT_VER' does not follow Major.Patch format (e.g. 1.2)."
    echo "Release aborted."
    exit 1
fi

# ------------------------------------------------------------------------------
# 3. Determine Release Version & Calculate Next Version
# ------------------------------------------------------------------------------
RELEASE_VER="$CURRENT_VER"
MAJOR="${CURRENT_VER%%.*}"
PATCH="${CURRENT_VER##*.}"
NEXT_PATCH=$((PATCH + 1))
NEXT_VER="${MAJOR}.${NEXT_PATCH}"

echo "Releasing firmware version: $RELEASE_VER"
echo "Next development version:   $NEXT_VER (will be set after release completes)"
echo ""

# ------------------------------------------------------------------------------
# 5. Check if Target Git Tag Already Exists
# ------------------------------------------------------------------------------
TAG_NAME="stable-release-${RELEASE_VER}"

if git rev-parse -q --verify "refs/tags/${TAG_NAME}" >/dev/null 2>&1; then
    echo "ERROR: Local Git tag '${TAG_NAME}' already exists."
    echo "If a previous release partially succeeded or network dropped during confirmation, check:"
    echo "  git ls-remote --tags origin refs/tags/${TAG_NAME}"
    echo "To proceed with a new release cycle, advance '$VERSION_FILE' to $NEXT_VER."
    echo "Overwriting existing release tags is strictly prohibited."
    echo "Release aborted."
    exit 1
fi

# Check remote tags if connected
if git ls-remote --tags origin "refs/tags/${TAG_NAME}" 2>/dev/null | grep -q "${TAG_NAME}"; then
    echo "ERROR: Remote Git tag '${TAG_NAME}' already exists on origin."
    echo "If the release already reached GitHub, advance '$VERSION_FILE' to $NEXT_VER for the next cycle."
    echo "Release aborted."
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Locate Build Artifacts & Enforce Freshness (Built Today)
# ------------------------------------------------------------------------------
REPO_NAME="$(basename "$SCRIPT_DIR")"
TODAY_DATE=$(date +"%Y-%m-%d")
TIMESTAMP=$(date +"%d-%b-%Y-%H-%M")

echo "Scanning for firmware build directories..."
echo "Release date cutoff: Today ($TODAY_DATE)"
echo ""

is_excluded_dir() {
    local d="$1"
    case "$d" in
        Releases|src|boards|docs|Key|modules|zephyr|mcuboot|CMakeFiles|\.git|\.vscode|_sysbuild)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

get_file_date() {
    local file="$1"
    if stat -c %y "$file" >/dev/null 2>&1; then
        stat -c %y "$file" | cut -d' ' -f1
    else
        date -r "$file" +"%Y-%m-%d"
    fi
}

get_file_timestamp() {
    local file="$1"
    if stat -c %y "$file" >/dev/null 2>&1; then
        stat -c %y "$file" | cut -d. -f1
    else
        date -r "$file" +"%Y-%m-%d %H:%M:%S"
    fi
}

CANDIDATE_DIRS=()
# Known standard candidates
for d in "SPNC_FOTA" "build" "build/zephyr" "SPNC_FOTA/zephyr" "bin" "out"; do
    if [[ -d "$d" ]]; then
        CANDIDATE_DIRS+=("$d")
    fi
done

# Scan any top-level directories
for d in *; do
    if [[ -d "$d" ]] && ! is_excluded_dir "$d"; then
        found=0
        for cd in "${CANDIDATE_DIRS[@]}"; do
            if [[ "$cd" == "$d" ]]; then
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            CANDIDATE_DIRS+=("$d")
        fi
    fi
done

ELIGIBLE_BUILDS=()
ELIGIBLE_BUILD_TIMES=()
STALE_BUILDS=()
STALE_BUILD_TIMES=()

archive_and_clean_stale_dir() {
    local dir="$1"
    local hex="$dir/merged.hex"
    local zip="$dir/dfu_application.zip"
    local safe_name
    safe_name=$(echo "$dir" | sed 's#[/\\]#__#g')

    # Format build timestamp for filename (e.g. 24-Aug-2026-15-03)
    local build_ts
    build_ts=$(date -r "$hex" +"%d-%b-%Y-%H-%M" 2>/dev/null || stat -c %y "$hex" 2>/dev/null | cut -d. -f1 | tr ' :' '--')

    mkdir -p "Releases"

    local hex_hash=""
    local zip_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        hex_hash=$(sha256sum "$hex" 2>/dev/null | awk '{print $1}')
        zip_hash=$(sha256sum "$zip" 2>/dev/null | awk '{print $1}')
    fi

    local hex_already_saved=0
    local zip_already_saved=0

    if [[ -n "$hex_hash" ]]; then
        if find Releases -type f -exec sha256sum {} + 2>/dev/null | grep -q "^$hex_hash "; then
            hex_already_saved=1
        fi
    fi
    if [[ -n "$zip_hash" ]]; then
        if find Releases -type f -exec sha256sum {} + 2>/dev/null | grep -q "^$zip_hash "; then
            zip_already_saved=1
        fi
    fi

    if [[ $hex_already_saved -eq 1 && $zip_already_saved -eq 1 ]]; then
        echo "    -> Already archived: Identical artifacts exist in Releases/."
    else
        echo "    -> Backing up outdated artifacts into Releases/ before cleanup..."
        local arch_hex="Releases/archived_${safe_name}_${build_ts}_${REPO_NAME}_merged.hex"
        local arch_zip="Releases/archived_${safe_name}_${build_ts}_${REPO_NAME}_dfu.zip"
        cp "$hex" "$arch_hex"
        cp "$zip" "$arch_zip"
        echo "       Saved: $arch_hex"
        echo "       Saved: $arch_zip"
    fi

    echo "    -> Removing outdated build directory '$dir/'..."
    rm -rf "$dir"
    echo "    -> Cleaned '$dir/' successfully."
}

for dir in "${CANDIDATE_DIRS[@]}"; do
    HEX_CAND="$dir/merged.hex"
    ZIP_CAND="$dir/dfu_application.zip"

    if [[ -f "$HEX_CAND" && -f "$ZIP_CAND" ]]; then
        # Check if non-empty
        if [[ ! -s "$HEX_CAND" || ! -s "$ZIP_CAND" ]]; then
            echo "  [WARN] Skipping '$dir/': merged.hex or dfu_application.zip is empty (0 bytes)."
            continue
        fi

        BUILD_DATE=$(get_file_date "$HEX_CAND")
        BUILD_TIME=$(get_file_timestamp "$HEX_CAND")

        if [[ "$BUILD_DATE" == "$TODAY_DATE" ]]; then
            ELIGIBLE_BUILDS+=("$dir")
            ELIGIBLE_BUILD_TIMES+=("$BUILD_TIME")
            echo "  [FRESH BUILD] Found '$dir/' (Compiled today at $BUILD_TIME)"
        else
            STALE_BUILDS+=("$dir")
            STALE_BUILD_TIMES+=("$BUILD_TIME")
            echo "  [OUTDATED / ARCHIVING] '$dir/' (Compiled on $BUILD_TIME - not today)"
            archive_and_clean_stale_dir "$dir"
        fi
    fi
done

echo ""

if [[ ${#ELIGIBLE_BUILDS[@]} -eq 0 ]]; then
    echo "=================================================="
    echo "Outdated build directory cleanup complete."
    echo "No fresh firmware builds compiled today were found."
    echo "Today's date: $TODAY_DATE"
    echo "=================================================="
    if [[ ${#STALE_BUILDS[@]} -gt 0 ]]; then
        echo "Processed and removed outdated build directories:"
        for i in "${!STALE_BUILDS[@]}"; do
            echo "  - ${STALE_BUILDS[$i]}/ (Built: ${STALE_BUILD_TIMES[$i]})"
        done
        echo ""
    fi
    echo "Please build the firmware (e.g. via 'west build') and re-run this script to release."
    echo "Release aborted."
    exit 1
fi

echo "Eligible builds to package (${#ELIGIBLE_BUILDS[@]} build(s)):"
for i in "${!ELIGIBLE_BUILDS[@]}"; do
    b_dir="${ELIGIBLE_BUILDS[$i]}"
    echo "  $((i + 1)). $b_dir/ [HEX: $(du -h "$b_dir/merged.hex" | cut -f1), ZIP: $(du -h "$b_dir/dfu_application.zip" | cut -f1)]"
done
echo ""

# ------------------------------------------------------------------------------
# 7. Create Releases Directory & Package Artifacts
# ------------------------------------------------------------------------------
RELEASE_BASE="Releases"
if ! mkdir -p "$RELEASE_BASE"; then
    echo "ERROR: Failed to create or access '$RELEASE_BASE' directory."
    echo "Release aborted."
    exit 1
fi

COPIED_HEX_PATHS=()
COPIED_ZIP_PATHS=()
COPIED_HEX_NAMES=()
COPIED_ZIP_NAMES=()
ALL_PACKAGED_FILES=()

echo "Packaging release artifacts into '$RELEASE_BASE/'..."

for i in "${!ELIGIBLE_BUILDS[@]}"; do
    b_dir="${ELIGIBLE_BUILDS[$i]}"
    # Replace slashes and backslashes with double underscores for filename safety
    safe_folder_name=$(echo "$b_dir" | sed 's#[/\\]#__#g')

    TARGET_HEX_NAME="${safe_folder_name}_v${RELEASE_VER}_${TIMESTAMP}_${REPO_NAME}_merged.hex"
    TARGET_ZIP_NAME="${safe_folder_name}_v${RELEASE_VER}_${TIMESTAMP}_${REPO_NAME}_dfu.zip"

    TARGET_HEX_PATH="$RELEASE_BASE/$TARGET_HEX_NAME"
    TARGET_ZIP_PATH="$RELEASE_BASE/$TARGET_ZIP_NAME"

    echo "Packaging build '$b_dir/':"
    echo "  HEX -> $TARGET_HEX_PATH"
    if ! cp "$b_dir/merged.hex" "$TARGET_HEX_PATH"; then
        echo "ERROR: Failed to copy '$b_dir/merged.hex' to '$TARGET_HEX_PATH'."
        echo "Release aborted."
        exit 1
    fi

    echo "  ZIP -> $TARGET_ZIP_PATH"
    if ! cp "$b_dir/dfu_application.zip" "$TARGET_ZIP_PATH"; then
        echo "ERROR: Failed to copy '$b_dir/dfu_application.zip' to '$TARGET_ZIP_PATH'."
        echo "Release aborted."
        exit 1
    fi

    # Verify target files are non-empty
    if [[ ! -s "$TARGET_HEX_PATH" ]]; then
        echo "ERROR: Target file '$TARGET_HEX_PATH' is missing or 0 bytes after copy."
        exit 1
    fi
    if [[ ! -s "$TARGET_ZIP_PATH" ]]; then
        echo "ERROR: Target file '$TARGET_ZIP_PATH' is missing or 0 bytes after copy."
        exit 1
    fi

    COPIED_HEX_PATHS+=("$TARGET_HEX_PATH")
    COPIED_ZIP_PATHS+=("$TARGET_ZIP_PATH")
    COPIED_HEX_NAMES+=("$TARGET_HEX_NAME")
    COPIED_ZIP_NAMES+=("$TARGET_ZIP_NAME")
    ALL_PACKAGED_FILES+=("$TARGET_HEX_PATH" "$TARGET_ZIP_PATH")
done

echo ""
echo "Successfully packaged ${#ALL_PACKAGED_FILES[@]} artifact file(s) into '$RELEASE_BASE/'."
echo ""

# ------------------------------------------------------------------------------
# 8. Git Staging, Commit & Release Tag
# ------------------------------------------------------------------------------
echo "Staging release files in Git..."
git add "$VERSION_FILE" || { echo "ERROR: Failed to stage '$VERSION_FILE'."; echo "Release aborted."; exit 1; }
git add .gitignore || { echo "ERROR: Failed to stage '.gitignore'."; echo "Release aborted."; exit 1; }
git add R1-Convert_Release_hex-1.sh || { echo "ERROR: Failed to stage 'R1-Convert_Release_hex-1.sh'."; echo "Release aborted."; exit 1; }
git add R1-Convert_Release_hex-1.bat || { echo "ERROR: Failed to stage 'R1-Convert_Release_hex-1.bat'."; echo "Release aborted."; exit 1; }

for target_file in "${ALL_PACKAGED_FILES[@]}"; do
    git add -f "$target_file" || { echo "ERROR: Failed to stage '$target_file'."; echo "Release aborted."; exit 1; }
done

# Verify expected files are staged
if ! git ls-files --error-unmatch "$VERSION_FILE" >/dev/null 2>&1; then
    echo "ERROR: '$VERSION_FILE' is not tracked or staged."
    exit 1
fi

STAGED_FILES=$(git diff --cached --name-only)
for target_file in "${ALL_PACKAGED_FILES[@]}"; do
    if ! echo "$STAGED_FILES" | grep -Fxq "$target_file"; then
        echo "ERROR: '$target_file' is not staged."
        exit 1
    fi
done

echo "Creating release commit..."
BUILD_COUNT="${#ELIGIBLE_BUILDS[@]}"
git commit -m "release: version ${RELEASE_VER} (${BUILD_COUNT} build variant(s))"

echo "Creating annotated Git tag: $TAG_NAME..."
TAG_MSG="Release ${TAG_NAME} (${TIMESTAMP})

Firmware: ${REPO_NAME}
Version:  ${RELEASE_VER}
Builds Packaged (${BUILD_COUNT}):"

for i in "${!ELIGIBLE_BUILDS[@]}"; do
    TAG_MSG+=$'\n'"  - Build Folder: ${ELIGIBLE_BUILDS[$i]}"
    TAG_MSG+=$'\n'"    Build Time:   ${ELIGIBLE_BUILD_TIMES[$i]}"
    TAG_MSG+=$'\n'"    HEX Artifact: ${COPIED_HEX_NAMES[$i]}"
    TAG_MSG+=$'\n'"    ZIP Artifact: ${COPIED_ZIP_NAMES[$i]}"
done

git tag -a "$TAG_NAME" -m "$TAG_MSG"

# ------------------------------------------------------------------------------
# 9. Verify Tag Integrity (git ls-tree -r with Exact Path Matching)
# ------------------------------------------------------------------------------
echo "Verifying release tag integrity (git ls-tree -r refs/tags/$TAG_NAME)..."

TAG_COMMIT=$(git rev-list -n 1 "$TAG_NAME" 2>/dev/null || true)
if [[ -z "$TAG_COMMIT" ]]; then
    echo "INTEGRITY ERROR: Tag '$TAG_NAME' could not be resolved to a commit SHA."
    exit 1
fi

if ! git cat-file -e "${TAG_COMMIT}^{commit}" 2>/dev/null; then
    echo "INTEGRITY ERROR: Resolved SHA '$TAG_COMMIT' for tag '$TAG_NAME' is not a valid commit object."
    exit 1
fi

if ! git ls-tree -r --name-only "$TAG_COMMIT" -- "$VERSION_FILE" | grep -Fxq "$VERSION_FILE"; then
    echo "INTEGRITY ERROR: Exact file path '$VERSION_FILE' is missing from release tag commit ($TAG_COMMIT)."
    exit 1
fi

for target_file in "${ALL_PACKAGED_FILES[@]}"; do
    if ! git ls-tree -r --name-only "$TAG_COMMIT" -- "$target_file" | grep -Fxq "$target_file"; then
        echo "INTEGRITY ERROR: Exact artifact path '$target_file' is missing from release tag commit ($TAG_COMMIT)."
        exit 1
    fi
done

echo "Release tag integrity verified: exact source + all firmware artifacts confirmed."

# ------------------------------------------------------------------------------
# 10. Push to GitHub Remote
# ------------------------------------------------------------------------------
echo "Pushing release commit and tag to GitHub (origin)..."
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if ! git push origin "$CURRENT_BRANCH"; then
    echo ""
    echo "ERROR: Failed to push commit to origin/$CURRENT_BRANCH."
    echo "Push status could not be confirmed. Verify the remote branch before retrying:"
    echo "  git log origin/$CURRENT_BRANCH -n 1"
    echo "  git ls-remote --tags origin refs/tags/$TAG_NAME"
    echo "Release aborted. '$VERSION_FILE' was NOT modified and remains at $RELEASE_VER."
    exit 1
fi

if ! git push origin "$TAG_NAME"; then
    echo ""
    echo "ERROR: Failed to push tag '$TAG_NAME' to origin."
    echo "Push status could not be confirmed. Verify the remote tag before retrying:"
    echo "  git ls-remote --tags origin refs/tags/$TAG_NAME"
    echo "Release aborted. '$VERSION_FILE' was NOT modified and remains at $RELEASE_VER."
    exit 1
fi

# ------------------------------------------------------------------------------
# 11. Advance to Next Development Version (Local Only & Verified)
# ------------------------------------------------------------------------------
echo ""
echo "Advancing '$VERSION_FILE' locally to $NEXT_VER for next development cycle..."
cat <<EOF > "$VERSION_FILE"
#ifndef APP_VERSION_H
#define APP_VERSION_H

#define APP_VERSION_MAJOR $MAJOR
#define APP_VERSION_PATCH $NEXT_PATCH
#define APP_VERSION_STR   "$NEXT_VER"

#endif /* APP_VERSION_H */
EOF

if [[ ! -f "$VERSION_FILE" || ! -s "$VERSION_FILE" ]]; then
    echo "ERROR: Failed to write to '$VERSION_FILE' or file is empty."
    exit 1
fi

WRITTEN_LINE=$(grep -E '^[[:space:]]*#[[:space:]]*define[[:space:]]+APP_VERSION_STR[[:space:]]+' "$VERSION_FILE" || true)
WRITTEN_VER=$(echo "$WRITTEN_LINE" | sed -E 's/.*APP_VERSION_STR[[:space:]]+"([^"]+)".*/\1/')

if [[ "$WRITTEN_VER" != "$NEXT_VER" ]]; then
    echo "ERROR: Version verification failed after writing '$VERSION_FILE'."
    echo "Expected: $NEXT_VER, found: $WRITTEN_VER"
    exit 1
fi
echo "Verified: '$VERSION_FILE' successfully set to $NEXT_VER for next development cycle."

# ------------------------------------------------------------------------------
# 12. Success Summary
# ------------------------------------------------------------------------------
echo ""
echo "=================================================="
echo " Release $TAG_NAME Completed Successfully!"
echo "=================================================="
echo "Firmware Project:   $REPO_NAME"
echo "Firmware Released:  $RELEASE_VER"
echo "Release Directory:  $RELEASE_BASE/"
echo "Git Release Tag:    $TAG_NAME"
echo "Build Variants Packaged ($BUILD_COUNT):"
for i in "${!ELIGIBLE_BUILDS[@]}"; do
    echo "  - [${ELIGIBLE_BUILDS[$i]}]"
    echo "      HEX: ${COPIED_HEX_NAMES[$i]}"
    echo "      ZIP: ${COPIED_ZIP_NAMES[$i]}"
done
echo "Next Version Set:   $NEXT_VER in $VERSION_FILE (local only)"
echo "=================================================="
