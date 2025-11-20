#!/bin/bash
set -e

# Load Configuration
source ./config.sh
source ./ndk-setup.sh

# --- Functions ---

prepare_sources() {
    echo "==> Preparing Sources..."
    mkdir -p "$SRC_DIR" "$OUT_DIR"

    # 1. Download Talloc
    if [ ! -d "$SRC_DIR/talloc-$TALLOC_VERSION" ]; then
        echo " -> Downloading Talloc $TALLOC_VERSION..."
        curl -L -o "$SRC_DIR/talloc.tar.gz" "https://www.samba.org/ftp/talloc/talloc-$TALLOC_VERSION.tar.gz"
        tar -xzf "$SRC_DIR/talloc.tar.gz" -C "$SRC_DIR"
        rm "$SRC_DIR/talloc.tar.gz"
    fi

    # 2. Download Proot
    if [ ! -d "$SRC_DIR/proot" ]; then
        echo " -> Cloning Proot ($PROOT_REF)..."
        git clone https://github.com/termux/proot.git "$SRC_DIR/proot"
        cd "$SRC_DIR/proot"
        git checkout "$PROOT_REF"
        
        # Apply Patches
        if [ -d "$PATCH_DIR" ]; then
            echo " -> Applying patches..."
            for patch in "$PATCH_DIR"/*.patch; do
                [ -f "$patch" ] || continue
                echo "   Applying $(basename "$patch")"
                patch -p1 < "$patch" || echo "Warning: Failed to apply $patch (maybe already applied?)"
            done
        fi
        cd - > /dev/null
    fi
}

generate_talloc_answers() {
    local file=$1
    cat <<EOF > "$file"
Checking uname sysname type: "Linux"
Checking uname machine type: "dontcare"
Checking uname release type: "dontcare"
Checking uname version type: "dontcare"
Checking simple C program: OK
rpath library support: OK
-Wl,--version-script support: FAIL
Checking getconf LFS_CFLAGS: OK
Checking for large file support without additional flags: OK
Checking for -D_FILE_OFFSET_BITS=64: $FILE_OFFSET_BITS
Checking for -D_LARGE_FILES: OK
Checking correct behavior of strtoll: OK
Checking for working strptime: OK
Checking for C99 vsnprintf: OK
Checking for HAVE_SHARED_MMAP: OK
Checking for HAVE_MREMAP: OK
Checking for HAVE_INCOHERENT_MMAP: OK
Checking for HAVE_SECURE_MKSTEMP: OK
Checking getconf large file support flags work: OK
Checking for HAVE_IFACE_IFCONF: FAIL
EOF
}

download_loader() {
    local ARCH=$1
    local DEST_DIR=$2

    # Parse LOADER_TAG (Format: TAG::VERSION)
    local TAG="${LOADER_TAG%%::*}"
    local VER="${LOADER_TAG##*::}"

    # --- 1. Download Main Loader ---
    local LOADER_ARCH="$ARCH"
    # Map standard arch to loader filename convention if needed
    if [ "$ARCH" == "arm64" ]; then LOADER_ARCH="aarch64"; fi
    # x86, x86_64, arm usually match directly

    local ASSET_NAME="libproot-loader-${LOADER_ARCH}-${VER}.so"
    local URL="https://github.com/${LOADER_REPO}/releases/download/${TAG}/${ASSET_NAME}"

    echo " -> Downloading Main Loader ($LOADER_ARCH)..."
    # We rename the downloaded asset to a generic 'libproot-loader.so'
    curl -L -f -o "${DEST_DIR}/libproot-loader.so" "$URL" || {
        echo "Error: Failed to download loader from $URL"
        exit 1
    }
    
    # --- 2. Download 32-bit Loader (for 64-bit archs) ---
    # This fetches the actual 32-bit binary required for emulation on 64-bit systems
    local LOADER32_ARCH=""
    if [ "$ARCH" == "arm64" ]; then
        LOADER32_ARCH="arm"
    elif [ "$ARCH" == "x86_64" ]; then
        LOADER32_ARCH="x86"
    fi

    if [ -n "$LOADER32_ARCH" ]; then
        local ASSET_NAME_32="libproot-loader-${LOADER32_ARCH}-${VER}.so"
        local URL_32="https://github.com/${LOADER_REPO}/releases/download/${TAG}/${ASSET_NAME_32}"

        echo " -> Downloading 32-bit Loader ($LOADER32_ARCH)..."
        # We rename the downloaded asset to 'libproot-loader32.so'
        curl -L -f -o "${DEST_DIR}/libproot-loader32.so" "$URL_32" || {
             echo "Error: Failed to download 32-bit loader from $URL_32"
             exit 1
        }
    fi
}

build_arch() {
    local ARCH=$1
    echo "==> Building for Architecture: $ARCH"

    # Define paths for this arch
    local ARCH_BUILD_DIR="$BUILD_DIR/$ARCH"
    local STATIC_ROOT="$ARCH_BUILD_DIR/static-root"
    local INSTALL_ROOT="$ARCH_BUILD_DIR/install"
    
    # Clean build dirs
    rm -rf "$ARCH_BUILD_DIR"
    mkdir -p "$STATIC_ROOT" "$INSTALL_ROOT"

    # 1. Setup Environment
    setup_ndk_env "$ARCH" "$ANDROID_API_LEVEL" "$ANDROID_NDK_HOME"

    # 2. Build Talloc (Static)
    echo " -> Building Talloc..."
    cd "$SRC_DIR/talloc-$TALLOC_VERSION"
    
    # Generate answers file for cross-compilation
    generate_talloc_answers "cross-answers-$ARCH.txt"

    # Clean previous builds
    make distclean >/dev/null 2>&1 || true

    ./configure build \
        --prefix="$INSTALL_ROOT" \
        --disable-rpath \
        --disable-python \
        --cross-compile \
        --cross-answers="cross-answers-$ARCH.txt" > /dev/null

    # Build libtalloc.a manually if make install doesn't do it nicely for static
    make -j$(nproc)
    
    # Install headers and libs to STATIC_ROOT for Proot to find
    mkdir -p "$STATIC_ROOT/include" "$STATIC_ROOT/lib"
    ar rcs "$STATIC_ROOT/lib/libtalloc.a" bin/default/talloc*.o
    cp -f talloc.h "$STATIC_ROOT/include"
    
    # 3. Build Proot (Static Only)
    echo " -> Building Proot (Static)..."
    cd "$SRC_DIR/proot/src"
    make distclean >/dev/null 2>&1 || true

    # Common Flags pointing to our local talloc
    export CFLAGS="$CFLAGS -I$STATIC_ROOT/include -Werror=implicit-function-declaration"
    
    # LDFLAGS for Static Build
    export LDFLAGS="-L$STATIC_ROOT/lib -static -ffunction-sections -fdata-sections -Wl,--gc-sections -Wl,-z,max-page-size=16384"
    
    # Unset Loader Variables (Static build does not use external loader)
    unset PROOT_UNBUNDLE_LOADER 
    unset PROOT_UNBUNDLE_LOADER_NAME
    unset PROOT_UNBUNDLE_LOADER_NAME_32
    
    make -j$(nproc) V=1 "PREFIX=$INSTALL_ROOT" install > /dev/null
    
    # Copy the binary to install dir (renaming to generic 'proot')
    cp -a ./proot "$INSTALL_ROOT/bin/proot"
    
    make distclean >/dev/null 2>&1 || true

    # 4. Strip Binaries
    echo " -> Stripping binaries..."
    find "$INSTALL_ROOT/bin" -type f -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true

    # 5. Final Packaging
    local FINAL_OUT="$OUT_DIR/$ARCH"
    
    # Ensure output directory is clean before populating
    rm -rf "$FINAL_OUT"
    mkdir -p "$FINAL_OUT"
    
    # Copy Proot and rename to libproot.so
    echo " -> Packaging artifacts..."
    cp "$INSTALL_ROOT/bin/proot" "$FINAL_OUT/libproot.so"
    
    # Download and Copy Loaders (renames to libproot-loader.so / libproot-loader32.so)
    download_loader "$ARCH" "$FINAL_OUT"
    
    echo "==> Finished $ARCH"
}

# --- Main Execution ---

prepare_sources

for ARCH in $TARGET_ARCHS; do
    build_arch "$ARCH"
done

echo "=========================================="
echo "Build Complete. Artifacts in $OUT_DIR"
echo "=========================================="
ls -R "$OUT_DIR"