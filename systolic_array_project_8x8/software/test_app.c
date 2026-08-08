/* =============================================================
 * 文件名  : test_app.c
 * 描述    : 板卡 ARM 端验证程序（PetaLinux 2020.1 运行，ACU4EV 优化版）
 *           通过 /dev/mem 直接 mmap 访问 PL 端脉动阵列寄存器，
 *           并可选择将每轮"预测结果"通过以太网上传至上位机（PS→ETH）。
 *
 * 【本版本相对上一移植版的优化】
 *   1. PL 端加速 + PS 端以太网上传结果（对应需求1）：
 *      计算完成后，若指定了 --host，则通过 TCP Socket 将结果以
 *      JSON Lines 协议发送给上位机（配合 python/host_eth_receiver.py
 *      使用）。协议细节见文件末尾 eth_upload_result() 的注释。
 *      　　【重要】用户要求参考其 GitHub imgproc 工程的以太网配置，
 *      但该仓库内容不在本次对话上下文中，我没有权限访问任意用户的
 *      私有/外部 GitHub 仓库，因此这里实现的是一套通用、可直接工作
 *      的参考方案（原始 TCP + 换行分隔 JSON），并在协议层做了清晰
 *      注释，方便你对照 imgproc 的实际配置（IP/端口约定、粘包协议、
 *      重连策略等）做针对性替换。如果你把 imgproc 里 eth 配置相关的
 *      代码片段或说明发给我，我可以在下一轮直接对齐改造。
 *   2. 脉动阵列规模由 4x4 提升为 8x8（对应需求2）：
 *      对照 porting_env_hardware_config.md 记录的板卡资源余量
 *      （LUT 88,000 / DSP48E2 728，原 4x4 设计仅用 16 个 DSP≈2.2%），
 *      RTL 侧已重构为参数化设计（rtl/axi_ctrl_top.v 的 ARRAY_SIZE），
 *      本文件同步更新寄存器偏移公式和测试数据为 8x8。
 *   3. 【重要 bug 修复】原设计里 ctrl_fsm 的 done 信号只维持 1 个时钟
 *      周期（@100MHz 即 10ns），而 ARM 端软件轮询 /dev/mem 的单次开销
 *      是微秒级，几乎必然错过这个瞬间脉冲，会导致本程序永久卡死在
 *      等待 done 的轮询循环里。此问题已在 rtl/ctrl_fsm.v 修复为电平
 *      保持型 done（详见该文件头部注释），本程序的轮询逻辑无需改动，
 *      但如果你在旧 bitstream 上运行本程序，会出现卡死，请确认已用
 *      新 bitstream 重新综合。
 *
 * 编译    : 在板卡上：gcc -O2 -o test_app test_app.c
 *           交叉编译：aarch64-linux-gnu-gcc -O2 -o test_app test_app.c
 * 运行    : sudo ./test_app                                    # 仅本地验证，不上传
 *           sudo ./test_app --host <host_ip> --port 9000    # 本地验证 + 以太网上传
 *           sudo ./test_app --test_id 2                        # 只跑第 2 组测试向量
 *           sudo ./test_app 2>&1 | tee board_result.txt        # 保存日志供 golden_model.py --mode board 使用
 *
 * 寄存器映射（公式化，与 rtl/axi_ctrl_top.v 完全一致，基地址 0x8005_0000）：
 *   字索引 0                       CTRL_REG    (R/W) bit0=start
 *   字索引 1                       STATUS_REG  (R)   bit0=done, bit1=busy
 *   字索引 [2 .. 2+N-1]             RESULT_0..N-1 (R)
 *   字索引 [2+N .. 2+2N-1]          DATA_IN_0..N-1 (R/W)
 *   字索引 [2+2N .. 2+2N+N*N-1]     WEIGHT_00..N-1,N-1 (R/W, 行主序)
 *   （N = 8，与本文件 ARRAY_SIZE 宏一致）
 * ============================================================= */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>
#include <time.h>

/* ── 阵列规模（须与当前烧录的 bitstream 一致）─────────────────── */
#define ARRAY_SIZE        8
#define NUM_TEST_VECTORS  5

/* ── 外设物理基地址（ACU4EV 有效孔径 0x8000_0000 [512M] 内）───── */
#define AXI_CTRL_BASE_PHYS  0x80050000UL
#define AXI_CTRL_MAP_SIZE   0x10000UL

