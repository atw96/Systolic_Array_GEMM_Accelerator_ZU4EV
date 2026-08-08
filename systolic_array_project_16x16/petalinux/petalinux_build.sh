#!/bin/bash
# =============================================================
# 文件名  : petalinux_build.sh
# 描述    : PetaLinux 2020.1 自动化构建脚本（ACU4EV 真实硬件移植版）
# 平台    : WSL2 Ubuntu 18.04 + ALINX ACU4EV (XCZU4EV)
# 运行    : bash petalinux_build.sh --xsa deploy/systolic_gemm_accel.xsa
#
# 【重要】本脚本只需运行【一次】，用于构建带有 fpga_manager +
# /dev/mem 支持的基础 PetaLinux 系统并烧录 SD 卡。之后每次 RTL /
# bitstream 迭代，不需要重跑本脚本，改用 scripts/board_load_gemm.sh
# 通过 fpga_manager 秒级动态加载即可（详见 PETALINUX_GUIDE.md Step 9）。
# =============================================================

set -e

# ── 默认参数 ──────────────────────────────────────────────────
# 【ACU4EV 移植说明】真实环境路径为 /opt/pkg/petalinux/settings.sh
# （无版本子目录），与早期假设的 .../2020.1/settings.sh 不同。
# 这里自动探测两种可能路径，优先使用真实环境路径。
if [ -f "/opt/pkg/petalinux/settings.sh" ]; then
    PETALINUX_SETTINGS="/opt/pkg/petalinux/settings.sh"
elif [ -f "/opt/pkg/petalinux/2020.1/settings.sh" ]; then
    PETALINUX_SETTINGS="/opt/pkg/petalinux/2020.1/settings.sh"
else
    PETALINUX_SETTINGS="/opt/pkg/petalinux/settings.sh"  # 默认值，供下方报错提示
fi
PROJ_NAME="systolic_gemm_proj"
# 【ACU4EV 移植说明】WSL 工程根路径规范为 $HOME/work/<project>
# （禁止用 /mnt/<windows_drive>/... 做综合/构建）。若当前主机无该用户目录，回退到 $HOME。
if [ -d "$HOME/work" ]; then
    PROJ_DIR="$HOME/work/${PROJ_NAME}"
else
    PROJ_DIR="${HOME}/fpga_projects/${PROJ_NAME}"
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
XSA_FILE=""

# ── 参数解析 ──────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --xsa)   XSA_FILE="$2"; shift 2 ;;
        --proj)  PROJ_DIR="$2"; shift 2 ;;
        --help)
            echo "用法: bash petalinux_build.sh --xsa <path/to/file.xsa>"
            echo "      --proj <工程目录> (可选，默认 ~/fpga_projects/${PROJ_NAME})"
            exit 0 ;;
        *) echo "[WARN] 未知参数: $1"; shift ;;
    esac
done

if [ -z "${XSA_FILE}" ]; then
    echo "[ERROR] 必须指定 XSA 文件路径: --xsa /path/to/file.xsa"
    echo "        XSA 由 Vivado → File → Export Hardware (Include Bitstream) 生成"
    exit 1
fi

if [ ! -f "${XSA_FILE}" ]; then
    echo "[ERROR] XSA 文件不存在: ${XSA_FILE}"
    exit 1
fi

echo "======================================================"
echo "  PetaLinux 2020.1 自动化构建"
echo "  XSA: ${XSA_FILE}"
echo "  工程目录: ${PROJ_DIR}"
echo "======================================================"

# ── Step 1：初始化 PetaLinux 环境 ─────────────────────────────
echo ""
echo "[Step 1] 初始化 PetaLinux 环境..."
if [ ! -f "${PETALINUX_SETTINGS}" ]; then
    echo "[ERROR] PetaLinux 2020.1 未找到: ${PETALINUX_SETTINGS}"
    exit 1
fi
source "${PETALINUX_SETTINGS}"
echo "  PETALINUX=${PETALINUX}"

# ── Step 2：创建工程 ───────────────────────────────────────────
echo ""
echo "[Step 2] 创建 PetaLinux ZynqMP 工程..."
mkdir -p "$(dirname "${PROJ_DIR}")"
if [ -d "${PROJ_DIR}" ]; then
    echo "  工程已存在，跳过创建步骤"
