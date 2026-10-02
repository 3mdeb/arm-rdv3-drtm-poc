# fTPM + Arm DRTM on the RD-V3 FVP: PoC summary

Goal: run an Arm DRTM (DEN0113 1.1) dynamic launch of the Debian 13 kernel on
the Neoverse RD-V3 FVP, measured into a TPM. There is no TPM on the FVP, so the
PoC adds a firmware TPM first.

Status: a dynamic launch of the rebuilt Debian 6.12.107 kernel works on the
FVP. PCR 17/18 are reset and extended at locality 4, and Linux reads them
through `/sys/class/tpm/tpm0/pcr-sha384/{17,18}`. This is **PoC quality and not secure** (see the gaps below).

Deliverables are in `drtm-poc/` (patches, kernel images, scripts, `README.md`
with build and test steps).

---

## 1. What was done

### 1.1 Firmware TPM in TF-A BL31 (EL3)

* The OP-TEE fTPM (S-EL1 SP under Hafnium) was tried first. It was replaced by
  an fTPM in BL31, which is simpler for DRTM: the D-CRTM and the TPM are in the
  same image, so locality 4 is reached by a direct call. The OP-TEE code has
  been removed completely.
* `tf-a/drivers/tpm/ftpm/`: Microsoft `ms-tpm-20-ref` (main `ee21db0`, TPM 2.0
  v1.83) with the wolfCrypt backend (9c87f979) through TpmBigNum, built as
  `libftpm.a` and linked into BL31. Our own `TpmConfiguration` overrides
  (`lib/config/`) turn off the simulator switches and keep the algorithm set
  of the earlier profile.
  Compat headers, a first-fit heap and a dedicated 256 KB stack
  (`ftpm_stack_call`) are provided for the reference code.
* Interface to the OS: TCG CRB with the Arm SMC start method (ACPI TPM2 start
  method 11). The control area is at `0xF7400040` and the command/response
  buffer at `0xF7401000`. The OS sets START and calls SiP SMC `0x82000200`
  (`ARM_SIP_FTPM_CRB_START`, non-secure callers only), then BL31 runs the
  command.
* BL31 no longer fits in SRAM, so with the fTPM it is linked to DRAM at
  `0xF7000000` (4 MB, Root PAS), inside `NRD_CSS_CARVEOUT_RESERVED`.
* NV state is volatile. Every cold boot calls `TPM_Manufacture()`, so the
  EK/SRK change on each boot. Entropy comes from FEAT_RNG if present, otherwise
  from a timer-seeded PRNG.
* Banks: SHA-1, SHA-256 and SHA-384 are supported, and SHA-256 and SHA-384
  are allocated (the upstream default since v1.83). EDK2 uses
  `PcdTpm2HashMask = 0x6` (SHA-256 | SHA-384) to match.
* Build option: `PLAT_ENABLE_EL3_FTPM=1` (build-scripts), which passes
  `NRD_EL3_FTPM=1` to TF-A and `-D EDK2_ENABLE_EL3_FTPM=TRUE` to EDK2.

### 1.2 EDK2 (edk2-platforms SgiPkg)

* ACPI: TPM2 table (start method 11) and SSDT `MSFT0101` device `TPM0`.
* `Tpm2DeviceLibCrbSmc`: the TPM2 device library for CRB+SMC. The CRB pages are
  mapped as device memory in PEI/DXE.
* TCG2 stack: `El3FtpmConfigPei` (a replacement for `Tcg2ConfigPei`, which
  defaulted to TPM 1.2), `Tcg2Pei`, `Tcg2Dxe` and `Tcg2ConfigDxe` (the TCG2
  Configuration menu). `PcdTpm2HashMask = 0x6` (SHA-256 | SHA-384).
* Measured boot: `DxeTpm2MeasureBootLib` in SecurityStubDxe (PE/COFF images go
  to PCR 2/4, the GPT to PCR 5) and `DxeTpmMeasurementLib`. The TCG event log is
  handed to Linux.
