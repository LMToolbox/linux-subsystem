#!/bin/bash

# --- Sources ---
# Talloc Version
export TALLOC_VERSION="2.4.3"

# Proot: Can be a branch name (master) or a specific Commit Hash
export PROOT_REF="master"

# Termux Loader Tag (from termux-play-store/termux-packages)
export LOADER_TAG="proot-2025.10.04-r1::5.1.107-67"
# The GitHub User/Repo for the loader
export LOADER_REPO="termux-play-store/termux-packages"

# Termux ELF Cleaner (Used to fix linker warnings on older Androids)
export ELF_CLEANER_REPO="termux/termux-elf-cleaner"
export ELF_CLEANER_TAG="v3.0.1" # Check for latest version

# --- Android Configuration ---
export ANDROID_API_LEVEL="24"
# Architectures to build
export TARGET_ARCHS="arm arm64 x86_64"

# --- Directories ---
export BUILD_DIR="${PWD}/build"
export SRC_DIR="${PWD}/src"
export OUT_DIR="${PWD}/out"
export PATCH_DIR="${PWD}/patches"
