# =============================================================
# 文件名  : Makefile
# 描述    : test_app 编译 Makefile
#           1. 交叉编译（WSL2 PC 端，Vitis 2020.1 工具链）
#           2. 原生编译（板卡 ARM 端）
# =============================================================
# 使用方法：
#   make CROSS=1
#   make CROSS=1 install BOARD_IP=<board_ip>
#   make            # 板卡原生编译
# =============================================================

TARGET = test_app
SRC    = test_app.c
CFLAGS = -O2 -Wall -Wextra -std=c99
LDFLAGS =

# Vitis 2020.1 自带 aarch64-linux-gnu-gcc（WSL 默认 PATH 上没有）
VITIS_GCC ?= /tools/Xilinx/Vitis/2020.1/gnu/aarch64/lin/aarch64-linux/bin/aarch64-linux-gnu-gcc

ifeq ($(CROSS), 1)
    ifneq ($(wildcard $(VITIS_GCC)),)
        CC = $(VITIS_GCC)
    else ifneq ($(shell which aarch64-linux-gnu-gcc 2>/dev/null),)
        CC = aarch64-linux-gnu-gcc
    else
        $(error 交叉编译器未找到。请确认 Vitis 路径: $(VITIS_GCC))
    endif
    $(info [INFO] 交叉编译模式: CC=$(CC))
else
    CC = gcc
    $(info [INFO] 原生编译模式: CC=$(CC))
endif

.PHONY: all clean check install help

all: $(TARGET)
	@echo ""
	@echo "编译完成: $(TARGET)"
	@file $(TARGET) || true

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

check:
ifeq ($(CROSS), 1)
	@test -x "$(CC)" || (echo "[ERROR] 找不到 $(CC)"; exit 1)
	@echo "[OK] $(CC)"
	@$(CC) --version | head -1
else
	@which gcc || (echo "[ERROR] gcc 未安装"; exit 1)
	@gcc --version | head -1
endif

# 用法：make CROSS=1 install BOARD_IP=10.0.0.50
install: $(TARGET)
ifndef BOARD_IP
	@echo "[ERROR] 请指定板卡 IP：make install BOARD_IP=<board_ip>"
	@exit 1
endif
	scp -o ConnectTimeout=8 $(TARGET) root@$(BOARD_IP):/tmp/gemm_bench/
	@echo "已传输到板卡：root@$(BOARD_IP):/tmp/gemm_bench/$(TARGET)"

clean:
	rm -f $(TARGET) *.o

help:
	@echo "========================================================"
	@echo "  test_app Makefile（ACU4EV / edgeai_acu4ev）"
	@echo "========================================================"
	@echo "  make CROSS=1                         # WSL 交叉编译"
	@echo "  make CROSS=1 check                   # 检查工具链"
	@echo "  make CROSS=1 install BOARD_IP=<board_ip>"
	@echo "  make                                 # 板卡原生编译"
	@echo "  make clean"
	@echo ""
	@echo "  板卡运行（需 root，加载 bit 后）："
	@echo "    ./test_app 2>&1 | tee board_result.txt"
	@echo "========================================================"