* Not done: TCG2 physical presence requests are not processed, and changing PCR
  banks in the menu loops forever because the TPM state is volatile.

### 1.3 TF-A DRTM service on RD-V3

* Build option: `PLAT_ENABLE_DRTM=1`, which passes `DRTM_SUPPORT=1`. It is used
  together with `PLAT_ENABLE_EL3_FTPM=1`.
* Platform hooks in `plat/arm/board/neoverse_rd/platform/rdv3/rdv3_drtm.c`.
  Before this they existed only for FVP Base.
  * Address map / region validation: the DLME and parameters must be in NS
    DRAM1 (`0x80000000`-`0xF4000000`) or DRAM2 (`0x8080000000`, 6 GB).
  * DMA protection: complete protection only, by setting abort-all (GBPA) on
    the four PCIe IO-virtualization SMMUv3 instances
    (`0x280000000 + n*0x8000000`).
  * TPM features: firmware hashing (no TPM-based hashing), algorithm =
    Event Log algorithm, default PCR schema. With the fTPM the algorithm
    defaults to SHA-384 (`MBOOT_TPM_HASH_ALG ?= sha384` in the RD-V3
    `platform.mk`, overridable on the command line).
  * Errors: kept in RAM. Remediation resets the platform via SCMI
    (`css_scp_sys_reboot()`).
  * Sizing: event log 0x800 bytes (room for 48-byte digests), extra mmap/xlat entries, DRTM stack.
* fTPM wiring. Two new weak hooks are called by the DRTM core:
  * `plat_drtm_tpm_reset_pcrs()` calls `ftpm_drtm_reset_pcrs()`, which runs
    `PCRResetDynamics()` at locality 4. This resets PCR 17-22, the same thing
    `_TPM_Hash_End` does. `TPM2_PCR_Reset` returns `TPM_RC_LOCALITY` (0x907)
    for these PCRs.
  * `plat_drtm_tpm_extend(pcr, digest, size)` calls `ftpm_drtm_extend()`, which
    extends at locality 4 only the bank given by the DRTM TPM features'
    firmware hash algorithm (SHA-384). The launch fails if that bank is not
    allocated or the digest size does not match. The SHA-256 bank of
    PCR 17/18 stays at zero.
* Fixes in the upstream (experimental) DRTM code:
  * DMA protection undo. `drtm_dma_prot_disengage()` always went into
    remediation ("cannot undo PROTECT_MEM_ALL SMMU config"). It now saves and
    restores each SMMU's `GBPA` and `CR0.SMMUEN`
    (`smmuv3_ns_save/restore_abort_state()`), so a failed launch returns an
    error to the caller instead of resetting the platform.
  * DLME image mapping returned `-ENOMEM`. The image is now mapped from its PA
    rounded down to 2 MB, so VA and PA are congruent and 2 MB blocks are used.
    Before this, a 64 KB-aligned `_stext` forced 4 KB pages for the whole image
    and used up the translation tables.

### 1.4 Linux (Debian 13, 6.12.107+deb13-arm64)

* `scripts/build-debian-kernel.sh` rebuilds only the `Image` from the Debian
  source package in a `debian:trixie` container, using the installed config and
  `KERNELRELEASE`. The installed modules and initrd keep working:
  * all 11880 export CRCs match Debian's `Module.symvers`;
  * the Debian build-time module-signing certificate (extracted from the
    original vmlinuz) is built in, so module signatures still verify.
* DRTM launch: NVIDIA's `jgunthorpe/linux arm64_drtm` series (EFI stub launch,
  `drtm_entry` DLME entry point, `UNPROTECT_MEMORY`) was backported to 6.12 in
  `kernel/drtm-patches/0001-0019`:
  * the zboot parts were dropped (Debian uses a plain `Image`);
  * 6.12 context fixes and missing helpers;
  * binutils 2.44 linker-script syntax fixes;
  * DRTM interface 1.0 (what TF-A reports) is accepted in addition to 1.1.
