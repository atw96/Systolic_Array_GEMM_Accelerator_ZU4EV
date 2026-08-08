# INT8 Systolic Array GEMM Accelerator
## FPGA Demo Project — ALINX ACU4EV (Xilinx XCZU4EV)

A **Weight Stationary** INT8 systolic array for matrix multiplication (GEMM),
designed as an AI chip front-end interview demo. Covers RTL design, xsim simulation,
Vivado implementation, PetaLinux integration, and board-level ARM-driven verification.

---

## System Architecture

```
PC (WSL2 Ubuntu 18.04)                         ACU4EV Board (<board_ip>)
┌──────────────────────────┐                   ┌──────────────────────────────────┐
│ Vivado 2020.1            │                   │  PS: ARM Cortex-A53 (1.2 GHz)    │
│   - RTL synthesis        │  Ethernet(scp/ssh)│  PetaLinux 2020.1                │
│   - Bitstream gen        │ ────────────────► │  test_app  (/dev/mem → mmap)     │
│   - create_bd.tcl        │                   │      │ AXI4-Lite @ 0x8005_0000    │
│                          │                   │      ▼  (via M_AXI_HPM0_LPD)      │
│ PetaLinux 2020.1         │                   │  PL: XCZU4EV @ pl_clk1=100 MHz   │
│   - fpga_manager reload  │                   │  ┌────────────────────────────┐   │
│   - (no full re-image)   │                   │  │  axi_ctrl_top              │   │
│                          │                   │  │  ├── ctrl_fsm              │   │
│ Python 3.9               │                   │  │  │   IDLE→LOAD→COMPUTE     │   │
│   - golden_model.py      │                   │  │  │   →OUTPUT→DONE          │   │
│   - Result verification  │                   │  │  └── systolic_array [4×4]  │   │
└──────────────────────────┘                   │  │       ├── PE[0][0..3]      │   │
                                               │  │       ├── PE[1][0..3]      │   │
                                               │  │       ├── PE[2][0..3]      │   │
                                               │  │       └── PE[3][0..3]      │   │
                                               │  │       (16× DSP48E2 total)  │   │
                                               │  └────────────────────────────┘   │
                                               └──────────────────────────────────┘
```

> **注意**：本图已按真实 ACU4EV 板卡环境更新（详见下方"真实硬件移植说明"章节）。
> 早期 Demo 版本假设 JTAG 直连 + UIO + 基地址 `0xA000_0000`，
> 与本板实测环境不符，请以本文档为准。

### Weight Stationary Data Flow

| Signal | Direction | Description |
|--------|-----------|-------------|
| `data_in[row]` | Left → Right | A matrix row elements, staggered by row index |
| `weight_reg` | Static | B matrix values, preloaded into each PE |
| `psum` | Top → Bottom | Partial sums accumulate down each column |
| `result_flat` | Output | C matrix row, valid after 2×4−1 = 7 clock cycles |

### INT8 Overflow Analysis

```
Max INT8 product    : 127 × 127 = 16,129  (15 bits)
4-cycle accumulation: 4 × 16,129 = 64,516  (17 bits)
INT32 range         : ±2,147,483,648      (31 bits + sign)
→ INT32 is completely safe, no saturation logic needed
```

---

## Development Environment

| Component | Version / Spec (real ACU4EV environment) |
|-----------|----------------|
| Host OS | WSL2 Ubuntu 18.04 |
| Vivado | 2020.1 (path: `/tools/Xilinx/Vivado/2020.1`) |
| Vitis HLS / Vivado HLS | 2020.1 (path: `/tools/Xilinx/Vitis_HLS/2020.1`) |
| PetaLinux | 2020.1 (path: **`/opt/pkg/petalinux/settings.sh`**, no version subdir) |
| Python | 3.9 (host) / 3.7.6 (board rootfs, no pip3) |
| Simulator | Vivado xsim (built-in, no ModelSim required) |
| FPGA Board | ALINX ACU4EV (core board ACU4EV + carrier AXU4EVB-P) |
| Device | Xilinx Zynq UltraScale+ XCZU4EV-1SFVC784I (`xczu4ev-sfvc784-1-i`) |
| PS | ARM Cortex-A53 ×4 + Cortex-R5 ×2, DDR4 4 GB (64-bit) |
| PL Resources | LUT: 88K, DSP48E2: 728, BRAM_18K: 252 (≈4.5 Mb), **URAM: 0 (unavailable)** |
| WSL project root | **`$HOME/work/<project>`** (never synthesize under `/mnt/<windows_drive>/...`) |
| Board network | DHCP-assigned `<board_ip>`, SSH as `root` via dropbear |
| Board OS | PetaLinux 2020.1 (not PYNQ); inference via **`/dev/mem`**, not UIO/Overlay |
| PL firmware dir | `/lib/firmware/` (loaded via `/sys/class/fpga_manager/fpga0/`) |

