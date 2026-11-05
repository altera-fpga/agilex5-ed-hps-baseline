#!/bin/bash
set -e

###############################################################################
# Configuration
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 26.3 ships SD boot only. QSPI packaging returns in a later release (27.1).
# Accept optional "sd" (or BOOT_SOURCE_TYPE=sd) for compatibility with
# hps_baremetal_sd.mk; reject "qspi".
BOOT_SOURCE_TYPE="${1:-${BOOT_SOURCE_TYPE:-sd}}"
if [ "$BOOT_SOURCE_TYPE" = "qspi" ]; then
    echo "ERROR: QSPI boot is not supported in this 26.3 example (deferred)."
    echo "       Use SD:  ./build.sh   or   ./build.sh sd"
    exit 1
fi
if [ "$BOOT_SOURCE_TYPE" != "sd" ]; then
    echo "ERROR: unknown boot source '$BOOT_SOURCE_TYPE' (expected: sd)"
    exit 1
fi
BUILD_DIR="$SCRIPT_DIR/build_sd"

# Default toolchain: repo-local if present, else the internal Linaro install.
# Override by exporting TOOLCHAIN_BIN.
DEFAULT_TOOLCHAIN_BIN=""
if [ -d "$SCRIPT_DIR/gcc-arm/bin" ]; then
    DEFAULT_TOOLCHAIN_BIN="$SCRIPT_DIR/gcc-arm/bin"
elif [ -d "/p/psg/ctools/arm_gnu/linaro/aarch64/14.3/1/bin" ]; then
    DEFAULT_TOOLCHAIN_BIN="/p/psg/ctools/arm_gnu/linaro/aarch64/14.3/1/bin"
fi
TOOLCHAIN_BIN="${TOOLCHAIN_BIN:-$DEFAULT_TOOLCHAIN_BIN}"

###############################################################################
# Build Process
###############################################################################

# Add toolchain to PATH if no aarch64 GCC (linux-gnu or elf) is already found.
if ! command -v aarch64-none-linux-gnu-gcc &>/dev/null && ! command -v aarch64-none-elf-gcc &>/dev/null; then
    if [ -n "$TOOLCHAIN_BIN" ] && [ -d "$TOOLCHAIN_BIN" ]; then
        export PATH="$TOOLCHAIN_BIN:$PATH"
    else
        echo "ERROR: AArch64 GCC toolchain not found (aarch64-none-linux-gnu-gcc or aarch64-none-elf-gcc) and TOOLCHAIN_BIN is not set."
        echo "       Please install an AArch64 cross toolchain and/or export TOOLCHAIN_BIN=/path/to/<toolchain>/bin."
        exit 1
    fi
fi

echo "==========================================================================="
echo " Building: Agilex5 HPS Baremetal (DDR) - boot source: sd"
echo "==========================================================================="

# FPGA SOF used to assemble the boot image. The SOF name is owned by the
# makefile (passed as SOF_PATH / SOF_NAME); nothing board-specific is hardcoded
# here. If SOF_PATH is unset, auto-detect the single design SOF in output_files.
if [ -z "${SOF_PATH:-}" ]; then
    _cands=$(ls "$SCRIPT_DIR/../../../output_files/"*.sof 2>/dev/null | grep -v '_hps_debug\.sof$' || true)
    if [ -n "$_cands" ] && [ "$(echo "$_cands" | wc -l)" -eq 1 ]; then
        SOF_PATH="$_cands"
    fi
fi
# Default SOF_NAME (defaults to SOF_PATH's basename).
SOF_NAME="${SOF_NAME:-$( [ -n "${SOF_PATH:-}" ] && basename "$SOF_PATH" || echo baseline.sof )}"
# Base SOF for the SD FSBL SOF (programmed over JTAG to boot from SD). Defaults
# to the hps_debug variant of SOF_PATH; override with HPS_DEBUG_SOF.
HPS_DEBUG_SOF="${HPS_DEBUG_SOF:-${SOF_PATH%.sof}_hps_debug.sof}"

# Cross toolchain for CMake. FetchContent_MakeAvailable runs the baremetal
# library's CMake during configure, so the compiler must be set on the command
# line below (mirroring the repo's bm_toolchain.cmake: compiler, BM_CROSS_PREFIX
# for the ATF/fiptool cross build, and CMAKE_SIZE).
BM_GCC="$(command -v aarch64-none-linux-gnu-gcc || command -v aarch64-none-elf-gcc || true)"
if [ -z "$BM_GCC" ]; then
    echo "ERROR: no AArch64 GCC (aarch64-none-linux-gnu-gcc / aarch64-none-elf-gcc) on PATH."
    exit 1
fi
BM_GCC_DIR="$(dirname "$BM_GCC")"
BM_PREFIX="$(basename "$BM_GCC")"; BM_PREFIX="${BM_PREFIX%-gcc}"

# Stage the selected example as CMakeLists.txt (what `cmake -S` expects) and
# configure from the build dir; EXAMPLE_ROOT points CMake back at main.c. Drop
# any stale cache so overrides don't require hand-editing CMakeCache.txt.
CMAKE_SRC="$SCRIPT_DIR/CMakeLists_sd.txt"
if [ ! -f "$CMAKE_SRC" ]; then
    echo "ERROR: $CMAKE_SRC not found."
    exit 1