/* ── 寄存器字索引公式（须与 rtl/axi_ctrl_top.v 的 localparam 一致）─
 * RESULT_BASE = 2
 * DATA_BASE   = RESULT_BASE + ARRAY_SIZE
 * WEIGHT_BASE = DATA_BASE   + ARRAY_SIZE
 * ──────────────────────────────────────────────────────────────── */
#define REG_CTRL_IDX        0
#define REG_STATUS_IDX      1
#define REG_RESULT_BASE_IDX 2
#define REG_DATA_BASE_IDX   (REG_RESULT_BASE_IDX + ARRAY_SIZE)
#define REG_WEIGHT_BASE_IDX (REG_DATA_BASE_IDX   + ARRAY_SIZE)

#define REG_CTRL_OFF          (REG_CTRL_IDX   * 4U)
#define REG_STATUS_OFF        (REG_STATUS_IDX * 4U)
#define REG_RESULT_OFF(i)     ((REG_RESULT_BASE_IDX + (uint32_t)(i)) * 4U)
#define REG_DATA_OFF(i)       ((REG_DATA_BASE_IDX   + (uint32_t)(i)) * 4U)
#define REG_WEIGHT_OFF(i,j)   ((REG_WEIGHT_BASE_IDX + (uint32_t)(i)*ARRAY_SIZE + (uint32_t)(j)) * 4U)

/* ── 状态位掩码 ───────────────────────────────────────────────── */
#define STATUS_DONE     (1U << 0)
#define STATUS_BUSY     (1U << 1)
#define CTRL_START      (1U << 0)

#define DEVMEM_PATH     "/dev/mem"
#define POLL_TIMEOUT    200000

/* ── 5 组测试向量（与 python/golden_model.py --array_size 8 完全一致，
 * seed=42），逐一跑一遍即模拟"批量预测"场景，便于演示以太网批量上传 ── */
static const int8_t TEST_A[NUM_TEST_VECTORS][ARRAY_SIZE] = {
    { 7, -91, 88, -107, 76, 122, -96, 69 },  /* test_id=0 */
    { -88, -3, -53, -14, -88, -113, -106, -1 },  /* test_id=1 */
    { 111, 33, 94, 82, -85, 56, 88, -59 },  /* test_id=2 */
    { -68, 56, -75, -118, 31, 121, 106, 10 },  /* test_id=3 */
    { -89, 8, -63, -96, -72, -120, 60, 46 },  /* test_id=4 */
};

static const int8_t TEST_B[NUM_TEST_VECTORS][ARRAY_SIZE][ARRAY_SIZE] = {
    { /* test_id=0 */
        { 64, 126, 16, 38, -32, -43, -39, -17 },
        { -93, -107, 89, -19, 65, -111, 76, 90 },
        { 12, 7, -107, -115, 53, 5, 49, 106 },
        { 0, 18, -78, 52, -128, -101, -105, 11 },
        { -46, 70, 5, 108, -31, 65, 120, -16 },
        { -61, -39, 59, -82, -116, 89, 65, -65 },
        { 22, 43, 54, 34, 1, -70, 72, -110 },
        { 80, -31, 2, -107, -115, 75, -97, -19 },
    },
    { /* test_id=1 */
        { 10, 29, 107, -35, 46, 17, 58, -83 },
        { -27, -9, -65, 108, -123, 77, -109, 71 },
        { -80, -41, 83, 35, 53, 31, -125, -26 },
        { -52, 0, 31, 81, -94, -67, 32, 10 },
        { 73, 22, 2, -16, -71, -48, -48, -14 },
        { -99, -48, -85, -71, -95, -73, 21, -106 },
        { 66, -61, 120, 12, 46, 62, -53, 98 },
        { 98, -46, -43, -113, -19, 121, 55, 90 },
    },
    { /* test_id=2 */
        { -113, 65, 51, 32, 116, -14, -53, -87 },
        { 66, -120, -111, 65, -98, -8, -44, 50 },
        { 61, -75, 65, -39, 8, -77, -30, -112 },
        { -20, 41, -2, 119, -69, 18, -105, -15 },
        { 118, 20, 34, 99, 47, -104, 11, 44 },
        { -114, -93, -61, 70, -113, 68, 7, 65 },
        { 35, 86, 82, -80, -106, 113, -89, -36 },
        { -106, -122, -6, -10, -72, -61, -18, -2 },
    },
    { /* test_id=3 */
        { -95, 3, -2, -90, -86, 97, -52, 61 },
        { 82, -54, 91, 45, 83, 71, -87, 107 },
        { 13, 58, 39, 61, -118, -54, 91, -36 },
        { 66, 54, 45, 118, -95, -4, -84, -24 },
        { -24, -55, -24, -46, -95, -80, 80, 102 },
        { 0, -15, 85, -35, -98, -71, 10, -110 },
        { -60, 78, -77, -9, 79, 45, 48, 74 },
        { 105, -80, 0, -81, 117, -60, 2, -11 },
    },
    { /* test_id=4 */
        { -53, 75, 70, -8, -76, 62, 6, -45 },
        { -88, 58, -107, -71, 38, -113, 2, 15 },
        { -112, 109, -9, 42, -7, 101, 54, 111 },
        { -87, -81, 104, -18, -128, 91, -95, -88 },
        { 115, -28, -87, 84, 54, -70, -73, 32 },
        { 94, 17, -61, 50, -66, 87, 98, -105 },
        { 28, -63, 118, -50, -76, -22, 16, 67 },
        { -13, 121, -115, 84, -119, -37, -23, -18 },
    },
};

