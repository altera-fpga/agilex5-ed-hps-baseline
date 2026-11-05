# HPS Baremetal Hello World Example Design (DDR)

The HPS Baremetal Hello World Example Design showcases a minimal, bare-metal
application running on the Agilex 5 HPS. The program uses baseline-a55
as the hardware design and runs the following actions:

1. Initialize the UART (115200 baud) for console output
2. Initialize the clock manager
3. Initialize the GIC for interrupt handling
4. Print platform and version information
5. Continuously print a "Hello World" message once per second

This variant targets the **DDR** memory layout (`BUILD_MODE=DDR`): the
application is linked to execute from DDR. At boot, ATF (BL31) loads the
application into DDR and hands off control to it, rather than the application
running directly from the HPS on-chip RAM.

# Boot source (SD)

This 26.3 example supports **SD card boot only**. QSPI packaging is deferred to
a later release.

| Boot source | CMake file        | Make target                        | Produces                                                    |
| ----------- | ----------------- | ---------------------------------- | ----------------------------------------------------------- |
| SD          | `CMakeLists_sd.txt` | `software-hps_baremetal_sd-build-sw` | `baremetal.elf`, `baremetal.hps.sd.img`, `fsbl_sd.sof` |

`build.sh` stages `CMakeLists_sd.txt` into the build directory as
`CMakeLists.txt` and configures from there:

```bash
./build.sh        # SD (default)
./build.sh sd     # same
```

The ATF build machinery lives in the baremetal repo (`cmake/bm_boot.cmake`) and
provides the `atf-bl2-bl31-sd` / `atf-fiptool` targets that `CMakeLists_sd.txt`
wires into a `fip.bin`.

## SD

The SD flow uses the SD-variant ATF (`atf-bl2-bl31-sd`, built with
`MMC_DEVICE_TYPE=SD`) and the SD packaging scripts shipped in the baremetal repo
(`tools/make_sdimage.sh`, `tools/sdimage_build.sh`) to produce a bootable SD card
image (`baremetal.hps.sd.img`). This requires `guestfish` (from
[libguestfs](https://libguestfs.org/)) to be installed and on your `PATH`. It
also produces an SD FSBL SOF (`fsbl_sd.sof`, embedding the SD `bl2.hex`) - the
SOF programmed over JTAG to boot the baremetal from the SD card. If the SD tools
or `guestfish` are unavailable, the SD image step is skipped with a warning (the
ELF still builds).

# Build Steps

1. Enter the baseline-a55 folder

```bash
cd TOP_DIR/dk-a5e065ab32aea-enablement/baseline-a55
```

2. Build the baremetal application (SD boot)

```bash
make software-hps_baremetal_sd-build-sw
```

The artifacts (`baremetal.elf`, plus `baremetal.hps.sd.img` and `fsbl_sd.sof`
when SD packaging succeeds) appear under
`software/hps_baremetal/baremetal_ddr/` when building via the Make target (it
copies them from the `build_sd/` directory). The target depends on the FPGA SOF
(`output_files/<revision>.sof`), so the FPGA is compiled first.

(Note: you can also run `./software/hps_baremetal/baremetal_ddr/build.sh`
directly. Override the SOF with `SOF_PATH=/path/to.sof ./build.sh`.)

3. (Optional) Install the binary + boot image into the enablement output tree

```bash
make software-hps_baremetal_sd-install-sw
```

This step is only needed for the full baseline enablement/packaging flow; it
copies the produced artifacts into the shared output tree where downstream steps
collect software binaries. Skip it if you only need the artifacts locally.

4. Clean the build artifacts

```bash
make software-hps_baremetal_sd-clean-sw
```

# Toolchain

The build requires an AArch64 GCC cross toolchain. `build.sh` accepts either
the `aarch64-none-linux-gnu` or `aarch64-none-elf` GCC. If neither is already
on your `PATH`, the script falls back to a repo-local vendored toolchain
(`gcc-arm/bin`) if present. The toolchain can be downloaded from the
[Arm GNU Toolchain downloads page](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads).

You can point the build at a specific toolchain by exporting `TOOLCHAIN_BIN`
before building:

```bash
export TOOLCHAIN_BIN=/path/to/<toolchain>/bin
make software-hps_baremetal_sd-build-sw
```

The cross-compile setup lives in the baremetal repo
(`cmake/bm_toolchain.cmake`) and is included before `project()`, so a single
CMake configure pass is sufficient. The baremetal library and ATF source are
fetched automatically via CMake `FetchContent` during configuration.
