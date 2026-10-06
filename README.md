# RD-V3 FVP: DRTM PoC with an EL3 firmware TPM

The TPM is a firmware TPM running in TF-A BL31 (EL3); TF-A also provides the
DRTM service, and the Debian kernel is rebuilt with the DRTM launch support.

## Quick start

### 1. Get the sources

Install dependencies:

```bash
# install repo and xterm with package manager
sudo dnf install xterm repo
sudo apt-get install xterm repo
```

The `pinned-rdv3-drtm.xml` manifest in `infra-refdesign-manifests` is Arm's
`pinned-rdv3.xml` (RD-INFRA-2025.07.03) plus this repository (`drtm-poc`)
and `ms-tpm-20-ref` (with its wolfSSL submodule):

```sh
mkdir rd-infra && cd rd-infra
repo init -u https://github.com/3mdeb/infra-refdesign-manifests -m pinned-rdv3-drtm.xml --depth=1
repo sync -c -j $(nproc) --fetch-submodules --force-sync --no-clone-bundle
```

### 2. Patch tf-a, edk2-platforms and build-scripts

```sh
drtm-poc/scripts/apply-patches.sh
```

This applies `patches/<repo>/` with `git am` onto a local `rdv3-drtm-poc`
branch in each repository (`-c` only checks, `-n` leaves the changes
uncommitted). It skips patches that are already applied, so run it again
after every `repo sync`. See [Sources](#sources) for details.

### 3. Container setup

```bash
./container-scripts/container.sh build
./container-scripts/container.sh -v $PWD/ run
```

### 4. Build the firmware

In the RD-INFRA build container, as for the stock RD-V3 software stack:

```sh
PLAT_ENABLE_EL3_FTPM=1 PLAT_ENABLE_DRTM=1 ./build-scripts/build-test-uefi.sh -p rdv3 all
```

`PLAT_ENABLE_EL3_FTPM=1` adds the EL3 fTPM to TF-A and the TCG2 stack to EDK2.
`PLAT_ENABLE_DRTM=1` adds the DRTM service to TF-A. The fTPM can also be built
on its own, without DRTM.

### 5. Build the Debian image with the DRTM kernel

On a Linux host with docker, in a work directory on a local file system (not
a virtiofs/9p share):

```sh
drtm-poc/scripts/build-drtm-debian-image.sh drtm-image
```

This downloads the Debian 13 nocloud arm64 image and rebuilds its kernel from
the Debian sources with the DRTM patches. It then copies the kernel and the
guest scripts to `/root/drtm-poc` in the image. The script also sets the root
password to `debian` to skip the initial system configuration.

See also [One-shot: Debian image with the DRTM
kernel](#one-shot-debian-image-with-the-drtm-kernel).

### 6. Boot on the FVP

```sh
cd model-scripts/rdinfra
export MODEL=/path/to/FVP_RD_V3/models/Linux64_GCC-9.3/FVP_RD_V3
./distro.sh -p rdv3 -d ../../drtm-image/debian-13-nocloud-arm64-20260914-2601.raw
```

The Debian console is on telnet (telnet port may change per model invocation
if not using headless mode `-j` in `distro.sh` command, check model log to
determine the port). The EDK2 firmware and OS console is on
`terminal_ns_uart0` and TF-A firmware debug log is on `terminal_sec_uart`.

Log in as `root` with the `debian` password. Install the DRTM kernel for the
next boot only, then reboot:

```sh
/root/drtm-poc/install-rebuilt-kernel.sh /root/drtm-poc/vmlinuz-6.12.107+deb13-arm64.drtm drtm
reboot -f
```

The model may not restart. If it does not, simply run the `distro.sh` command
again and connect to telnet:

```sh
# kill existing model process
kill `pgrep FVP_RD_V3`
./distro.sh -p rdv3 -d ../../drtm-image/debian-13-nocloud-arm64-20260914-2601.raw
```

Expected results:

* secure UART: `DRTM service handler: dynamic launch`, then
  `DRTM: fTPM PCR17-22 reset (D-CRTM, locality 4)`;
* kernel log: `DRTM: launch completed`;
* `/sys/class/tpm/tpm0/pcr-sha384/17` and `18` hold the DRTM measurements, and
  the SHA-256 bank of PCR 17/18 stays at zero.

## EL3 fTPM (TF-A BL31, CRB with Arm SMC start method)

The MS TPM 2.0 reference implementation (ms-tpm-20-ref, wolfCrypt backend)
runs inside BL31. The OS uses the standard TCG CRB interface with ACPI TPM2
start method 11: it writes the command into the CRB buffer, sets START and
issues SiP SMC `0x82000200`; BL31 runs the command and clears START.
This is PoC code: the TPM NV state is volatile (re-manufactured on every cold
boot, so EK/SRK change each boot), and entropy falls back to a timer-seeded
PRNG when FEAT_RNG is not implemented.

### Memory layout (`NRD_EL3_FTPM=1`)

| Region             | Base         | Size  | PAS    |
|--------------------|--------------|-------|--------|
| BL31 (moved, incl. fTPM) | `0xF7000000` | 4 MB  | Root   |
| CRB control area   | `0xF7400040` | 0x30  | NS     |
| CRB cmd/rsp buffer | `0xF7401000` | 4 KB  | NS     |

Both regions are in `NRD_CSS_CARVEOUT_RESERVED`, outside the DRAM that
UEFI reports to the OS (ends at `0xF3000000`). BL31 no longer fits in SRAM
(148 KB), so it is linked to and loaded at the DRAM region above.

### ms-tpm-20-ref v1.83 configuration

ms-tpm-20-ref v1.83 expects the integrator to provide `TpmConfiguration`.
`drivers/tpm/ftpm/lib/config/TpmConfiguration/` comes first on the include
path and wraps the upstream headers (`#include_next`):

* `TpmBuildSwitches.h`: no simulator (`SIMULATION`, debug RNG, crypto
  library reporting), no hosted-libc start-up checks, no force-failure test
  hook (it prints to `stderr`), no `FAIL_TRACE`;
* `TpmProfile_Common.h`: the algorithm set of the earlier profile the PoC was
  validated with: no Camellia, ECMQV, SM2, P-192/P-224/P-521/BN-P638 or RSA
  3072/4096.

Upstream also disables `TPM2_CertifyX509` by default (`CC_CertifyX509`).

### Sources

```sh
ms-tpm-20-ref  ee21db0a941decd3cac67925ea3310873af60ab3 (main, TPM 2.0 v1.83)
  external/wolfssl  9c87f979a7f1d3a6d786b260653d566c1d31a1c4 (submodule)
tf-a           RD-INFRA-2025.07.03 + patches/tf-a/            (9 patches)
edk2-platforms RD-INFRA-2025.07.03 + patches/edk2-platforms/  (4 patches)
build-scripts  RD-INFRA-2025.07.03 + patches/build-scripts/   (1 patch)
```

The patch series are `git format-patch` output on top of the revisions the
RD-V3 manifest pins. In a repo checkout that also has `drtm-poc` and
`ms-tpm-20-ref` (top level, next to `tf-a`), apply them with:

```sh
drtm-poc/scripts/apply-patches.sh        # git am onto a local rdv3-drtm-poc branch
drtm-poc/scripts/apply-patches.sh -c     # check only (temporary worktrees)
drtm-poc/scripts/apply-patches.sh -n     # working trees only, no commits
```

Patches whose subject is already in the branch history are skipped, so it
can be run again after `repo sync`. The repositories must not have
uncommitted changes. Without a git identity, the committer is set to
`drtm-poc` (`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` override it).

To refresh a series after changing a repository, commit on the
`rdv3-drtm-poc` branch and run e.g.
`git -C tf-a format-patch -o ../drtm-poc/patches/tf-a RD-INFRA-2025.07.03`
(remove the old files first).

Without repo:

```sh
git clone https://github.com/microsoft/ms-tpm-20-ref
git -C ms-tpm-20-ref checkout ee21db0a941decd3cac67925ea3310873af60ab3
git -C ms-tpm-20-ref submodule update --init external/wolfssl
```

### Build (in the rdinfra container)

```sh
PLAT_ENABLE_EL3_FTPM=1 ./build-scripts/build-test-uefi.sh -p rdv3 all
```

This passes `NRD_EL3_FTPM=1` to TF-A and `-D EDK2_ENABLE_EL3_FTPM=TRUE`
to EDK2. On the EDK2 side that adds:

* the TPM2 ACPI table and an `MSFT0101` device (`TPM0`) for the OS,
* `Tpm2DeviceLibCrbSmc` (SgiPkg), the TPM2 device library for the CRB/SMC
  interface, and the CRB pages in the PEI/DXE MMU map,
* the TCG2 stack (`SgiPkg/El3Ftpm.dsc.inc`): El3FtpmConfigPei (TPM 2.0
  device selection, replaces Tcg2ConfigPei which defaults to TPM 1.2), Tcg2Pei
  (TPM2_Startup, firmware measurements), Tcg2Dxe (EFI_TCG2_PROTOCOL, event
  log handed to Linux) and Tcg2ConfigDxe (Device Manager > TCG2
  Configuration).

`PcdTpm2HashMask` is `0x6` (SHA256/SHA384) and only those hash instances
are linked: the fTPM supports SHA-1 too but only allocates SHA-256 and SHA-384
(the ms-tpm-20-ref default since v1.83). With `0x7` Tcg2Pei keeps the SHA-1
bit (it only drops algorithms the TPM does not support), so every event is
also hashed with SHA-1 and that digest is dropped with "Event log has HashAlg
unsupported by PCR bank (0x4)". Do not change the PCR banks in the TCG2 menu: Tcg2Pei would
reallocate them and reset, and with volatile TPM state that loops forever.
Measured boot: `DxeTpm2MeasureBootLib` in SecurityStubDxe measures loaded
PE/COFF images (PCR 2/4) and the GPT (PCR 5); `DxeTpmMeasurementLib`
lets other DXE drivers log measurements. TCG2 physical presence requests
from the TCG2 menu are not processed (ArmPkg PlatformBootManagerLib does not
call Tcg2PhysicalPresenceLibProcessRequest).

### Test

No kernel rebuild is needed: the Debian 6.12 kernel has `CONFIG_TCG_CRB=y`.

* Secure UART: `fTPM: initialising, CRB at 0xf7400000` and
  `fTPM: ready (PoC, volatile NV)` during BL31 setup.
* Linux: `/dev/tpm0` and `/dev/tpmrm0`;

---

# DRTM (TF-A BL31)

`PLAT_ENABLE_DRTM=1` builds TF-A with `DRTM_SUPPORT=1` (experimental in TF-A).
Use it together with `PLAT_ENABLE_EL3_FTPM=1`:

```sh
PLAT_ENABLE_EL3_FTPM=1 PLAT_ENABLE_DRTM=1 ./build-scripts/build-test-uefi.sh -p rdv3 all
```

RD-V3 platform hooks (`plat/arm/board/neoverse_rd/platform/rdv3/rdv3_drtm.c`):

* address map: DLME/arguments must be in NS DRAM1 (`0x80000000`-`0xF4000000`)
  or DRAM2 (`0x8080000000`, 6 GB); the DRTM address map is the BL31 mmap;
* DMA protection: complete protection only, over the four PCIe IO
  virtualization SMMUs (`0x280000000 + n * 0x8000000`). PoC: the FVP RoS
  virtio-mmio devices are not behind an SMMU and are not reported;
* TPM features: firmware hashing with the Event Log algorithm. With
  `NRD_EL3_FTPM=1` it defaults to SHA-384 (`MBOOT_TPM_HASH_ALG ?= sha384`,
  DEN0113 R48000: SHA-384 is required when the TPM implements it); override
  with `MBOOT_TPM_HASH_ALG=sha256`. The DRTM Event Log buffer is 2 KB;
  `plat/arm/common/arm_common.mk` now includes `event_log.mk` before the
  TRUSTED_BOARD_BOOT mbedTLS makefiles. Before this, `mbedtls_common.mk` ran
  before `MBOOT_EL_HASH_ALG` was set, so mbedTLS only had the TBB hash
  (SHA-256) and the first DRTM measurement failed with `CRYPTO_ERR_HASH` (rc=2);
* errors: kept in RAM (lost on cold boot); remediation resets via SCMI.

fTPM wiring: the DRTM core calls two new weak hooks
(`plat_drtm_tpm_reset_pcrs`, `plat_drtm_tpm_extend`). On RD-V3:

* reset: `TPM2_PCR_Reset` is never allowed at locality 4 for the DRTM PCRs
  (`TPM_RC_LOCALITY`, 0x907). The TCG model resets them with the locality 4
  `_TPM_Hash_Start`/`_TPM_Hash_End` sequence, so BL31 calls the fTPM
  directly (`ftpm_drtm_reset_pcrs()`, i.e. what `_TPM_Hash_End()` does
  before its extend: `PCRResetDynamics()`, PCR 17-22 to zero);
* extend: every DRTM Event Log digest is extended at locality 4 into the
  bank of the firmware hash algorithm advertised in the DRTM TPM features
  (`plat_drtm_get_tpm_features()`, SHA-384 on RD-V3), which is also the
  Event Log algorithm (`ftpm_drtm_extend()`). The launch fails if that bank
  is not allocated. That bank of PCR 17/18 equals a replay of the DRTM Event
  Log from zero; the other banks stay at zero after the reset. The OS at
  locality 0 can neither reset nor extend them.

Expected on the secure UART after a dynamic launch:
`DRTM: fTPM PCR17-22 reset (D-CRTM, locality 4)`.

---

# Debian 13 kernel rebuilt from Debian sources

`scripts/build-debian-kernel.sh` rebuilds the kernel image of
`linux-image-6.12.107+deb13-arm64` (Debian 6.12.107-1) in a `debian:trixie`
container: Debian source package with all Debian patches, the installed
`/boot/config-6.12.107+deb13-arm64`, Debian's `aarch64-linux-gnu-gcc-14`,
`KERNELRELEASE=6.12.107+deb13-arm64`. Only the Image is built; the installed
modules and initrd are reused.

```sh
scripts/extract-debian-kernel-cert.sh <debian vmlinuz> <work>/debian-builtin-certs.pem
scripts/build-debian-kernel.sh <work> <debian config> [patch-dir]
```

* The installed modules are signed with the Debian build-time key; its
  certificate (extracted from the Debian vmlinuz) is built into the rebuilt
  kernel, so signatures still verify.
* Check: all 11880 vmlinux exports have the same CRCs as Debian's
  `Module.symvers` (`linux-headers-6.12.107+deb13-arm64`).
* The only config differences to the installed config are the entries Debian
  strips from it (`BUILD_SALT`, `MODULE_SIG_ALL`, `MODULE_SIG_KEY`,
  `SYSTEM_TRUSTED_KEYS`).
* `patch-dir` applies extra patches (e.g. DRTM) on top; keep them free of
  changes to exported symbols or structures used by modules.

Install in the guest with `guest/install-rebuilt-kernel.sh` (adds a
`6.12.107+deb13-arm64.rebuilt` GRUB entry and boots it once).

---

# Kernel DRTM (NVIDIA arm64_drtm series, backported to Debian 6.12)

Source: https://github.com/jgunthorpe/linux/commits/arm64_drtm (16 patches
on Linux 7.3-rc2: EFI stub DRTM launch, `drtm_entry` DLME entry point,
UNPROTECT_MEMORY). Backport in `kernel/drtm-patches/` (apply on top of the
Debian 6.12.107-1 source):

* zboot parts dropped (patch 06, zboot hunks of 07 and 10): Debian arm64 is
  a plain `Image`;
* 6.12 context fixes (`screen_info`, linker script), missing helpers
  (`BIT_U32/U64`, `efi_pool` cleanup, `TPM_ALG_*`), binutils 2.44 linker
  script syntax (`sym = .;`, `;` after in-section `ASSERT`);
* RD-V3: accept DRTM interface 1.0, as reported by TF-A (its DRTM service
  already handles revision 2 parameters, the FEATURES encodings and launch
  features the stub uses).

Build: `ARM64_DRTM=y` on top of the Debian config (CRCs still identical to
Debian's), default policy `auto` (`drtm=off|auto|enforce` overrides).

```sh
SRC=linux-drtm EXTRA_CONFIG="ARM64_DRTM=y EFI_STUB_DRTM_DEFAULT_OFF=n EFI_STUB_DRTM_DEFAULT_AUTO=y" \
	OUT_SUFFIX=.drtm scripts/build-debian-kernel.sh <work> <debian config>
```

Install in the guest: `install-rebuilt-kernel.sh /root/drtm-poc/vmlinuz-6.12.107+deb13-arm64.drtm drtm`.
Firmware: `PLAT_ENABLE_EL3_FTPM=1 PLAT_ENABLE_DRTM=1`.

Expected: UEFI console `EFI stub: DRTM: interface version 1.0`; secure UART
`DRTM service handler: dynamic launch` and
`DRTM: fTPM PCR17-22 reset (D-CRTM, locality 4)`; kernel `DRTM: launch completed`;
PCR 17/18 (sha384) in `/sys/class/tpm/tpm0/pcr-sha384/17` and `18` no
longer all `FF`/`00`.

DMA protection undo: upstream `drtm_dma_prot_disengage()` always entered
remediation ("cannot undo PROTECT_MEM_ALL SMMU config"), so any launch
failure after DMA protection was engaged reset the platform. It now saves
each SMMU's `SMMU_GBPA` and `SMMU_CR0.SMMUEN` before setting abort-all and
restores them on failure (`smmuv3_ns_save/restore_abort_state()`), so the
launch returns the error to the caller (with `drtm=auto` the stub then boots
normally). Remediation is only entered if the restore itself fails.

DLME image mapping: `drtm_take_measurements()` maps the DLME image from its
PA rounded down to 2 MB. The image start is usually only 64 KB aligned
(Linux `_stext`); mapping it at the 2 MB aligned VA chosen by
`mmap_add_dynamic_region_alloc_va()` forced 4 KB pages for the whole image
(one level 3 table per 2 MB, ~19 tables for the Debian kernel) and failed
with `-ENOMEM`. With congruent VA/PA, 2 MB blocks are used and only the ends
need level 3 tables.

---

# One-shot: Debian image with the DRTM kernel

`scripts/build-drtm-debian-image.sh [work-dir]` runs all of the steps above in
one go, without root (the image is edited with `debugfs -w`):

1. downloads the Debian 13 nocloud arm64 image and verifies it against
   SHA512SUMS. `IMAGE_VERSION` selects the build: the default `20260914-2601`
   ships 6.12.107+deb13-arm64, and `latest` ships a newer 6.12.y on which the
   patches may need a refresh;
2. reads the kernel release from `/boot/config-*` and the Debian source
   version from the dpkg status, and dumps the config and vmlinuz;
3. extracts the module signing certificate from vmlinuz;
4. downloads the Debian source package from deb.debian.org, then the
   security archive, then snapshot.debian.org;
5. applies `kernel/drtm-patches` and rebuilds the Image with `ARM64_DRTM=y`
   (`build-debian-kernel.sh`);
6. checks the exported symbol CRCs against `Module.symvers` from the matching
   `linux-headers` package;
7. writes the kernel and the guest scripts to `/root/drtm-poc` in the image.
   `INSTALL=default` also replaces `/boot/vmlinuz-<krel>` and keeps the Debian
   kernel as `/boot/vmlinuz-<krel>.debian`;
8. preseeds the first boot (`scripts/configure-image.sh`). The nocloud image
   has a locked root account, and on its first boot systemd-firstboot prompts
   for the keymap, timezone and root password. The script sets the root
   password (`ROOT_PASSWORD`, default `debian`) and, if they are missing, the
   keymap (`KEYMAP`, default `us`) and the timezone (`TIMEZONE`, default
   `Etc/UTC`), so nothing is asked. `ROOT_PASSWORD=` leaves the account locked.
   `configure-image.sh <image.raw>` also works on its own, on any Debian cloud
   raw image.

Both scripts edit the image with `debugfs`, which ignores the ext4 journal. If
the image was not shut down cleanly (for example, the FVP was killed after a
boot), the kernel would replay the journal over those edits on the next boot
and corrupt the file system ("EXT4-fs error ... deleted inode referenced").
The scripts therefore check the root file system first. If it needs journal
recovery, or has errors, it is repaired with `e2fsck -p` in a temporary copy
next to the image (it needs up to 3 GB of free space) and written back. If
`e2fsck -p` cannot repair it, the image is left unchanged; use a fresh image
(delete it and the script downloads it again) or run `e2fsck -f` on it by
hand.

```sh
scripts/build-drtm-debian-image.sh drtm-image
# guest: /root/drtm-poc/install-rebuilt-kernel.sh /root/drtm-poc/vmlinuz-6.12.107+deb13-arm64.drtm drtm
```

Other options: `IMAGE=<raw>` (use an existing image), `PATCHES=` (plain
rebuild), `EXTRA_CONFIG`, `OUT_SUFFIX`, `JOBS`, `SKIP_CRC_CHECK=1`.

Use a work directory on a local file system: the kernel build creates about
80k files, which can exhaust the host file handles of a virtiofs/9p share
("Too many open files in system").
