#!/bin/bash
# embed_openslide.sh - Copy OpenSlide and ALL dependencies into app bundle Frameworks
# Uses recursive dependency resolution via otool -L
set -e

FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
mkdir -p "${FRAMEWORKS_DIR}"

TMPLIST=$(mktemp /tmp/dylib_list.XXXXXX)

# Recursive dependency resolver using a temp file to track resolved libs
resolve_deps() {
    local lib="$1"
    local reallib
    
    # Resolve symlinks
    if [ -L "$lib" ]; then
        reallib=$(readlink -f "$lib" 2>/dev/null || python3 -c "import os; print(os.path.realpath('$lib'))")
    else
        reallib="$lib"
    fi
    
    local name=$(basename "$lib")
    
    # Skip if already resolved
    if grep -q "^${name}$" "$TMPLIST" 2>/dev/null; then
        return
    fi
    echo "$name" >> "$TMPLIST"
    
    # Only process homebrew libs
    case "$reallib" in
        /opt/homebrew/*) ;;
        *) return ;;
    esac
    
    if [ ! -f "$reallib" ]; then
        echo "Warning: $reallib not found, skipping"
        return
    fi
    
    echo "  Found: $name ($reallib)"
    cp -f "$reallib" "${FRAMEWORKS_DIR}/${name}"
    chmod 755 "${FRAMEWORKS_DIR}/${name}"
    install_name_tool -id "@rpath/${name}" "${FRAMEWORKS_DIR}/${name}" 2>/dev/null || true
    
    # Recurse into dependencies
    local deps=$(otool -L "$reallib" | tail -n +2 | awk '{print $1}')
    for dep in $deps; do
        case "$dep" in
            /opt/homebrew/*) resolve_deps "$dep" ;;
        esac
    done
}

# Start with openslide
echo "Resolving dependencies for libopenslide..."
resolve_deps "/opt/homebrew/opt/openslide/lib/libopenslide.1.dylib"

COUNT=$(wc -l < "$TMPLIST" | tr -d ' ')
echo "Found ${COUNT} libraries to embed"
rm -f "$TMPLIST"

# Fix all inter-library references
echo "Fixing library references..."
for fw_dylib in "${FRAMEWORKS_DIR}"/*.dylib; do
    deps=$(otool -L "$fw_dylib" | tail -n +2 | awk '{print $1}')
    for dep in $deps; do
        dep_name=$(basename "$dep")
        case "$dep" in
            /opt/homebrew/*) install_name_tool -change "$dep" "@rpath/${dep_name}" "$fw_dylib" 2>/dev/null || true ;;
        esac
    done
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "$fw_dylib" 2>/dev/null || true
done

# Fix the main app binary
APP_BIN="${BUILT_PRODUCTS_DIR}/${EXECUTABLE_PATH}"
if [ -f "$APP_BIN" ]; then
    deps=$(otool -L "$APP_BIN" | tail -n +2 | awk '{print $1}')
    for dep in $deps; do
        dep_name=$(basename "$dep")
        case "$dep" in
            /opt/homebrew/*) install_name_tool -change "$dep" "@rpath/${dep_name}" "$APP_BIN" 2>/dev/null || true ;;
        esac
    done
fi

# Fix appex binaries, debug dylibs, and inject entitlements
for appex in "${BUILT_PRODUCTS_DIR}/${PLUGINS_FOLDER_PATH}"/*.appex; do
    if [ -d "$appex" ]; then
        appex_name=$(basename "$appex" .appex)
        appex_macos="${appex}/Contents/MacOS"
        
        # Fix the main appex binary
        appex_bin="${appex_macos}/${appex_name}"
        if [ -f "$appex_bin" ]; then
            deps=$(otool -L "$appex_bin" | tail -n +2 | awk '{print $1}')
            for dep in $deps; do
                dep_name=$(basename "$dep")
                case "$dep" in
                    /opt/homebrew/*) install_name_tool -change "$dep" "@rpath/${dep_name}" "$appex_bin" 2>/dev/null || true ;;
                esac
            done
        fi
        
        # Fix all dylibs inside the appex (including .debug.dylib)
        for dylib in "${appex_macos}"/*.dylib; do
            if [ -f "$dylib" ]; then
                deps=$(otool -L "$dylib" | tail -n +2 | awk '{print $1}')
                for dep in $deps; do
                    dep_name=$(basename "$dep")
                    case "$dep" in
                        /opt/homebrew/*) install_name_tool -change "$dep" "@rpath/${dep_name}" "$dylib" 2>/dev/null || true ;;
                    esac
                done
                # Re-sign the dylib after modification
                codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "$dylib" 2>/dev/null || true
            fi
        done
        
        ENTFILE="${PROJECT_DIR}/${appex_name}/${appex_name}.entitlements"
        if [ -f "$ENTFILE" ]; then
            echo "Re-signing ${appex_name} with entitlements"
            codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --entitlements "$ENTFILE" "$appex" 2>/dev/null || true
        else
            codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" "$appex" 2>/dev/null || true
        fi
    fi
done

# Re-sign the main app
if [ -f "$APP_BIN" ]; then
    MAIN_ENTFILE="${PROJECT_DIR}/SlideSVC/SlideSVC.entitlements"
    if [ -f "$MAIN_ENTFILE" ]; then
        codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" --entitlements "$MAIN_ENTFILE" "${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}" 2>/dev/null || true
    fi
fi

echo "OpenSlide and ${COUNT} dependencies embedded successfully"