---

## File Structure

```
systolic_array_project/
├── rtl/
│   ├── pe_unit.v           # Processing Element (MAC unit, DSP48E2)
│   ├── systolic_array.v    # NxN WS array, generate loop, skewing (parameterized)
│   ├── ctrl_fsm.v          # 5-state Moore FSM controller (parameterized, sticky done)
│   └── axi_ctrl_top.v      # AXI4-Lite slave, generic parameterized register file
│                           #   (base addr 0x8005_0000, ARRAY_SIZE default 8)
├── tb/
│   └── pe_unit_tb.v        # xsim testbench, 7 test vectors
├── constraints/
│   └── acu4ev_top.xdc      # Timing constraints (100 MHz reference clock)
├── scripts/
│   ├── run_xsim.sh         # pe_unit simulation (step 1 check)
│   ├── run_xsim_full.sh    # Full systolic array simulation (N=8, fixed AXI tasks)
│   ├── create_project.tcl  # Vivado 2020.1 project creation
│   ├── create_bd.tcl       # Block Design automation (HPM0_LPD, 0x8005_0000)
│   └── board_load_gemm.sh  # fpga_manager dynamic bit loading (board-side)
├── software/
│   ├── test_app.c          # ARM-side C program (/dev/mem + mmap + Ethernet upload)
│   └── Makefile            # Cross-compile or native compile
├── python/
│   ├── golden_model.py     # Bit-accurate golden model + verification (gen/sim/board/eth modes)
│   └── host_eth_receiver.py # Host-side TCP listener + live cross-check against golden model
└── petalinux/
    ├── PETALINUX_GUIDE.md  # Step-by-step PetaLinux build guide (ACU4EV real env)
    ├── petalinux_build.sh  # Automated build script
    └── system-user.dtsi    # OPTIONAL: UIO device tree (not needed by default)
```

---

## Real Hardware Porting Notes (ACU4EV)

This project was originally drafted against generic assumptions and has been
**ported to match the actual verified ACU4EV environment** (cross-referenced
against a companion project, `EdgeAI-ZU4EV_Claude`, that already runs on the
same board). Key changes:

| Item | Original assumption | Real board value | Why |
|---|---|---|---|
| AXI-Lite base address | `0xA000_0000` | **`0x8005_0000`** | Valid PL control aperture on this board is only `0x8000_0000` [512 MB]; `0xA000_0000` is out of range and unreachable in hardware. `0x8005_0000` sits in a free 256 KB gap between the companion project's DMA (`0x8004_0000`) and its debug peripherals (`0x8008_0000`), so it won't collide if the two designs are ever merged. |
| PS master port | `M_AXI_HPM0_FPD` | **`M_AXI_HPM0_LPD`** (`CONFIG.PSU__USE__M_AXI_GP2`) | Matches the master port already verified working on this board for control-plane peripherals. |
| PL clock | `pl_clk0` = 100 MHz | **`pl_clk1`** = 100 MHz | Reserves `pl_clk0` (200 MHz on this board) for future high-throughput accelerator IP, consistent with the companion project's clock plan. |
| Board-side access | UIO (`/dev/uio0`) | **`/dev/mem` + mmap** | This board's PetaLinux rootfs is verified to allow `/dev/mem` access without any device-tree changes; no kernel rebuild required. `system-user.dtsi` is kept as an optional alternative only. |
| PetaLinux `settings.sh` | `/opt/pkg/petalinux/2020.1/settings.sh` | **`/opt/pkg/petalinux/settings.sh`** | Actual install path has no version subdirectory on this host. |
| WSL project root | any path | **`$HOME/work/<project>`** | Synthesis must never run under a Windows-mounted `/mnt/<windows_drive>/...` path. |
| Iterative bitstream reload | Rebuild + reflash whole SD card | **`fpga_manager`** (`/sys/class/fpga_manager/fpga0/firmware`) | Copy `.bit` to `/lib/firmware/` and trigger reload in seconds — no PetaLinux rebuild needed after the first boot image is flashed. |