fi
echo ">>> Configuring CMake build system"
mkdir -p "$BUILD_DIR"
cp -f "$CMAKE_SRC" "$BUILD_DIR/CMakeLists.txt"
rm -f "$BUILD_DIR/CMakeCache.txt"
cmake -S "$BUILD_DIR" -B "$BUILD_DIR" -G "Unix Makefiles" \
    -DPLAT=agilex5 \
    -DBUILD_MODE=DDR \
    -DEXAMPLE_ROOT="$SCRIPT_DIR" \
    -DCMAKE_SYSTEM_NAME=Generic \
    -DCMAKE_C_COMPILER="$BM_GCC" \
    -DCMAKE_ASM_COMPILER="$BM_GCC" \
    -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
    -DBM_CROSS_PREFIX="${BM_PREFIX}-" \
    -DCMAKE_SIZE="${BM_GCC_DIR}/${BM_PREFIX}-size" \
    -DCMAKE_BUILD_TYPE=Release

# Build the application + ATF (bl2/bl31), bl2.hex and fip.bin (BL31 + app .bin),
# all driven by CMake.
echo ">>> Building hps_baremetal (ATF + app + FIP)"
cmake --build "$BUILD_DIR" -j"$(nproc)"

# Remove boot images from a previous run so a skipped step below can't leave
# stale outputs for the Makefile to copy out.
rm -f "$BUILD_DIR/hps_baremetal.hps.jic" \
      "$BUILD_DIR/hps_baremetal.hps.sd.img" \
      "$BUILD_DIR/sd_binaries/fsbl_sd.sof"

# -------------------------------------------------------------------------
# SD card image (+ SD FSBL SOF). Uses the SD-variant ATF (generate-sd-fip)
# and the baremetal repo SD tools; sdimage_build.sh auto-loads libguestfs via
# arc. Skipped (with a warning) if the SD tools / guestfish / arc are absent.
# -------------------------------------------------------------------------
# baremetal FetchContent source lives at the default _deps location.
BM_TOOLS_DIR="$BUILD_DIR/_deps/baremetal-src/tools"
SD_BINARIES_DIR="$BUILD_DIR/sd_binaries"

if [ -f "$BM_TOOLS_DIR/make_sdimage.sh" ] && [ -f "$BM_TOOLS_DIR/sdimage_build.sh" ] && { command -v guestfish &>/dev/null || command -v arc &>/dev/null; }; then
    # Build the SD-variant ATF + SD fip.bin (also produces sd_binaries/bl2.hex).
    echo ">>> Building SD ATF + FIP"
    cmake --build "$BUILD_DIR" --target generate-sd-fip -j"$(nproc)"

    echo ">>> Generating SD card image"
    SD_STAGE="$BUILD_DIR/sd_stage"
    rm -rf "$SD_STAGE"
    mkdir -p "$SD_STAGE"
    cp -f "$SD_BINARIES_DIR/fip.bin" "$SD_STAGE/fip.bin"
    cp -f "$BM_TOOLS_DIR/make_sdimage.sh" "$BM_TOOLS_DIR/sdimage_build.sh" "$SD_STAGE/"
    ( cd "$SD_STAGE" && sh sdimage_build.sh )
    cp -f "$SD_STAGE/sd_image.img" "$BUILD_DIR/hps_baremetal.hps.sd.img"
    echo ">>> SD image: $BUILD_DIR/hps_baremetal.hps.sd.img"

    # Assemble the SD FSBL SOF: embed the SD bl2.hex into the SOF as the HPS
    # FSBL (program this over JTAG to boot baremetal from SD). Prefer the
    # hps_debug SOF as the base; fall back to the plain design SOF.
    if [ -f "$HPS_DEBUG_SOF" ]; then
        FSBL_BASE_SOF="$HPS_DEBUG_SOF"
    elif [ -f "$SOF_PATH" ]; then
        FSBL_BASE_SOF="$SOF_PATH"
    else
        FSBL_BASE_SOF=""
    fi
    if [ -n "$FSBL_BASE_SOF" ]; then
        if command -v quartus_pfg &>/dev/null; then
            echo ">>> Generating SD FSBL SOF (base: $(basename "$FSBL_BASE_SOF"))"
            mkdir -p "$SD_BINARIES_DIR"
            ( cd "$SD_BINARIES_DIR" && \
              quartus_pfg -c -o hps_path="$SD_BINARIES_DIR/bl2.hex" "$FSBL_BASE_SOF" fsbl_sd.sof )
        else
            echo "WARNING: quartus_pfg not found; skipping SD FSBL SOF generation."
        fi
    fi
else
    echo "WARNING: SD tools or arc not found; skipping SD image generation."
    echo "         Need the baremetal repo tools/ and either guestfish on PATH or 'arc'."
fi

echo ""
echo "==========================================================================="
echo " Agilex5 HPS Baremetal (DDR) build complete! (boot source: sd)"
echo "==========================================================================="