* Config: `ARM64_DRTM=y`, default policy `auto` (`drtm=off|auto|enforce`).
* Guest helpers: `guest/install-rebuilt-kernel.sh` (one-shot GRUB entry) and
  `guest/check-ftpm.sh` (ACPI/CRB, TPM device, PCR 17/18 per bank, event log).

### 1.5 Verified results

* `/dev/tpm0` and `/dev/tpmrm0` work. TPM2_GetRandom works, and PCRs are
  readable from sysfs.
* The TCG2 menu works in UEFI, and the firmware event log is visible in Linux.
* Dynamic launch on the FVP: `DRTM: launch completed` in the kernel, and
  PCR 17/18 are no longer all `FF`/`00`.
* Single-bank SHA-384 extend on ms-tpm-20-ref v1.83: TF-A builds, and BL31
  reports algorithm `0x000C` and extends 48-byte digests. On the host fTPM test
  the SHA-384 bank equals the expected replay, SHA-256 stays zero, and a bad
  size or unallocated bank is rejected.

---

## 2. Gaps against DEN0113 1.1

Legend: **Missing** = not implemented. **Partial** = implemented in part or
for PoC only. **PoC deviation** = done in a way the spec does not allow.

### 2.1 Interface functions (chapter 3)

| Function | Status |
|---|---|
| `DRTM_VERSION` | Reports **1.0**, while the spec is 1.1. The kernel was patched to accept 1.0. |
| `DRTM_FEATURES` | Implemented (TPM, memory requirements, DMA protection, boot PE, TCB hashes, DLME image auth). |
| `DRTM_UNPROTECT_MEMORY` | Implemented. For complete protection it restores the saved SMMU state. |
| `DRTM_DYNAMIC_LAUNCH` | Implemented (see 2.2-2.4 for gaps). |
| `DRTM_CLOSE_LOCALITY` (3.6) | **Missing** (returns `NOT_SUPPORTED`). |
| `DRTM_GET_ERROR` / `DRTM_SET_ERROR` | Implemented, but the value is in RAM only (see 2.5). |
| `DRTM_SET_TCB_HASH` / `DRTM_LOCK_TCB_HASHES` (3.9/3.10) | **Missing** (`NOT_SUPPORTED`). The TCB hash table in the DLME data is empty (size 0). |
| DLME image authentication feature | **Missing** (reported unsupported). |
| Region-based DMA protection | **Missing**. Only complete DMA protection (`PROTECT_MEM_ALL`) is supported. |

### 2.2 D-CRTM requirements (4.4)

| Requirement | Status |
|---|---|
| Phase 1 checks: boot PE, other PEs off (PSCI), AArch64 caller, parameter validation, NS-memory checks (R44000-R44070) | Implemented by the upstream TF-A checks. |
| No active TPM localities before launch | **Missing**. The fTPM has no per-locality open/close state. |
| No asynchronous NS preemption of Secure services (R513000) | Not checked. RD-V3 runs Hafnium S-EL2 with SPs, and the PoC assumes none can DMA or preempt. |
| R44080: disable GIC ITS / LPIs (GICR_CTLR.EnableLPIs, GITS_CTLR) | **Missing** (TODO in `drtm_dma_prot.c`). The GIC can still DMA to the LPI tables during launch. |
| R44090: reset dynamic PCRs via `TPM_HASH_START` at locality 4 | **PoC deviation**. Same effect (PCR 17-22 set to 0 at locality 4), but done by a direct `PCRResetDynamics()` call instead of the `_TPM_Hash_Start/End` sequence. `restartCount` is incremented. |
| R44100: open localities 1/2/3 | **Missing**. The fTPM ignores locality for the OS interface; the OS always runs at locality 0. |
| R44120-R44160: DCE authentication and measurement | **Partial**. The DCE is part of BL31 (DCE = D-CRTM). Its integrity relies on the TF-A CCA chain of trust. The `DCE` event is measured; `DCE_PUBKEY` is measured as a placeholder because no separate signed DCE exists. |
| R44170: measure PCR schema | Implemented (default schema). |
| R44180/R44190: measure external debug and trace enable state | **Missing** (TODO in `drtm_measurements.c`; needs a platform hook). |

