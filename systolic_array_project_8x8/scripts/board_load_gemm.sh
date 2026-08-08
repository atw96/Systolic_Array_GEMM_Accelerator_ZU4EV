#!/bin/sh
# =============================================================
# 文件名  : board_load_gemm.sh
# 描述    : 在 ACU4EV 板端用 fpga_manager 加载 GEMM 加速器 bitstream
#           对齐 EdgeAI-ZU4EV 已验证的 board_load_only.sh 行为
#
# 运行位置：ACU4EV 板卡（PetaLinux 2020.1，root 用户）
# 用法    ：sh board_load_gemm.sh [bit文件路径]
#           默认: /tmp/gemm_bench/systolic_gemm_accel.bit
# =============================================================

set -e

# Ensure busybox applets like /sbin/devmem are visible over non-login SSH
export PATH="/sbin:/usr/sbin:/usr/bin:/bin:${PATH}"

BIT_SRC="${1:-/tmp/gemm_bench/systolic_gemm_accel.bit}"
BIT_NAME="systolic_gemm_accel.bit"
BIT_DST="/lib/firmware/${BIT_NAME}"
FPGA_MGR="/sys/class/fpga_manager/fpga0"
FORCE_PL_RELOAD="${FORCE_PL_RELOAD:-1}"

echo "======================================================"
echo "  ACU4EV FPGA Manager 加载 — INT8 脉动阵列 GEMM"
echo "======================================================"

if [ ! -f "${BIT_SRC}" ]; then
    echo "[ERROR] bit 文件不存在: ${BIT_SRC}"
    echo "        请先从 PC 端 scp 传输："
    echo "        scp deploy/systolic_gemm_accel.bit root@<board_ip>:/tmp/gemm_bench/"
    exit 1
fi

echo ""
echo "[Step 1] 拷贝 bit 文件到 /lib/firmware/"
mkdir -p /lib/firmware
cp -f "${BIT_SRC}" "${BIT_DST}"
sync
ls -la "${BIT_DST}"
md5sum "${BIT_DST}" 2>/dev/null || true

echo ""
echo "[Step 2] 检查 fpga_manager 节点"
if [ ! -d "${FPGA_MGR}" ]; then
    echo "[ERROR] ${FPGA_MGR} 不存在"
    echo "        请确认 PetaLinux 内核已启用 ZynqMP FPGA Manager 驱动"
    echo "        (CONFIG_FPGA_MGR_ZYNQMP_FPGA=y)"
    exit 1
fi
CUR=$(cat "${FPGA_MGR}/state" 2>/dev/null || echo unknown)
echo "  当前状态: ${CUR}"

echo ""
echo "[Step 3] 触发 FPGA 加载: ${BIT_NAME}"
if [ "${FORCE_PL_RELOAD}" = "1" ] || [ "${CUR}" != "operating" ]; then
    echo "${BIT_NAME}" > "${FPGA_MGR}/firmware"
else
    echo "  skip reload (FORCE_PL_RELOAD=0, already operating)"
fi

echo ""
echo "[Step 4] 等待加载完成..."
TIMEOUT=30
COUNT=0
while [ ${COUNT} -lt ${TIMEOUT} ]; do
    STATE=$(cat "${FPGA_MGR}/state" 2>/dev/null || echo unknown)
    if [ "${STATE}" = "operating" ]; then
        echo "  加载成功！state=${STATE}"
        break
    fi
    COUNT=$((COUNT + 1))
    sleep 1
done

STATE=$(cat "${FPGA_MGR}/state" 2>/dev/null || echo unknown)
if [ "${STATE}" != "operating" ]; then
    echo "[ERROR] 加载超时或失败，最终 state=${STATE}"
    echo "--- recent fpga dmesg ---"
    dmesg | grep -iE 'fpga_manager|fpga0' | tail -10 || true
    dmesg | tail -30
    exit 1
fi

echo ""
echo "[Step 5] 活体探测（未定义地址应返回 0xDEADBEEF）"
if command -v devmem >/dev/null 2>&1; then
    # 先确认 pl_clk0 使能（CRL_APB PL0_REF_CTRL）
    PL0=$(devmem 0xFF5E00C0 32 2>/dev/null || echo READ_FAILED)
    echo "  PL0_REF_CTRL @ 0xFF5E00C0 = ${PL0}  (期望 0x01010402)"
    PROBE=$(devmem 0x80050FFC 32 2>/dev/null || echo READ_FAILED)
    echo "  PROBE @ 0x80050FFC = ${PROBE}  (期望 0xDEADBEEF)"
    STATUS=$(devmem 0x80050004 32 2>/dev/null || echo READ_FAILED)
    echo "  STATUS_REG @ 0x80050004 = ${STATUS}"
    if [ "${PROBE}" != "0xDEADBEEF" ] && [ "${PROBE}" != "0xdeadbeef" ]; then
        echo "  [WARN] 活体探测未返回 DEADBEEF — 检查时钟/地址映射"
    fi
else
    echo "  [SKIP] devmem 不可用"
fi

echo ""
echo "======================================================"
echo "  加载完成！fpga0 state = operating"
echo "  下一步：运行 ./test_app 进行功能验证"
echo "======================================================"
