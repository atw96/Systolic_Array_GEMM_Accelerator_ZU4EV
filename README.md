# INT8 Systolic Array GEMM Accelerator for Zynq UltraScale+ ZU4EV

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Zynq%20UltraScale%2B%20ZU4EV-blue.svg)](https://www.xilinx.com/products/silicon-devices/soc/zynq-ultrascale-mpsoc.html)
[![Vivado](https://img.shields.io/badge/Vivado-2020.1-orange.svg)](https://www.xilinx.com/support/download.html)
[![HDL](https://img.shields.io/badge/HDL-Verilog-brightgreen.svg)](./systolic_array_project_8x8/rtl)
[![Board Status](https://img.shields.io/badge/Board%20Bring--up-8%2F16%2F24%20PASS-success.svg)](#board-bring-up-results)

Weight-stationary **INT8** systolic-array GEMM accelerator targeting the **ALINX ACU4EV** (Xilinx **XCZU4EV**) platform.  
The repository provides three parameterized array sizes (**8×8 / 16×16 / 24×24**), a Vivado 2020.1 block-design flow, an ARM-side `/dev/mem` test application, and golden-model scripts for host-side checking.

This project is intended as an **FPGA / AI-accelerator interview demo**: RTL → simulation → implementation → PetaLinux board bring-up.

---

## Highlights

- Parameterized Weight-Stationary INT8 systolic array (`ARRAY_SIZE = 8 / 16 / 24`)
- AXI4-Lite control plane at a fixed PL aperture (`0x8005_0000`) via `M_AXI_HPM0_LPD`
- Dynamic bitstream reload through Linux `fpga_manager` (no SD-card reflash for PL iteration)
- Board-proven on ACU4EV + AXU4EVB-P with PetaLinux 2020.1
- All three variants pass 5 built-in golden vectors on hardware

---

## Architecture

```text
Host PC (WSL2 / Ubuntu)                         ACU4EV Board
┌────────────────────────────┐                  ┌────────────────────────────────────┐
│ Vivado 2020.1              │   SSH / SCP      │ PS: Cortex-A53 + PetaLinux 2020.1  │
│  - package IP              │ ───────────────► │  test_app  (/dev/mem + mmap)       │
│  - BD + synth + impl       │                  │           │                        │
│  - export .bit / .xsa      │                  │           ▼ AXI4-Lite              │
│                            │                  │      0x8005_0000                   │
│ Python golden model        │                  │  PL: axi_ctrl_top                  │
│  - board / eth verify      │                  │   ├── ctrl_fsm                     │
└────────────────────────────┘                  │   └── systolic_array [N×N]         │
                                                │        PE grid (DSP48E2 MAC)       │
                                                └────────────────────────────────────┘
```

### Dataflow (Weight Stationary)

| Signal | Direction | Role |
|--------|-----------|------|
| `data_in[row]` | left → right | A-matrix stream with per-row skew |
| `weight_reg` | stationary | B-matrix values preloaded into each PE |
| `psum` | top → bottom | partial-sum accumulation |
| `result_flat` | output | C-matrix row after `2N−1` compute cycles |

### Register Map (formula-based)

Word index layout (N = `ARRAY_SIZE`):

| Word index | Register |
|------------|----------|
| 0 | `CTRL_REG` (bit0 = start, write-1 auto-clear) |
| 1 | `STATUS_REG` (bit0 = done sticky, bit1 = busy) |
| `[2 .. 2+N−1]` | `RESULT_0 .. RESULT_{N−1}` |
| `[2+N .. 2+2N−1]` | `DATA_IN_0 .. DATA_IN_{N−1}` |
| `[2+2N .. 2+2N+N²−1]` | `WEIGHT_00 .. WEIGHT_{N−1,N−1}` (row-major) |

Base address on this board: **`0x8005_0000`** (4 KB aperture).

---

## Repository Layout

```text
.
├── LICENSE
├── README.md
├── .gitignore
├── systolic_array_project_8x8/
├── systolic_array_project_16x16/
└── systolic_array_project_24x24/
```

Each variant directory has the same layout:

| Path | Description |
|------|-------------|
| [`rtl/`](./systolic_array_project_8x8/rtl) | Parameterized RTL (`pe_unit`, `systolic_array`, `ctrl_fsm`, `axi_ctrl_top`) |
| [`constraints/`](./systolic_array_project_8x8/constraints) | Timing constraints |
| [`scripts/`](./systolic_array_project_8x8/scripts) | IP package / BD / bitstream / xsim / board deploy |
| [`software/`](./systolic_array_project_8x8/software) | ARM `test_app.c` + Makefile |
| [`python/`](./systolic_array_project_8x8/python) | Golden model & Ethernet receiver |
| [`tb/`](./systolic_array_project_8x8/tb) | xsim testbench |
| [`petalinux/`](./systolic_array_project_8x8/petalinux) | Optional DT overlay notes (default path uses `/dev/mem`) |
| [`deploy/`](./systolic_array_project_8x8/deploy) | Verified `.bit` / `.xsa` / `test_app` / timing & util reports / `board_result.txt` |

---

## Board Bring-up Results

Hardware: ALINX **ACU4EV** (XCZU4EV-1SFVC784I) + carrier, PetaLinux 2020.1, PL clock from FSBL-enabled **`pl_clk0` @ 200 MHz**.

| Variant | DSP48E2 | Util | WNS @ 200 MHz | Board test |
|---------|---------|------|---------------|------------|
| 8×8 | 64 / 728 | 8.8% | +0.932 ns | **5 / 5 PASS** |
| 16×16 | 256 / 728 | 35.2% | +0.646 ns | **5 / 5 PASS** |
| 24×24 | 576 / 728 | 79.1% | +0.094 ns | **5 / 5 PASS** |

Raw logs are stored under each variant’s [`deploy/board_result.txt`](./systolic_array_project_8x8/deploy/board_result.txt).

---

## Development Environment

| Item | Value |
|------|-------|
| Host OS | WSL2 Ubuntu 18.04 (recommended) |
| Vivado | 2020.1 |
| Cross compiler | `aarch64-linux-gnu-gcc` (Vitis 2020.1 toolchain) |
| Board OS | PetaLinux 2020.1 (not PYNQ) |
| PL access | `/dev/mem` + `mmap` (no UIO required by default) |
| Bitstream load | `/sys/class/fpga_manager/fpga0` |

> Build Vivado projects on a **native Linux filesystem** (e.g. under `$HOME/...`).  
> Avoid synthesizing directly on a Windows-mounted path such as `/mnt/<drive>/...`.

---

## Quick Start

Replace placeholders with your own machine / board settings.  
**Do not commit passwords, private keys, or lab IP addresses.**

### 1) Build bitstream (example: 16×16)

```bash
source /tools/Xilinx/Vivado/2020.1/settings64.sh
# Copy or sync the variant to a Linux-local working directory first
cd /path/to/work/systolic_array_project_16x16
vivado -mode batch -source scripts/build_bitstream.tcl
```

Outputs are written to `deploy/systolic_gemm_accel.bit` and `deploy/systolic_gemm_accel.xsa`.

### 2) Cross-compile `test_app`

```bash
cd software
export PATH=/tools/Xilinx/Vitis/2020.1/gnu/aarch64/lin/aarch64-linux/bin:$PATH
make CROSS=1
cp test_app ../deploy/
```

### 3) Deploy to board

```bash
# Optional password helper (local shell only; never commit secrets)
# export SSHPASS='<board_password>'
BOARD_IP=<board_ip> bash scripts/board_deploy.sh
```

Manual flow:

```bash
scp deploy/systolic_gemm_accel.bit deploy/test_app scripts/board_load_gemm.sh \
    root@<board_ip>:/tmp/gemm_bench/

ssh root@<board_ip> '
  cd /tmp/gemm_bench &&
  FORCE_PL_RELOAD=1 sh board_load_gemm.sh systolic_gemm_accel.bit &&
  ./test_app
'
```

### 4) Optional host-side check

```bash
python3 python/golden_model.py --array_size 16 --test_id 0 --mode board
```

---

## Important Porting Notes (ACU4EV)

These settings match the **verified** board environment and differ from generic ZynqUS+ assumptions:

1. **AXI base address** must stay inside the reachable PL control aperture → `0x8005_0000` (not `0xA000_0000`).
2. **PS master** for control is `M_AXI_HPM0_LPD` (`PSU__USE__M_AXI_GP2`).
3. **Clock**: use FSBL-enabled `pl_clk0` and connect `maxihpm0_lpd_aclk`. Using an unenabled `pl_clk1` yields a dead accelerator (reads hang / never complete).
4. **`ctrl_reg` must be single-driven** in `axi_ctrl_top.v`. A split always-block for start auto-clear creates a multi-driver and can optimize the array away (observed as DSP=0 and STATUS timeout).

---

## Simulation

```bash
# PE unit smoke test
bash scripts/run_xsim.sh

# Full array + AXI task-level simulation
bash scripts/run_xsim_full.sh
```

---

## Security / Privacy

This repository is scrubbed for public release:

- No board IP addresses, SSH passwords, or private keys
- No host-specific home directories or lab inventory strings
- Use local environment variables (for example `BOARD_IP`, `SSHPASS`) on your machine only

If you fork this project for a private lab, keep credentials out of git history.

---

## License

This project is released under the [MIT License](./LICENSE).

```text
Copyright (c) 2026 atw96
```

---

## Acknowledgements

- Xilinx / AMD Vivado & PetaLinux toolchains
- ALINX ACU4EV hardware platform documentation
- Companion Edge-AI bring-up experience on the same ZU4EV carrier (control-plane address / clock conventions)

---

## Disclaimer

Hardware results depend on your FSBL/clocking setup, bitstream packaging, and board revision.  
Always re-run the included golden vectors after any RTL or BD change.

---

**Repository status:** board-verified initial release on `main`.
