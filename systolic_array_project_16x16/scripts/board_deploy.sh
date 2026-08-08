#!/bin/bash
# =============================================================
# board_deploy.sh — 一键部署到 ACU4EV（WSL 内执行）
# 用法: BOARD_IP=<board_ip> bash scripts/board_deploy.sh
# =============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOARD_IP="${BOARD_IP:?请设置 BOARD_IP，例如 BOARD_IP=<board_ip>}"
HOST_IP="${HOST_IP:-<host_ip>}"
# PetaLinux 2020.1's Dropbear commonly exposes only an ssh-rsa host key.
SSH_OPTS=(-o ConnectTimeout=8 -o StrictHostKeyChecking=no -o HostKeyAlgorithms=+ssh-rsa)

# Set SSHPASS in the invoking environment when password authentication is
# required (for example: SSHPASS='<password>' BOARD_IP=<board_ip> bash scripts/board_deploy.sh).
# Leaving it unset preserves the usual interactive/key-based SSH behaviour.
if [ -n "${SSHPASS:-}" ]; then
    command -v sshpass >/dev/null 2>&1 || {
        echo "[ERROR] SSHPASS is set but sshpass is unavailable" >&2
        exit 2
    }
    SSH_CMD=(sshpass -e ssh "${SSH_OPTS[@]}")
    SCP_CMD=(sshpass -e scp "${SSH_OPTS[@]}")
else
    SSH_CMD=(ssh "${SSH_OPTS[@]}")
    SCP_CMD=(scp "${SSH_OPTS[@]}")
fi

# Artifacts live in each variant's own deploy/ directory.
DEPLOY_DIR="${PROJECT_DIR}/deploy"

BITSTREAM="${DEPLOY_DIR}/systolic_gemm_accel.bit"
TEST_APP="${DEPLOY_DIR}/test_app"
LOAD_SCRIPT="${SCRIPT_DIR}/board_load_gemm.sh"

for artifact in "${BITSTREAM}" "${TEST_APP}" "${LOAD_SCRIPT}"; do
    if [ ! -f "${artifact}" ]; then
        echo "[ERROR] Missing deployment artifact: ${artifact}" >&2
        exit 2
    fi
done

echo "======================================================"
echo " Deploy GEMM accel -> root@${BOARD_IP}"
echo "======================================================"

"${SSH_CMD[@]}" root@${BOARD_IP} "mkdir -p /tmp/gemm_bench /lib/firmware"

"${SCP_CMD[@]}" \
    "${BITSTREAM}" \
    "${LOAD_SCRIPT}" \
    "${TEST_APP}" \
    root@${BOARD_IP}:/tmp/gemm_bench/

"${SSH_CMD[@]}" root@${BOARD_IP} "chmod +x /tmp/gemm_bench/test_app /tmp/gemm_bench/board_load_gemm.sh"

echo ""
echo "[Preflight] PL0_REF_CTRL before load"
"${SSH_CMD[@]}" root@${BOARD_IP} "devmem 0xFF5E00C0 32 || true"

echo ""
echo "[Load] fpga_manager"
"${SSH_CMD[@]}" root@${BOARD_IP} "cd /tmp/gemm_bench && FORCE_PL_RELOAD=1 sh board_load_gemm.sh systolic_gemm_accel.bit"

echo ""
echo "[Run] test_app (all 5 vectors)"
"${SSH_CMD[@]}" root@${BOARD_IP} "cd /tmp/gemm_bench && ./test_app 2>&1 | tee board_result.txt"

echo ""
echo "[Fetch] board_result.txt"
"${SCP_CMD[@]}" root@${BOARD_IP}:/tmp/gemm_bench/board_result.txt \
    "${DEPLOY_DIR}/board_result.txt"

echo "======================================================"
echo " Local verify:"
echo "   python python/golden_model.py --array_size 8 --test_id 0 --mode board"
echo " Ethernet (optional):"
echo "   python python/host_eth_receiver.py --port 9000 --array_size 8"
echo "   ssh root@${BOARD_IP} 'cd /tmp/gemm_bench && ./test_app --host ${HOST_IP} --port 9000'"
echo "======================================================"