### 2.3 DCE requirements (4.5)

| Requirement | Status |
|---|---|
| R45000-R45020: signed, rollback-protected, securely updated DCE | Inherited from TF-A secure boot (CCA CoT). There is no separate DCE image, and FVP keys are development keys. |
| R45030/R45040: map DRTM_PARAMETERS XN and validate fields | Implemented. |
| R45050: event log full → extend 0xFF into PCR 17/18 and enter remediation | Not verified. The event log is 0x800 bytes (`PLAT_DRTM_EVENT_LOG_MAX_SIZE`), enough for the current events with SHA-384 digests. |
| R45060: measure security lifecycle state (`EVTYPE_ARM_NONSECURE_CONFIG`) | **Missing** (TODO). RD-V3 FVP has no readable lifecycle hook (R55000). |
| R45080: complete DMA protection with NS SMMU TLB invalidation | **Partial**. GBPA abort-all is set on the 4 PCIe SMMUs, but there is no TLB invalidation (TODO). |
| R45090-R45140: region-based protection | **Missing** (not offered). |
| R45150 / R53000: all NS DMA blocked, all DMA masters behind an SMMU | **PoC deviation**. The FVP virtio-mmio devices (block, net, etc.) are not behind an SMMU and are not blocked. `plat_has_unmanaged_dma_peripherals()` returns `false` anyway. |
| R45160: protected-regions sentinel (0x0, max size) | Implemented by the upstream code. |
| R45170/R45180: multi-stage DCE / Normal world DCE (R45400/R45410) | Not used. Normal world DCE region checks exist upstream but are unused. |
| R45190-R45220: DLME region checks, cache clean/invalidate | Implemented. |
| R45230: measure DLME image (`EVTYPE_ARM_DLME`, PCR 18) | Implemented (the mapping was fixed in this PoC). |
| R45250-R45270: DLME data header, address map, protected regions | Implemented. The address map is the BL31 mmap. |
| R45290: TCB hashes locked | Not applicable (`SET_TCB_HASH` is not supported). |
| R45300: `EVTYPE_ARM_SEPARATOR` | Implemented. |
| R45310: invalidate I-caches before DLME | Implemented. |
| R45320: zero unused event log space | Implemented by the upstream serialisation (not separately verified). |
| R45330/R45340: close locality 3, locality 2 active at DLME entry | **Missing** (no locality model in the fTPM). |
| R45350: error code set to 0 before DLME | Implemented. |
| R45370: measure DLME entry point (`EVTYPE_ARM_DLME_ENTRY_POINT`) | Implemented. |
| R45380/R45390: X0/X1 handoff and jump | Implemented. The PE state reset to PSCI CPU_ON values is only partly done (TODO in `drtm_main.c`). |

### 2.4 Measurements and PCR schemas (4.8)

| Requirement | Status |
|---|---|
| R48000: SHA-384 (or stronger) if the TPM supports it | Implemented. With the fTPM, the DRTM event log, the reported firmware hash algorithm and the extended bank default to SHA-384. A `MBOOT_TPM_HASH_ALG=sha256` override would break compliance. |
| R48010: deterministic order | Implemented (fixed order). |
| R48020: default PCR schema (Tables 38/39) | Implemented, except the missing debug/trace and lifecycle events. |
| R48030: DLME Authorities PCR schema (Table 41) | **Missing**. Only the default schema is advertised. |

### 2.5 Error handling and remediation (4.7, 5.11)