static const int32_t GOLDEN[NUM_TEST_VECTORS][ARRAY_SIZE] = {
    { 2437, 3604, -6525, -26132, -12318, 48740, 11803, -55 },  /* test_id=0 */
    { 1838, 9648, -17302, 8039, 6954, 3348, 8814, 11061 },  /* test_id=1 */
    { -13351, 7425, 9208, 844, -10667, 18611, -26078, -22915 },  /* test_id=2 */
    { -3765, -10002, -1624, -17284, 25297, -4999, 10549, 4962 },  /* test_id=3 */
    { 943, -3540, -1129, -11958, 13795, -29943, -1402, 19068 },  /* test_id=4 */
};

/* ── 寄存器读写内联函数 ────────────────────────────────────────── */
static inline void reg_write(volatile uint32_t *base, uint32_t offset, uint32_t value)
{
    *(volatile uint32_t *)((uint8_t *)base + offset) = value;
}
static inline uint32_t reg_read(volatile uint32_t *base, uint32_t offset)
{
    return *(volatile uint32_t *)((uint8_t *)base + offset);
}

static void print_separator(void) { printf("======================================================\n"); }

/* =============================================================
 * 以太网结果上传（需求1：PL 加速 + PS 端以太网上传训练/预测结果）
 *
 * 协议设计（通用参考实现，非 imgproc 原始协议 —— 见文件头说明）：
 *   传输层：TCP，一次性短连接（每条结果建立/发送/关闭一次，简单可靠，
 *           不需要维护长连接状态机，适合低频结果上报场景）
 *   应用层：单行 JSON（newline-delimited JSON / JSON Lines），
 *           字段：
 *             seq        : 本次程序运行内的发送序号（从1开始）
 *             test_id    : 对应 golden_model.py 的测试向量编号
 *             array_size : 脉动阵列规模 N
 *             result     : 长度为 N 的 INT32 结果数组
 *             pass       : 板端与内置 GOLDEN 表比对的 PASS/FAIL
 *             ts         : Unix 时间戳（秒）
 *   host_eth_receiver.py 按行读取、JSON 解析、落盘 eth_results.jsonl，
 *   golden_model.py --mode eth 可据此做二次交叉验证。
 *
 *   连接超时保护：SO_SNDTIMEO/SO_RCVTIMEO 设为 3 秒，避免上位机不可达
 *   时导致板端永久阻塞（对照 porting_env_hardware_config.md 安全守则
 *   "禁止长时间阻塞板端" 的精神）。上传失败仅打印警告、不影响本地
 *   计算流程继续（网络问题不应影响 PL 计算结果的本地可用性）。
 * ============================================================= */
