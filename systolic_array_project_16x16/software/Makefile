# =============================================================
# 文件名  : Makefile
# 描述    : test_app 编译 Makefile
#           支持两种模式：
#           1. 交叉编译（WSL2 PC 端）→ 生成 ARM64 可执行文件
#           2. 原生编译（板卡 ARM 端）→ 直接在板卡上 gcc 编译
# =============================================================
# 使用方法：
#   # 方式 1：在 WSL2 PC 端交叉编译
#   make CROSS=1
#   scp test_app root@<board_ip>:/home/root/
#
#   # 方式 2：在板卡 ARM 上原生编译（板卡上有 gcc）
#   make
#   ./test_app
#
#   # 清理
#   make clean
# =============================================================

# 目标文件名
TARGET = test_app

# 源文件
SRC    = test_app.c

# 编译选项
CFLAGS = -O2 -Wall -Wextra -std=c99

# 链接选项
LDFLAGS =

# ── 编译器选择 ────────────────────────────────────────────────
# 默认：板卡原生编译（假设板卡已有 gcc）
ifeq ($(CROSS), 1)
    # 交叉编译：在 WSL2 PC 端生成 ARM64 二进制
    # 需要先安装：sudo apt-get install gcc-aarch64-linux-gnu
    CC = aarch64-linux-gnu-gcc
    $(info [INFO] 交叉编译模式: CC=$(CC))
else
    # 原生编译：在板卡 ARM Linux 上运行
    CC = gcc
    $(info [INFO] 原生编译模式: CC=$(CC))
endif

# ── 编译规则 ──────────────────────────────────────────────────
.PHONY: all clean check install help

all: $(TARGET)
	@echo ""
	@echo "编译完成: $(TARGET)"
	@file $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

# ── 检查交叉编译工具链 ────────────────────────────────────────
check:
ifeq ($(CROSS), 1)
	@which aarch64-linux-gnu-gcc || \
	    (echo "[ERROR] 交叉编译工具链未安装"; \
	     echo "        安装命令：sudo apt-get install gcc-aarch64-linux-gnu"; \
	     exit 1)
	@echo "[OK] aarch64-linux-gnu-gcc 已安装"
	@aarch64-linux-gnu-gcc --version
else
	@which gcc || (echo "[ERROR] gcc 未安装"; exit 1)
	@echo "[OK] gcc 已安装"
	@gcc --version | head -1
endif

# ── 拷贝到板卡（需设置 BOARD_IP）─────────────────────────────
# 用法：make install BOARD_IP=<host_ip>0
install: $(TARGET)
ifndef BOARD_IP
	@echo "[ERROR] 请指定板卡 IP：make install BOARD_IP=<host_ip>0"
	@exit 1
endif
	scp $(TARGET) root@$(BOARD_IP):/home/root/
	@echo "已传输到板卡：root@$(BOARD_IP):/home/root/$(TARGET)"

# ── 清理 ─────────────────────────────────────────────────────
clean:
	rm -f $(TARGET) *.o

# ── 帮助 ─────────────────────────────────────────────────────
help:
	@echo "========================================================"
	@echo "  test_app Makefile 使用说明（ACU4EV 移植版）"
	@echo "========================================================"
	@echo "  make              # 板卡原生编译（在板卡上运行）"
	@echo "  make CROSS=1      # WSL2 PC 端交叉编译（生成 ARM64）"
	@echo "  make check        # 检查工具链"
	@echo "  make install BOARD_IP=<board_ip>   # 传输到板卡（DHCP典型IP）"
	@echo "  make clean        # 清理"
	@echo ""
	@echo "  板卡运行（本版本通过 /dev/mem 访问寄存器，需 root）："
	@echo "    sudo ./test_app                          # 直接运行"
	@echo "    ./test_app 2>&1 | tee board_result.txt  # 保存日志"
	@echo "    （提示：加载 bit 前必须先运行"
	@echo "     scripts/board_load_gemm.sh 确认 fpga0 state=operating）"
	@echo "  PC 端验证："
	@echo "    python3 ../python/golden_model.py --test_id 0 --mode board"
	@echo "========================================================"