else
    petalinux-create -t project --template zynqMP -n "${PROJ_NAME}" \
        --dir "$(dirname "${PROJ_DIR}")"
fi
cd "${PROJ_DIR}"

# ── Step 3：导入 XSA ──────────────────────────────────────────
echo ""
echo "[Step 3] 导入硬件描述文件 (XSA)..."
# 非交互式配置（跳过 menuconfig GUI）
petalinux-config --get-hw-description="${XSA_FILE}" --silentconfig
echo "  XSA 导入完成"

# ── Step 4：复制自定义设备树 ──────────────────────────────────
echo ""
echo "[Step 4] 配置 UIO 设备树..."
DTSI_DIR="project-spec/meta-user/recipes-bsp/device-tree/files"
mkdir -p "${DTSI_DIR}"
cp "${PROJECT_ROOT}/petalinux/system-user.dtsi" "${DTSI_DIR}/"
echo "  设备树已复制到: ${DTSI_DIR}/system-user.dtsi"

# ── Step 5：配置内核（启用 UIO，非交互）─────────────────────
echo ""
echo "[Step 5] 启用内核 UIO 驱动..."
# 写入内核 config fragment
KERNEL_FRAG="project-spec/meta-user/recipes-kernel/linux/linux-xlnx/user.cfg"
mkdir -p "$(dirname "${KERNEL_FRAG}")"
cat > "${KERNEL_FRAG}" << 'EOF'
# UIO 驱动（用户态直接访问 PL 寄存器）
CONFIG_UIO=y
CONFIG_UIO_PDRV_GENIRQ=y
EOF
echo "  内核 UIO 配置写入: ${KERNEL_FRAG}"

# 追加 bbappend（告诉 bitbake 包含 config fragment）
KERNEL_BBAPPEND="project-spec/meta-user/recipes-kernel/linux/linux-xlnx_%.bbappend"
if ! grep -q "user.cfg" "${KERNEL_BBAPPEND}" 2>/dev/null; then
    cat >> "${KERNEL_BBAPPEND}" << 'EOF'

# 包含用户自定义内核配置
FILESEXTRAPATHS_prepend := "${THISDIR}/linux-xlnx:"
SRC_URI_append = " file://user.cfg"
EOF
    echo "  bbappend 已更新: ${KERNEL_BBAPPEND}"
fi

# ── Step 6：完整构建 ──────────────────────────────────────────
echo ""
echo "[Step 6] 开始完整构建（约 60~120 分钟）..."
echo "  提示：可按 Ctrl+C 中断，再次运行本脚本会增量构建"
petalinux-build

# ── Step 7：打包启动文件 ──────────────────────────────────────
echo ""
echo "[Step 7] 打包 BOOT.BIN..."
# 查找 bitstream 文件
BIT_FILE=$(find images/linux -name "*.bit" 2>/dev/null | head -1)
if [ -n "${BIT_FILE}" ]; then
    echo "  使用 bitstream: ${BIT_FILE}"
    petalinux-package --boot \
        --fsbl  images/linux/zynqmp_fsbl.elf \
        --pmufw images/linux/pmufw.elf \
        --u-boot \
        --fpga  "${BIT_FILE}" \
        --force
else
    echo "  [WARN] 未找到 bitstream，生成不含 PL 配置的 BOOT.BIN"
    petalinux-package --boot \
        --fsbl  images/linux/zynqmp_fsbl.elf \
        --pmufw images/linux/pmufw.elf \
        --u-boot \
        --force
fi

# ── 输出摘要 ──────────────────────────────────────────────────
echo ""
echo "======================================================"
echo "  构建完成！"
echo ""
echo "  SD 卡文件（FAT32 分区）："
echo "    $(realpath images/linux/BOOT.BIN)"
echo "    $(realpath images/linux/image.ub)"
echo "    $(realpath images/linux/boot.scr)"
echo ""
echo "  根文件系统（ext4 分区）："
echo "    $(realpath images/linux/rootfs.tar.gz)"
echo ""
echo "  下一步：参考 PETALINUX_GUIDE.md → Step 7.8"
echo "======================================================"