static int eth_upload_result(const char *host, int port, int seq, int test_id,
                              const int32_t *result, int n, int pass_flag)
{
    int sock;
    struct sockaddr_in addr;
    char json_buf[1024];
    int json_len;
    int i;
    struct timeval tv;
    ssize_t sent;

    sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        perror("[ETH] socket() 失败");
        return -1;
    }

    tv.tv_sec = 3;
    tv.tv_usec = 0;
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        fprintf(stderr, "[ETH] 无效的上位机 IP: %s\n", host);
        close(sock);
        return -1;
    }

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("[ETH] connect() 失败");
        fprintf(stderr, "[ETH]   请确认上位机 python/host_eth_receiver.py 已启动，\n");
        fprintf(stderr, "[ETH]   且板卡与上位机在同一网段（板卡典型IP <board_ip>）\n");
        close(sock);
        return -1;
    }

    /* 手工拼接 JSON（板端 rootfs 精简、无 pip3，不假设有第三方 JSON 库） */
    json_len = snprintf(json_buf, sizeof(json_buf),
        "{\"seq\":%d,\"test_id\":%d,\"array_size\":%d,\"result\":[",
        seq, test_id, ARRAY_SIZE);
    for (i = 0; i < n && json_len < (int)sizeof(json_buf) - 1; i++) {
        json_len += snprintf(json_buf + json_len, sizeof(json_buf) - json_len,
            "%s%d", (i == 0 ? "" : ","), result[i]);
    }
    json_len += snprintf(json_buf + json_len, sizeof(json_buf) - json_len,
        "],\"pass\":%s,\"ts\":%ld}\n",
        pass_flag ? "true" : "false", (long)time(NULL));

    sent = send(sock, json_buf, (size_t)json_len, 0);
    close(sock);

    if (sent != json_len) {
        fprintf(stderr, "[ETH] 发送不完整 (sent=%zd, expected=%d)\n", sent, json_len);
        return -1;
    }
    return 0;
}

static void print_usage(const char *prog)
{
    printf("用法: %s [选项]\n", prog);
    printf("  --host <IP>       上位机 IP，指定后启用以太网结果上传\n");
    printf("  --port <PORT>     上位机监听端口（默认 9000）\n");
    printf("  --test_id <N>     只运行第 N 组测试向量（默认运行全部 %d 组）\n", NUM_TEST_VECTORS);
    printf("  --help            显示本帮助\n");
    printf("\n示例:\n");
    printf("  %s                                  # 仅本地验证\n", prog);
    printf("  %s --host <host_ip> --port 9000  # 本地验证 + 以太网上传\n", prog);
}

