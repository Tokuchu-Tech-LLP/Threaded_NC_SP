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
    echo "Overwriting existing release tags is strictly prohibited."
    echo "Release aborted."
    exit 1
fi

# Check remote tags if connected
if git ls-remote --tags origin "refs/tags/${TAG_NAME}" 2>/dev/null | grep -q "${TAG_NAME}"; then
    echo "ERROR: Remote Git tag '${TAG_NAME}' already exists on origin."
    echo "Release aborted."
    exit 1
fi

# ------------------------------------------------------------------------------
# 6. Locate Build Artifacts (merged.hex & dfu_application.zip)
# ------------------------------------------------------------------------------
HEX_SRC=""
ZIP_SRC=""

# Known candidate directories in order of preference
CANDIDATE_DIRS=("SPNC_FOTA" "build" "build/zephyr" "SPNC_FOTA/zephyr" "bin" "out")

# Also search all subdirectories
for dir in *; do
    if [[ -d "$dir" && "$dir" != "Releases" && "$dir" != "src" && "$dir" != "boards" && "$dir" != "docs" ]]; then
        CANDIDATE_DIRS+=("$dir")
    fi
done

for dir in "${CANDIDATE_DIRS[@]}"; do
    if [[ -f "$dir/merged.hex" && -f "$dir/dfu_application.zip" ]]; then
        HEX_SRC="$dir/merged.hex"
        ZIP_SRC="$dir/dfu_application.zip"
        echo "Found release artifacts in directory: $dir/"
        break
    fi
done

if [[ -z "$HEX_SRC" || -z "$ZIP_SRC" ]]; then
    # Try finding individually if in slightly different folders
    if [[ -z "$HEX_SRC" ]]; then
        HEX_SRC=$(find . -maxdepth 3 -name "merged.hex" ! -path "*/Releases/*" | head -n 1)
    fi
    if [[ -z "$ZIP_SRC" ]]; then
        ZIP_SRC=$(find . -maxdepth 3 -name "dfu_application.zip" ! -path "*/Releases/*" | head -n 1)
    fi
fi

if [[ -z "$HEX_SRC" || ! -f "$HEX_SRC" || -z "$ZIP_SRC" || ! -f "$ZIP_SRC" ]]; then
    echo "ERROR: Required release artifacts not found."
    echo "Looked for 'merged.hex' and 'dfu_application.zip'."
    echo "Please build the firmware before running the release script."
    echo "Release aborted."
    exit 1
fi

# Verify artifacts are non-empty
if [[ ! -s "$HEX_SRC" ]]; then
    echo "ERROR: Artifact '$HEX_SRC' is empty (0 bytes)."
    echo "Release aborted."
    exit 1
fi

if [[ ! -s "$ZIP_SRC" ]]; then
    echo "ERROR: Artifact '$ZIP_SRC' is empty (0 bytes)."
    echo "Release aborted."
    exit 1
fi

echo "Artifacts to package:"
echo "  HEX: $HEX_SRC ($(du -h "$HEX_SRC" | cut -f1))"
echo "  ZIP: $ZIP_SRC ($(du -h "$ZIP_SRC" | cut -f1))"

# ------------------------------------------------------------------------------
# 7. Create Release Directory & Copy Artifacts
# ------------------------------------------------------------------------------
TIMESTAMP=$(date +"%d-%b-%Y-%H-%M")
RELEASE_DIR="Releases/v${RELEASE_VER}_${TIMESTAMP}"

mkdir -p "$RELEASE_DIR"

echo "Creating release directory: $RELEASE_DIR/"
cp "$HEX_SRC" "$RELEASE_DIR/merged.hex"
cp "$ZIP_SRC" "$RELEASE_DIR/dfu_application.zip"

if [[ ! -f "$RELEASE_DIR/merged.hex" || ! -f "$RELEASE_DIR/dfu_application.zip" ]]; then
    echo "ERROR: Failed to copy release artifacts into '$RELEASE_DIR'."
    echo "Release aborted."
    exit 1
fi

# ------------------------------------------------------------------------------
# 8. Git Staging, Commit & Release Tag
# ------------------------------------------------------------------------------
echo "Staging release files in Git..."
git add "$VERSION_FILE"
git add .gitignore
git add R1-Convert_Release_hex-1.sh
git add R1-Convert_Release_hex-1.bat
git add -f "$RELEASE_DIR/merged.hex"
git add -f "$RELEASE_DIR/dfu_application.zip"

# Verify expected files are staged
if ! git ls-files --error-unmatch "$VERSION_FILE" >/dev/null 2>&1; then
    echo "ERROR: '$VERSION_FILE' is not tracked or staged."
    exit 1
fi

STAGED_FILES=$(git diff --cached --name-only)
if ! echo "$STAGED_FILES" | grep -q "$RELEASE_DIR/merged.hex"; then
    echo "ERROR: '$RELEASE_DIR/merged.hex' is not staged."
    exit 1
fi
if ! echo "$STAGED_FILES" | grep -q "$RELEASE_DIR/dfu_application.zip"; then
    echo "ERROR: '$RELEASE_DIR/dfu_application.zip' is not staged."
    exit 1
fi

echo "Creating release commit..."
git commit -m "release: version ${RELEASE_VER}"

echo "Creating annotated Git tag: $TAG_NAME..."
git tag -a "$TAG_NAME" -m "Release $TAG_NAME"

# ------------------------------------------------------------------------------
# 9. Push to GitHub Remote
# ------------------------------------------------------------------------------
echo "Pushing release commit and tag to GitHub (origin)..."
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

if ! git push origin "$CURRENT_BRANCH"; then
    echo "ERROR: Failed to push commit to origin/$CURRENT_BRANCH."
    echo "Release tag not pushed."
    exit 1
fi

if ! git push origin "$TAG_NAME"; then
    echo "ERROR: Failed to push tag '$TAG_NAME' to origin."
    exit 1
fi

# ------------------------------------------------------------------------------
# 10. Advance to Next Development Version (Local Only)
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

# ------------------------------------------------------------------------------
# 11. Success Summary
# ------------------------------------------------------------------------------
echo ""
echo "=================================================="
echo " Release $TAG_NAME Completed Successfully!"
echo "=================================================="
echo "Firmware Released:  $RELEASE_VER"
echo "Release Directory:  $RELEASE_DIR/"
echo "Release Artifacts:  merged.hex, dfu_application.zip"
echo "Git Release Tag:    $TAG_NAME"
echo "Next Version Set:   $NEXT_VER in $VERSION_FILE (local only)"
echo "=================================================="
