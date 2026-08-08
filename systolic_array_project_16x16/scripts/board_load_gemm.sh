#!/bin/sh
# =============================================================
# 文件名  : board_load_gemm.sh
# 描述    : 在 ACU4EV 板端用 fpga_manager 加载 GEMM 加速器 bitstream
#           对照 porting_env_hardware_config.md 中 board_load_only.sh
#           的验证方式实现（无需重新打包整张 SD 卡镜像）
#
# 【移植说明】
#   本工程为纯 AXI4-Lite 控制接口（无 AXI-DMA / HP0 高速数据通路），
#   因此 *不需要* EdgeAI-ZU4EV 工程中的 HP0 64-bit AFIFM2 修复步骤
#   （那是针对 S_AXI_HP0_FPD 高速数据口的问题，本工程只用
#   M_AXI_HPM0_LPD 低速控制口，不受影响）。
#
# 运行位置：ACU4EV 板卡（PetaLinux 2020.1，root 用户）
# 用法    ：sh board_load_gemm.sh [bit文件路径]
#           默认: /tmp/gemm_bench/systolic_gemm_accel.bit
# =============================================================

set -e

# Ensure busybox applets like /sbin/devmem are visible over non-login SSH
export PATH="/sbin:/usr/sbin:/usr/bin:/bin:${PATH}"

BIT_SRC="${1:-/tmp/gemm_bench/systolic_gemm_accel.bit}"
BIT_DST="/lib/firmware/systolic_gemm_accel.bit"
FPGA_MGR="/sys/class/fpga_manager/fpga0"

echo "======================================================"
echo "  ACU4EV FPGA Manager 加载 — INT8 脉动阵列 GEMM"
echo "======================================================"

# ── Step 1：检查 bit 文件是否存在 ────────────────────────────
if [ ! -f "${BIT_SRC}" ]; then
    echo "[ERROR] bit 文件不存在: ${BIT_SRC}"
    echo "        请先从 PC 端 scp 传输："
    echo "        scp deploy/systolic_gemm_accel.bit root@<board_ip>:/tmp/gemm_bench/"
    exit 1
fi

# ── Step 2：拷贝到 /lib/firmware（fpga_manager 固定搜索路径）──
echo ""
echo "[Step 1] 拷贝 bit 文件到 /lib/firmware/"
cp "${BIT_SRC}" "${BIT_DST}"
sync

# ── Step 3：检查 fpga_manager 节点是否存在 ────────────────────
echo ""
echo "[Step 2] 检查 fpga_manager 节点"
if [ ! -d "${FPGA_MGR}" ]; then
    echo "[ERROR] ${FPGA_MGR} 不存在"
    echo "        请确认 PetaLinux 内核已启用 ZynqMP FPGA Manager 驱动"
    echo "        (CONFIG_FPGA_MGR_ZYNQMP_FPGA=y)"
    exit 1
fi
echo "  当前状态: $(cat ${FPGA_MGR}/state)"

# ── Step 4：触发加载（写 firmware 属性文件名）────────────────
echo ""
echo "[Step 3] 触发 FPGA 加载: $(basename ${BIT_DST})"
echo "$(basename ${BIT_DST})" > "${FPGA_MGR}/firmware"

# ── Step 5：轮询确认加载完成 ──────────────────────────────────
echo ""
echo "[Step 4] 等待加载完成..."
TIMEOUT=50
COUNT=0
while [ ${COUNT} -lt ${TIMEOUT} ]; do
    STATE=$(cat "${FPGA_MGR}/state")
    if [ "${STATE}" = "operating" ]; then
        echo "  加载成功！state=${STATE}"
        break
    fi
    COUNT=$((COUNT + 1))
    sleep 0.2
done

STATE=$(cat "${FPGA_MGR}/state")
if [ "${STATE}" != "operating" ]; then
    echo "[ERROR] 加载超时或失败，最终 state=${STATE}"
    echo "        请检查 dmesg 输出：dmesg | tail -30"
    exit 1
fi

# ── Step 6：（可选）用 devmem 快速探测寄存器是否可访问 ───────
echo ""
echo "[Step 5] 快速探测 AXI-Lite 寄存器（STATUS_REG @ 0x80050004）"
if command -v devmem >/dev/null 2>&1; then
    STATUS_VAL=$(devmem 0x80050004 32 2>/dev/null || echo "READ_FAILED")
    echo "  STATUS_REG = ${STATUS_VAL}"
    if [ "${STATUS_VAL}" = "READ_FAILED" ]; then
        echo "  [WARN] devmem 读取失败，请检查地址映射或权限"
    fi
else
    echo "  [SKIP] devmem 命令不可用（可用 test_app 代替验证）"
fi

echo ""
echo "======================================================"
echo "  加载完成！fpga0 state = operating"
echo "  下一步：运行 ./test_app 进行功能验证"
echo "======================================================"