int main(int argc, char **argv)
{
    const char *eth_host = NULL;
    int   eth_port = 9000;
    int   only_test_id = -1;
    int   mem_fd = -1;
    volatile uint32_t *base_addr = NULL;
    long   page_size, page_offset;
    off_t  page_base;
    int    ret = 0;
    int    t, i, j;
    int    total_pass = 0, total_fail = 0, seq = 0;

    /* ── 命令行参数解析 ─────────────────────────────────────────── */
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--host") == 0 && i + 1 < argc) {
            eth_host = argv[++i];
        } else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            eth_port = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--test_id") == 0 && i + 1 < argc) {
            only_test_id = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return EXIT_SUCCESS;
        }
    }

    print_separator();
    printf("  INT8 脉动阵列 GEMM (%dx%d) - 板卡验证程序（ACU4EV 优化版）\n", ARRAY_SIZE, ARRAY_SIZE);
    printf("  平台: ACU4EV (XCZU4EV)  PetaLinux 2020.1\n");
    printf("  访问方式: /dev/mem 直接映射（无需 UIO/PYNQ）\n");
    printf("  寄存器基地址: 0x%08lX\n", AXI_CTRL_BASE_PHYS);
    if (eth_host)
        printf("  以太网上传: 启用 -> %s:%d\n", eth_host, eth_port);
    else
        printf("  以太网上传: 未启用（加 --host <IP> 开启）\n");
    print_separator();

    /* ── 打开 /dev/mem 并 mmap ─────────────────────────────────── */
    mem_fd = open(DEVMEM_PATH, O_RDWR | O_SYNC);
    if (mem_fd < 0) {
        perror("[ERROR] open /dev/mem 失败");
        printf("        请用 root 权限运行: sudo %s\n", argv[0]);
        return EXIT_FAILURE;
    }

    page_size   = sysconf(_SC_PAGESIZE);
    page_base   = AXI_CTRL_BASE_PHYS & ~((off_t)page_size - 1);
    page_offset = AXI_CTRL_BASE_PHYS - page_base;

    base_addr = (volatile uint32_t *)mmap(NULL, AXI_CTRL_MAP_SIZE + page_offset,
        PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, page_base);
    if (base_addr == MAP_FAILED) {
        perror("[ERROR] mmap 失败");
        printf("        可能原因: bitstream 未加载 (检查 fpga0 state)，\n");
        printf("        或地址 0x%08lX 超出板卡有效 PL 控制孔径\n", AXI_CTRL_BASE_PHYS);
        close(mem_fd);
        return EXIT_FAILURE;
    }
    base_addr = (volatile uint32_t *)((uint8_t *)base_addr + page_offset);
    printf("  mmap 成功，虚拟地址: %p\n\n", (void *)base_addr);

    /* ── 依次运行测试向量（模拟"批量预测"场景）───────────────────── */
    for (t = 0; t < NUM_TEST_VECTORS; t++) {
        int32_t results[ARRAY_SIZE];
        uint32_t status;
        int timeout, pass;

        if (only_test_id >= 0 && t != only_test_id)
            continue;

        printf("---- test_id=%d ----\n", t);

        /* 加载权重矩阵 B */
        for (i = 0; i < ARRAY_SIZE; i++)
            for (j = 0; j < ARRAY_SIZE; j++)
                reg_write(base_addr, REG_WEIGHT_OFF(i, j), (uint32_t)(uint8_t)TEST_B[t][i][j]);

        /* 加载数据向量 A */
        for (i = 0; i < ARRAY_SIZE; i++)
            reg_write(base_addr, REG_DATA_OFF(i), (uint32_t)(uint8_t)TEST_A[t][i]);

        /* 触发计算 */
        reg_write(base_addr, REG_CTRL_OFF, CTRL_START);

        /* 轮询 done（电平保持型信号，已修复原单拍脉冲丢失问题） */
        timeout = 0;
        do {
            status = reg_read(base_addr, REG_STATUS_OFF);
            timeout++;
            if (timeout >= POLL_TIMEOUT) {
                printf("[ERROR] test_id=%d 超时！STATUS=0x%08X\n", t, status);
                printf("        请确认 bitstream 已加载: cat /sys/class/fpga_manager/fpga0/state\n");
                ret = EXIT_FAILURE;
                goto cleanup;
            }
        } while (!(status & STATUS_DONE));

        /* 读取结果并比对 */
        pass = 1;
        for (i = 0; i < ARRAY_SIZE; i++) {
            results[i] = (int32_t)reg_read(base_addr, REG_RESULT_OFF(i));
            if (results[i] != GOLDEN[t][i]) pass = 0;
            /* golden_model.py --mode board 解析格式 */
            printf("RESULT_%d: %d\n", i, results[i]);
        }

        if (pass) {
            printf("  [PASS] test_id=%d 与内置 GOLDEN 表完全一致\n", t);
            total_pass++;
        } else {
            printf("  [FAIL] test_id=%d 结果不匹配\n", t);
            total_fail++;
        }

        /* 以太网上传（若启用） */
        if (eth_host) {
            seq++;
            if (eth_upload_result(eth_host, eth_port, seq, t, results, ARRAY_SIZE, pass) == 0)
                printf("  [ETH] 已上传 test_id=%d -> %s:%d\n", t, eth_host, eth_port);
            else
                printf("  [ETH] 警告: test_id=%d 上传失败（不影响本地结果，继续下一组）\n", t);
        }
        printf("\n");
    }

    print_separator();
    printf("  汇总: %d PASS, %d FAIL (共 %d 组)\n", total_pass, total_fail, total_pass + total_fail);
    if (total_fail == 0) {
        printf("  *** 全部测试通过 — 上板验证 PASS ***\n");
    } else {
        printf("  *** 存在失败用例 — 请检查 RTL / bitstream / 地址映射 ***\n");
        ret = EXIT_FAILURE;
    }
    print_separator();

cleanup:
    if (base_addr && base_addr != MAP_FAILED)
        munmap((void *)((uint8_t *)base_addr - page_offset), AXI_CTRL_MAP_SIZE + page_offset);
    if (mem_fd >= 0)
        close(mem_fd);

    return ret;
}