> This project does **not** use the AXI-DMA / `S_AXI_HP0_FPD` high-throughput
> data path from the companion CNN project, so the HP0 64-bit AFIFM2 fix
> (`board_fix_hp0_width.py`) documented there is **not required** here —
> that fix is specific to the DMA data path, and this design only uses a
> low-speed AXI4-Lite control interface via `M_AXI_HPM0_LPD`.

---

## This Revision's Optimizations

Two changes were made in this pass: (1) PL computes, PS streams results to a
host PC over Ethernet; (2) the systolic array was scaled up since the board
has substantial unused DSP/LUT headroom. A third, unplanned but important fix
came out of actually simulating the full AXI transaction chain for the first
time (see below).

### 1. Array scale-up: 4×4 → 8×8 (parameterized)

`porting_env_hardware_config.md` records **LUT 88,000 / DSP48E2 728** available
on this board; the original 4×4 design used only 16 DSPs (≈2.2%). All three
RTL modules are now fully parameterized by `ARRAY_SIZE` (no hardcoded loops
left), so the array can be resized without touching the RTL:

| ARRAY_SIZE | DSP48E2 used | DSP % of 728 | LUT (rough estimate*) | Register count | Notes |
|---|---|---|---|---|---|
| 4 (original) | 16 | 2.2% | ~1,800 | 22 | Baseline |
| **8 (this revision's default)** | **64** | **8.8%** | **~4,500 (est.)** | 82 | Good balance of throughput vs. register-map size |
| 16 | 256 | 35.2% | ~19,000 (est.) | 290 | Feasible; comfortably under the 60% LUT budget noted in the hardware config doc |
| 24 | 576 | 79.1% | ~43,000 (est.) | 626 | Tight; would need careful floorplanning and timing closure |

\* LUT figures are extrapolated from the original design's placeholder
estimate, **not** measured from an actual Vivado synthesis run (this
environment has no Vivado access) — treat them as rough guidance and run
`report_utilization` after synthesis for real numbers before committing to a
size.

To change the size, edit exactly one parameter and re-synthesize:

```verilog
// rtl/axi_ctrl_top.v
module axi_ctrl_top #(
    parameter integer ARRAY_SIZE = 8,   // change this
    ...
```

`systolic_array.v`'s skewing chains and `ctrl_fsm.v`'s compute counter now
both auto-size themselves (`generate` loops / computed bit widths) — the
previous version hardcoded exactly 4 rows and a 4-bit counter, so it silently
would have produced wrong results or overflowed if you'd just bumped
`ARRAY_SIZE` without those fixes.

The AXI register map also changed from a hand-enumerated `case` list (which
doesn't scale past a handful of registers) to a **formula-based generic
register file**:

```
word index 0                          CTRL_REG
word index 1                          STATUS_REG
word index [2 .. 2+N-1]                RESULT_0 .. RESULT_{N-1}
word index [2+N .. 2+2N-1]             DATA_IN_0 .. DATA_IN_{N-1}
word index [2+2N .. 2+2N+N²-1]         WEIGHT_00 .. WEIGHT_{N-1,N-1} (row-major)
```

For the default N=8: `RESULT_0..7 @ 0x08-0x24`, `DATA_IN_0..7 @ 0x28-0x44`,
`WEIGHT_00..77 @ 0x48-0x144` (82 registers, 328 bytes total — well inside the
64 KB address space already allocated in `create_bd.tcl`).

### 2. Critical fix found via full-chain simulation: `done` was a 1-cycle pulse

This wasn't part of either request, but simulating the complete AXI4-Lite
transaction chain end-to-end (rather than just `pe_unit` in isolation, which
is all that had been verified before) surfaced a real bug: `ctrl_fsm`'s
`done` signal was combinationally high for exactly **one clock cycle**
(10 ns @ 100 MHz) during the `DONE_ST` state, then dropped back to 0 the
next cycle.

Software polling — whether it's an AXI read transaction in simulation, or an
ARM core polling `/dev/mem` in real life — costs microseconds per iteration.
A 10 ns pulse is invisible to that polling loop almost every time, so
`test_app` would hang forever waiting for `done=1`, both in simulation and,
critically, **on the real board too**. This is now fixed: `done` is a sticky,
level-held flag that's set on completion and only clears on the *next*
`start` pulse, matching how status registers are conventionally designed for
software polling. See the fix and full explanation in `rtl/ctrl_fsm.v`'s
header comment.

Two AXI testbench task bugs (a race between clearing `awvalid`/`wvalid` at
different clock edges) were also found and fixed the same way — see the
comments at the top of `scripts/run_xsim_full.sh`.

### 3. PS → Ethernet result upload

The board computes on the PL, then the PS streams each result to a host PC
over Ethernet instead of (or in addition to) printing locally.

> **On the referenced `imgproc` GitHub project**: I don't have access to your
> GitHub repos or any external/private code, so I can't read its actual
> Ethernet configuration. What's implemented here is a generic, fully
> working reference protocol (plain TCP + newline-delimited JSON) with the
> protocol clearly commented in both `test_app.c` and
> `host_eth_receiver.py`, so you can compare it against `imgproc`'s actual
> setup and tell me what to change — port/IP conventions, framing format,
> long-lived vs. per-message connections, UDP vs. TCP, etc. — and I can
> align it exactly next round.

**Protocol** (board → host):

- Transport: TCP, one short-lived connection per result (connect → send →
  close). Simple, no persistent connection state to manage, appropriate for
  a low-frequency result-reporting use case.
- Payload: one JSON object per line (JSON Lines), for example:
  ```json
  {"seq":1,"test_id":0,"array_size":8,"result":[2437,3604,...],"pass":true,"ts":1785409966}
  ```
- 3-second send/recv timeout on the board side, so an unreachable host
  doesn't hang the board indefinitely; a failed upload is logged as a
  warning and the board moves on to the next test vector rather than
  aborting (network issues shouldn't take down local computation).

**Usage:**

```bash
# On the host PC (run this first, it listens and blocks)
python3 python/host_eth_receiver.py --port 9000 --array_size 8

# On the board
sudo ./test_app --host <host PC IP> --port 9000
```

`host_eth_receiver.py` logs every received result to `eth_results.jsonl` and,
more usefully for debugging, **immediately re-computes the expected result
via `golden_model.py` and cross-checks it live** — so you see
`[HOST-VERIFIED PASS]` or `[HOST-VERIFIED FAIL]` the moment each result
arrives, rather than trusting the board's self-reported pass/fail or having
to run a separate comparison pass afterward. You can also replay the log
later with `python3 golden_model.py --mode eth --test_id <N>`.

`test_app` now runs all 5 built-in test vectors per invocation by default
(pass `--test_id N` to run just one), uploading each result as it completes
— a closer approximation of a real batch-inference-and-report workflow than
the original single-shot version.

---

## Quick Start

### Phase 1: PC-side Simulation (≈ 5 minutes)

```bash
# 1. Source Vivado
source /tools/Xilinx/Vivado/2020.1/settings64.sh

# 2. Run pe_unit unit simulation (array-size-independent, always 7 vectors)
cd systolic_array_project/scripts
chmod +x run_xsim.sh run_xsim_full.sh
bash run_xsim.sh
# Expected: 7 PASS, 0 FAIL

# 3. Run full systolic array simulation (default N=8, fixed AXI task timing)
bash run_xsim_full.sh
# Expected: *** 全链路仿真 PASS *** result.txt written

# 4. Verify with golden model (--array_size must match rtl/axi_ctrl_top.v's
#    ARRAY_SIZE parameter — both default to 8)
cd ..
python3 python/golden_model.py --array_size 8 --test_id 0 --mode sim
# Expected: ✓ [PASS]
```

### Phase 2: Vivado Synthesis & Implementation (≈ 30–60 min)

```bash
# 1. Package axi_ctrl_top as IP (Vivado GUI)
#    Tools → Create and Package New IP → Package specified directory → rtl/
#    Save to: ip_repo/axi_ctrl_top_1.0/

# 2. Create Block Design
#    (WSL project root must be $HOME/work/<project>,
#     never /mnt/<windows_drive>/... for synthesis)
source /tools/Xilinx/Vivado/2020.1/settings64.sh
vivado -mode batch -source scripts/create_bd.tcl
# Uses M_AXI_HPM0_LPD, pl_clk1=100MHz, base address 0x8005_0000

# 3. Open Vivado GUI, run implementation
#    Flow → Run Synthesis → Run Implementation → Generate Bitstream
#    (recommended strategy: Performance_ExplorePostRoutePhysOpt)
#    File → Export Hardware (Include Bitstream) → deploy/systolic_gemm_accel.xsa
# Also confirm in Window → Address Editor that the 0x8005_0000 segment
# shows a valid (green) mapping, not excluded/out-of-range.
```

### Phase 3: PetaLinux Build (≈ 60–120 min, one-time only)

```bash
# Real environment path has no version subdirectory
source /opt/pkg/petalinux/settings.sh
bash petalinux/petalinux_build.sh --xsa deploy/systolic_gemm_accel.xsa

# Outputs: BOOT.BIN, image.ub, boot.scr, rootfs.tar.gz
# See: petalinux/PETALINUX_GUIDE.md for SD card flashing
#
# NOTE: this full build + SD flash is only needed ONCE, to get a base
# PetaLinux system with fpga_manager + /dev/mem support running. After
# that, use Phase 4's fpga_manager reload for every subsequent bitstream
# iteration — no rebuild or reflash required.
```

### Phase 4: Board Verification (fpga_manager reload, seconds per iteration)

```bash
export BOARD_IP=<board_ip>   # set to your board address

# From WSL, transfer artifacts (never run scp/ssh from PowerShell directly)
scp deploy/systolic_gemm_accel.bit scripts/board_load_gemm.sh software/test_app \
    root@${BOARD_IP}:/tmp/gemm_bench/

# Load bitstream via fpga_manager (no PetaLinux rebuild needed)
ssh -o ConnectTimeout=8 root@${BOARD_IP} \
    "cd /tmp/gemm_bench && sh board_load_gemm.sh systolic_gemm_accel.bit"
# Confirm: fpga0 state = operating

# Run the test program locally on the board (needs root for /dev/mem),
# runs all 5 built-in test vectors, no Ethernet upload yet:
ssh -o ConnectTimeout=8 root@${BOARD_IP} \
    "cd /tmp/gemm_bench && ./test_app 2>&1 | tee board_result.txt"

# On PC, verify against golden model:
python3 python/golden_model.py --test_id 0 --mode board
```

### Phase 5: Board → Ethernet → Host live verification

```bash
# On the PC (this host), start the receiver first — it blocks and listens
python3 python/host_eth_receiver.py --port 9000 --array_size 8 &

# Find this PC's IP as seen from the board's subnet, e.g. <host_ip>
export HOST_IP=<host_ip>

# On the board, point test_app at the host
ssh -o ConnectTimeout=8 root@${BOARD_IP} \
    "cd /tmp/gemm_bench && ./test_app --host ${HOST_IP} --port 9000"

# The receiver terminal prints [HOST-VERIFIED PASS/FAIL] live as each of the
# 5 results arrives. Afterward, results are also on disk for replay:
python3 python/golden_model.py --mode eth --test_id 0
```

---

## Expected Synthesis Results

| Resource | Used (N=8, this revision) | Available | Utilization |
|----------|------|-----------|-------------|
| DSP48E2 | 64 | 728 | **8.8%** |
| LUT | ~4,500 (est.*) | 88,320 | ~5.1% (est.) |
| FF | ~6,000 (est.*) | 176,640 | ~3.4% (est.) |
| BRAM | 0 | 360 | 0% |
| Timing (WNS) | > 0 ns @ 100 MHz | — | PASS (expected; not yet synthesized) |

\* Estimated by scaling the original 4×4 design's placeholder numbers; **not**
measured from an actual Vivado run in this environment. Run
`report_utilization` after synthesis and replace this table with real numbers.
See the array scale-up table above for projections at N=4/8/16/24.

---

## Board Test Results

> *(Add serial port screenshot here after board verification)*

```
Expected output from test_app (N=8, running all 5 built-in test vectors):
======================================================
  INT8 脉动阵列 GEMM (8x8) - 板卡验证程序（ACU4EV 优化版）
  平台: ACU4EV (XCZU4EV)  PetaLinux 2020.1
======================================================
---- test_id=0 ----
RESULT_0: 2437
RESULT_1: 3604
RESULT_2: -6525
RESULT_3: -26132
RESULT_4: -12318
RESULT_5: 48740
RESULT_6: 11803
RESULT_7: -55
  [PASS] test_id=0 与内置 GOLDEN 表完全一致
...
======================================================
  汇总: 5 PASS, 0 FAIL (共 5 组)
  *** 全部测试通过 — 上板验证 PASS ***
======================================================
```

---

## Interview FAQ

**Q1: Why Weight Stationary instead of Output Stationary?**

Weight Stationary (WS) stores the B matrix permanently in PE registers, eliminating
repeated weight loads during computation. For inference workloads where the same weights
are applied to many input batches, WS minimizes weight-memory bandwidth — ideal for
edge AI accelerators where DRAM power dominates. This design processes one output row
per computation cycle, then reuses the stored weights for the next input row.

**Q2: How does the skewing mechanism ensure correctness?**

For C = A × B, PE[i][j] holds B[i][j]. Element A[m][i] must arrive at PE[i][*] exactly
when the partial sum from rows 0..i-1 is ready. Row i's data input is delayed by i
register stages, so A[m][0] enters row 0 at cycle 0, A[m][1] enters row 1 at cycle 1,
etc. This guarantees PE[i][j] receives both its input data and the correct accumulated
psum simultaneously. The total latency is 2×N−1 cycles — 7 for the original 4×4 array,
15 for this revision's default 8×8. The skewing chains are `generate`-loop based so
this scales automatically with `ARRAY_SIZE`; the original version hardcoded exactly
4 rows and wouldn't have worked correctly if you'd just changed the parameter.

**Q3: Why AXI4-Lite for the control interface, not AXI4-Stream?**

AXI4-Lite is designed for low-frequency register read/write access: simple address-mapped
transactions, no flow control overhead, easy integration with PS GPIO and driver code.
AXI4-Stream suits high-throughput data paths (streaming pixels, feature maps) where
burst transfers and backpressure signaling justify the complexity. The control plane
transfers well under 100 bytes per inference even at N=8 (82 registers × 4 bytes) — AXI4-Lite
overhead is negligible and the implementation is far simpler to verify.

**Q4: Why 8×8 instead of maxing out the DSP budget?**

At 8×8, only 8.8% of the board's 728 DSP48E2 slices are used — there's clearly room to go
further (16×16 would still be ~35%). The reason for landing on 8×8 as the shipped default
rather than the largest feasible size: the AXI register map grows as `2+2N+N²`, so going to
16×16 already means 290 registers instead of 82, and to 24×24 means 626 — more registers to
initialize per inference (more AXI transactions, more software loop iterations), and a design
that's harder to hand-verify end-to-end during interview discussion. `ARRAY_SIZE` is a single
parameter, so scaling further is a deliberate choice to make once you know your target
throughput and are ready to re-run synthesis/timing closure at that size, not a default to
maximize blindly.