| Requirement | Status |
|---|---|
| R47000 / R511000: error code persists across the remediation reset and is tamper-resistant | **Missing**. It is stored in BL31 RAM, so it is lost on the SCMI reset and the DCE preamble cannot see why the last launch failed. Needs NV storage (for example SCP/RSE shared memory or a reserved NV register). |
| R47030: remediation ends with a system reset | Implemented (SCMI system reboot). |
| R47010 / R47040: implementation-defined codes and reporting | Not used. |

### 2.6 System requirements (chapter 5)

| Requirement | Status |
|---|---|
| R54000: non-host platforms (SCP, MCP, RSE) quiesced or trusted | **Missing**. They are not reported and not quiesced. |
| R54010/R54020: GIC LPI disable | **Missing** (see R44080). |
| R54030: hardware trace detection | **Missing**. |
| R55000: readable security lifecycle | **Missing** on the FVP model. |
| R56000/R56010: TPM compliant with the TCG PC Client profile | **PoC deviation**. The MS reference TPM is not certified, its NV is volatile, and there is no EK certificate. |
| R56020: hardware enforcement of locality 4 | **Partial**. Locality 4 is reachable only from BL31 code, and the CRB/SMC path always runs at locality 0. The fTPM state and CRB are in DRAM: BL31 in Root PAS, CRB in NS. |
| R56030-R56110: localities 1-4 on the platform interface, open/close localities 2/3, reset closes 1-3 | **Missing**. There is a single CRB at locality 0 and no per-locality CRBs. |
| R56050: system reset resets the TPM | Implemented (the volatile TPM is re-manufactured on boot). |
| R57010 / R510010: ACPI TCB table hashes from NS firmware | **Missing** (no `SET_TCB_HASH` in EDK2 or TF-A). |
| R58000-R58020: at least one DMA protection type | Complete protection only (see the R45150 caveat). |
| R510020 / R512010: PSCI `MEM_PROTECT` against reset attacks | Not enabled or verified on RD-V3. |
| R512000 / R512020: PSCI 1.x, SMCCC 1.x | Provided by TF-A. |

### 2.7 Hardware-backed DRTM (chapter 6)

Not applicable. This is a firmware-backed implementation.

### 2.8 Kernel / DLME side

* The NVIDIA series is a launch-path PoC. After launch, nothing appraises
  PCR 17/18 or the DRTM event log (no IMA/attestation integration), and the
  DRTM event log is not exposed to user space.
* Kernel protections that depend on the missing TCB hash table and on
  region-based DMA protection are not available.
* The kernel accepts DRTM 1.0 only because of a local patch.

---

## 3. Next steps, by priority

1. Run the SHA-384 build on the FVP and check that the SHA-384 PCR 17/18
   values match a replay of the DRTM event log.
2. Persist the DRTM error code across the remediation reset (R47000/R511000).
3. Add a GIC ITS/LPI disable and re-enable to DMA protection (R44080), and
   SMMU TLB invalidation (R45080).
4. Add platform hooks for debug/trace and lifecycle measurement
   (R44180/R44190, R45060); a fixed value on the FVP is acceptable.
5. Add a locality model to the fTPM: per-locality CRBs or a locality field,
   `DRTM_CLOSE_LOCALITY`, and localities 2/3 open after launch
   (R44100, R45330/R45340, R56030-R56110).
6. Handle the virtio-mmio DMA masters: report them as unmanaged, or put them
   behind an SMMU in the FVP model configuration (R45150/R53000).
7. Implement `DRTM_SET_TCB_HASH` / `DRTM_LOCK_TCB_HASHES` and EDK2 reporting of
   ACPI table hashes, then the DLME Authorities schema and DLME image
   authentication.
8. Optionally use the `_TPM_Hash_Start/Data/End` sequence instead of the direct
   PCR reset, and persistent fTPM NV for stable EK/SRK.
