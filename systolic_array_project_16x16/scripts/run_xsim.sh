#!/bin/bash
# =============================================================
# 文件名  : run_xsim.sh
# 描述    : pe_unit 单模块仿真脚本（Vivado xsim 2020.1）
# 运行    : bash run_xsim.sh
# 输出    : xsim_pe_unit.log
# =============================================================

set -e  # 任何命令失败立即退出

# ── 环境初始化 ────────────────────────────────────────────────
VIVADO_SETTINGS="/tools/Xilinx/Vivado/2020.1/settings64.sh"
if [ ! -f "${VIVADO_SETTINGS}" ]; then
    echo "[ERROR] Vivado 2020.1 未找到: ${VIVADO_SETTINGS}"
    echo "        请检查安装路径"
    exit 1
fi
source "${VIVADO_SETTINGS}"

echo "======================================================"
echo "  pe_unit 仿真 — Vivado xsim 2020.1"
echo "  平台: XCZU4EV | INT8 MAC | Weight Stationary"
echo "======================================================"

# 工作目录切换到脚本所在的上级目录（工程根目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
cd "${PROJECT_DIR}"

# 创建仿真工作目录
mkdir -p sim_work
cd sim_work

# ── Step 1：编译 RTL 和 Testbench（-sv 启用 SystemVerilog 扩展）──
echo ""
echo "[Step 1] 编译 RTL 源文件..."
xvlog -sv \
    ../rtl/pe_unit.v \
    ../tb/pe_unit_tb.v \
    -log xvlog_pe_unit.log

if [ $? -ne 0 ]; then
    echo "[ERROR] 编译失败，查看 xvlog_pe_unit.log"
    exit 1
fi
echo "  编译成功"

# ── Step 2：精化（Elaboration）────────────────────────────────
echo "[Step 2] 精化仿真模型..."
xelab -debug typical \
    pe_unit_tb \
    -s pe_unit_sim \
    -log xelab_pe_unit.log

if [ $? -ne 0 ]; then
    echo "[ERROR] 精化失败，查看 xelab_pe_unit.log"
    exit 1
fi
echo "  精化成功"

# ── Step 3：仿真（无 GUI，输出到日志）────────────────────────
echo "[Step 3] 运行仿真..."
xsim pe_unit_sim \
    -runall \
    -log xsim_pe_unit.log

echo ""
echo "======================================================"
echo "  仿真完成！查看结果："
echo "  日志文件: sim_work/xsim_pe_unit.log"
echo "  波形文件: sim_work/pe_unit_wave.vcd"
echo ""
echo "  关键结果（从日志提取）："
grep -E "\[PASS\]|\[FAIL\]|Results:|PASSED|FAILED" xsim_pe_unit.log || true
echo "======================================================"
