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

    # 3. Download Termux ELF Cleaner (For fixing linker warnings)
    if [ ! -d "$SRC_DIR/termux-elf-cleaner" ]; then
        echo " -> Cloning Termux ELF Cleaner ($ELF_CLEANER_TAG)..."
        git clone https://github.com/${ELF_CLEANER_REPO}.git "$SRC_DIR/termux-elf-cleaner"
        cd "$SRC_DIR/termux-elf-cleaner"
        git checkout "$ELF_CLEANER_TAG"
        cd - > /dev/null
    fi
}

compile_host_tools() {
    echo "==> Compiling Host Tools (Alpine Native)..."
    
    # Check if we already built the cleaner
    if [ -f "$SRC_DIR/termux-elf-cleaner/termux-elf-cleaner" ]; then
        echo " -> termux-elf-cleaner already built."
        return
    fi

    echo " -> Building termux-elf-cleaner..."
    cd "$SRC_DIR/termux-elf-cleaner"
    
    # Since we are on Alpine, ensure g++ and make are installed
    apk add build-base git
    
    # We compile for the HOST (Alpine), not Android
    # We avoid the Makefile to ensure we don't accidentally pick up NDK flags if they are exported
    g++ -std=c++11 -Wall -Wextra -pedantic -O3 termux-elf-cleaner.cpp -o termux-elf-cleaner

    if [ ! -f "termux-elf-cleaner" ]; then
        echo "Error: Failed to compile termux-elf-cleaner"
        exit 1
    fi
    cd - > /dev/null
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

    # --- Normalize Architecture Name ---
    local LOADER_ARCH="$ARCH"
    if [ "$ARCH" == "arm64" ]; then LOADER_ARCH="aarch64"; fi

    # --- 1. Download Main Loader ---
    local ASSET_NAME="libproot-loader-${LOADER_ARCH}-${VER}.so"
    local URL="https://github.com/${LOADER_REPO}/releases/download/${TAG}/${ASSET_NAME}"

    echo " -> Downloading Main Loader ($LOADER_ARCH)..."
    curl -L -f -o "${DEST_DIR}/libproot-loader.so" "$URL" || {
        echo "Error: Failed to download loader from $URL"
        exit 1
    }
    
    # --- 2. Download 32-bit Loader (Only for 64-bit archs) ---
    if [ "$ARCH" == "arm64" ] || [ "$ARCH" == "x86_64" ]; then
        local ASSET_NAME_32="libproot-loader32-${LOADER_ARCH}-${VER}.so"
        local URL_32="https://github.com/${LOADER_REPO}/releases/download/${TAG}/${ASSET_NAME_32}"

        echo " -> Downloading 32-bit Loader (loader32 for $LOADER_ARCH)..."
        curl -L -f -o "${DEST_DIR}/libproot-loader32.so" "$URL_32" || {
             echo "Error: Failed to download 32-bit loader from $URL_32"
             exit 1
        }
    else
        echo " -> Skipping 32-bit loader (not required for $ARCH)"
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
    
    generate_talloc_answers "cross-answers-$ARCH.txt"
    make distclean >/dev/null 2>&1 || true

    ./configure build \
        --prefix="$INSTALL_ROOT" \
        --disable-rpath \
        --disable-python \
        --cross-compile \
        --cross-answers="cross-answers-$ARCH.txt" > /dev/null

    make -j$(nproc)
    
    mkdir -p "$STATIC_ROOT/include" "$STATIC_ROOT/lib"
    ar rcs "$STATIC_ROOT/lib/libtalloc.a" bin/default/talloc*.o
    cp -f talloc.h "$STATIC_ROOT/include"
    
    # 3. Build Proot
    echo " -> Building Proot..."
    cd "$SRC_DIR/proot/src"
    make distclean >/dev/null 2>&1 || true

    export CFLAGS="-I$STATIC_ROOT/include -Werror=implicit-function-declaration"      
    export LDFLAGS="-L$STATIC_ROOT/lib -Wl,-z,max-page-size=16384"
    
    export PROOT_UNBUNDLE_LOADER='.'
    export PROOT_UNBUNDLE_LOADER_NAME='libproot-loader.so'
    export PROOT_UNBUNDLE_LOADER_NAME_32='libproot-loader32.so'

    make -j$(nproc) V=1 "PREFIX=$INSTALL_ROOT" install > /dev/null
    
    # Copy binary to install location
    cp -a ./proot "$INSTALL_ROOT/bin/proot"
    make distclean >/dev/null 2>&1 || true

    # 4. Clean ELF Header (Fixes Android 7 linker warnings)
    echo " -> Running termux-elf-cleaner..."
    # We run the tool built in compile_host_tools
    "$SRC_DIR/termux-elf-cleaner/termux-elf-cleaner" \
        --api-level "$ANDROID_API_LEVEL" \
        "$INSTALL_ROOT/bin/proot" || {
            echo "Error: termux-elf-cleaner failed"
            exit 1
        }

    # 5. Strip Binaries
    echo " -> Stripping binaries..."
    find "$INSTALL_ROOT/bin" -type f -exec "$STRIP" --strip-unneeded {} \; 2>/dev/null || true

    # 6. Packaging
    local ABI_DIR="$ARCH"
    if [ "$ARCH" == "arm64" ]; then ABI_DIR="arm64-v8a"; fi
    if [ "$ARCH" == "arm" ]; then ABI_DIR="armeabi-v7a"; fi
    
    local FINAL_OUT="$OUT_DIR/$ABI_DIR"
    rm -rf "$FINAL_OUT"
    mkdir -p "$FINAL_OUT"
    
    echo " -> Packaging artifacts into $ABI_DIR..."
    cp "$INSTALL_ROOT/bin/proot" "$FINAL_OUT/libproot.so"
    download_loader "$ARCH" "$FINAL_OUT"
    
    echo "==> Finished $ARCH"
}

# --- Main Execution ---

prepare_sources
compile_host_tools  # <--- Build the cleaner on the Alpine host first

for ARCH in $TARGET_ARCHS; do
    build_arch "$ARCH"
done

echo "=========================================="
echo "Build Complete. Artifacts in $OUT_DIR"
echo "=========================================="
ls -R "$OUT_DIR"
