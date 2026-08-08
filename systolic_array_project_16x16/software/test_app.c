/* =============================================================
 * 文件名  : test_app.c
 * 描述    : 板卡 ARM 端验证程序（PetaLinux 2020.1 运行，ACU4EV 优化版）
 *           通过 /dev/mem 直接 mmap 访问 PL 端脉动阵列寄存器，
 *           并可选择将每轮"预测结果"通过以太网上传至上位机（PS→ETH）。
 *
 * 【本版本：ARRAY_SIZE = 16】
 *   对照 porting_env_hardware_config.md 记录的板卡资源余量
 *   （LUT 88,000 / DSP48E2 728），本版本阵列规模为 16x16，
 *   预计 DSP48E2 占用 256/728 ≈ 35.2%。
 *   RTL 侧 rtl/axi_ctrl_top.v 的 ARRAY_SIZE 参数须与本文件一致。
 *
 *   1. PL 端加速 + PS 端以太网上传结果：
 *      计算完成后，若指定了 --host，则通过 TCP Socket 将结果以
 *      JSON Lines 协议发送给上位机（配合 python/host_eth_receiver.py
 *      使用）。协议细节见文件末尾 eth_upload_result() 的注释。
 *      　　【重要】用户要求参考其 GitHub imgproc 工程的以太网配置，
 *      但该仓库内容不在本次对话上下文中，我没有权限访问任意用户的
 *      私有/外部 GitHub 仓库，因此这里实现的是一套通用、可直接工作
 *      的参考方案（原始 TCP + 换行分隔 JSON），并在协议层做了清晰
 *      注释，方便你对照 imgproc 的实际配置做针对性替换。
 *   2. 【重要 bug 修复】ctrl_fsm 的 done 信号已修复为电平保持型
 *      （详见 rtl/ctrl_fsm.v 头部注释），本程序轮询逻辑无需改动，
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
 *   （N = 16，与本文件 ARRAY_SIZE 宏一致）
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
#define ARRAY_SIZE        16
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

/* ── 5 组测试向量（与 python/golden_model.py --array_size 16 完全一致，
 * seed=42），逐一跑一遍即模拟"批量预测"场景，便于演示以太网批量上传 ── */
static const int8_t TEST_A[NUM_TEST_VECTORS][ARRAY_SIZE] = {
    { 7, -91, 88, -107, 76, 122, -96, 69, 64, 126, 16, 38, -32, -43, -39, -17 },  /* test_id=0 */
    { -60, 78, -77, -9, 79, 45, 48, 74, 105, -80, 0, -81, 117, -60, 2, -11 },  /* test_id=1 */
    { -10, 44, 98, -122, -85, 52, 116, -41, 119, 52, 75, -18, -51, 61, 19, 122 },  /* test_id=2 */
    { 26, 9, 35, 66, -21, 112, -102, 119, 1, -36, -11, -62, -97, -73, -37, 70 },  /* test_id=3 */
    { -53, -78, -117, -22, 111, -69, -9, -6, -51, -37, 19, -10, 121, -44, -32, 71 },  /* test_id=4 */
};

static const int8_t TEST_B[NUM_TEST_VECTORS][ARRAY_SIZE][ARRAY_SIZE] = {
    { /* test_id=0 */
        { -93, -107, 89, -19, 65, -111, 76, 90, 12, 7, -107, -115, 53, 5, 49, 106 },
        { 0, 18, -78, 52, -128, -101, -105, 11, -46, 70, 5, 108, -31, 65, 120, -16 },
        { -61, -39, 59, -82, -116, 89, 65, -65, 22, 43, 54, 34, 1, -70, 72, -110 },
        { 80, -31, 2, -107, -115, 75, -97, -19, 60, 120, 85, -88, -3, -53, -14, -88 },
        { -113, -106, -1, 10, 29, 107, -35, 46, 17, 58, -83, -27, -9, -65, 108, -123 },
        { 77, -109, 71, -80, -41, 83, 35, 53, 31, -125, -26, -52, 0, 31, 81, -94 },
        { -67, 32, 10, 73, 22, 2, -16, -71, -48, -48, -14, -99, -48, -85, -71, -95 },
        { -73, 21, -106, 66, -61, 120, 12, 46, 62, -53, 98, 98, -46, -43, -113, -19 },
        { 121, 55, 90, 111, 33, 94, 82, -85, 56, 88, -59, -113, 65, 51, 32, 116 },
        { -14, -53, -87, 66, -120, -111, 65, -98, -8, -44, 50, 61, -75, 65, -39, 8 },
        { -77, -30, -112, -20, 41, -2, 119, -69, 18, -105, -15, 118, 20, 34, 99, 47 },
        { -104, 11, 44, -114, -93, -61, 70, -113, 68, 7, 65, 35, 86, 82, -80, -106 },
        { 113, -89, -36, -106, -122, -6, -10, -72, -61, -18, -2, -68, 56, -75, -118, 31 },
        { 121, 106, 10, -95, 3, -2, -90, -86, 97, -52, 61, 82, -54, 91, 45, 83 },
        { 71, -87, 107, 13, 58, 39, 61, -118, -54, 91, -36, 66, 54, 45, 118, -95 },
        { -4, -84, -24, -24, -55, -24, -46, -95, -80, 80, 102, 0, -15, 85, -35, -98 },
    },
    { /* test_id=1 */
        { -89, 8, -63, -96, -72, -120, 60, 46, -53, 75, 70, -8, -76, 62, 6, -45 },
        { -88, 58, -107, -71, 38, -113, 2, 15, -112, 109, -9, 42, -7, 101, 54, 111 },
        { -87, -81, 104, -18, -128, 91, -95, -88, 115, -28, -87, 84, 54, -70, -73, 32 },
        { 94, 17, -61, 50, -66, 87, 98, -105, 28, -63, 118, -50, -76, -22, 16, 67 },
        { -13, 121, -115, 84, -119, -37, -23, -18, -13, -120, -124, 77, -55, -99, -8, 86 },
        { -12, 71, -80, -30, -107, -111, 104, 100, 95, 93, 78, -56, 48, 39, -46, -68 },
        { -4, -123, 55, 45, 48, 81, -127, 34, 25, 80, 69, -94, -60, -69, -83, 84 },
        { -106, -82, -84, -78, -58, 93, -116, 77, -30, -3, 97, -128, -80, 95, 124, 74 },
        { -64, 95, -14, 72, 58, 115, 68, 70, -20, 41, -78, 41, 86, 30, 55, -9 },
        { 94, 54, 4, 51, -36, -16, 112, -59, 22, 90, 92, 70, -108, 96, -67, 13 },
        { -106, 0, -6, -12, -56, -24, -18, 0, 99, -124, 24, 16, 90, -124, 9, -120 },
        { -18, 59, 72, -94, 13, 89, 86, -67, 71, 86, -48, -100, 101, 2, 9, -17 },
        { 92, -13, -101, 42, -42, 37, 7, 38, 77, 65, 24, -9, 123, 4, 101, 89 },
        { -66, -49, 50, 15, 114, -58, -59, -109, -111, 118, 85, 66, 70, -123, -104, 18 },
        { -39, 101, -5, 33, -26, -51, 59, 15, -84, -32, 54, 12, -6, -37, -82, -106 },
        { -46, -78, -89, 14, 41, -29, -2, 74, -15, 43, 78, -52, -19, 26, -46, 25 },
    },
    { /* test_id=2 */
        { -26, -124, 110, -75, -107, 94, 74, -59, -53, -44, 20, -25, 0, -44, -98, 125 },
        { 48, 30, -9, 89, -36, 34, 96, -121, -56, -12, 98, -70, 57, -64, -40, 81 },
        { 47, 108, 107, -115, 58, -67, -116, 90, -44, 69, -121, -57, -124, -65, 106, 105 },
        { 98, 116, -89, -54, 91, -31, -82, -18, -42, -37, -14, 40, -85, 110, -46, -97 },
        { 60, 39, 24, 13, -116, 49, -57, 0, 18, 12, 44, 71, 59, 91, 126, 64 },
        { -14, -113, 41, -46, -16, 63, -25, -90, 119, -121, -25, -90, -41, 126, -23, 81 },
        { 34, -30, 79, 57, -80, -70, -47, 61, 59, 61, -87, 60, -98, 19, -44, -38 },
        { -12, 79, -124, -119, -88, -85, -102, -24, -33, -116, -106, -1, -12, 3, 68, 89 },
        { 9, 107, 55, -108, 17, -34, 49, -115, 21, -68, -11, 11, -92, 16, 54, -9 },
        { -102, -56, -88, -7, -93, 14, 101, -23, -9, -61, -1, 80, -95, -93, 111, -118 },
        { 108, 124, -91, -101, -123, -48, -2, -43, -116, -63, 49, -55, -43, 96, -3, -77 },
        { -53, -74, -15, 65, -128, 12, -87, -24, 26, 9, -32, -74, 72, -98, -68, -15 },
        { 100, -82, -52, 47, -128, -122, 46, -77, -78, -39, 32, 47, -72, -16, 26, -48 },
        { 63, 30, -37, 67, -24, 45, 116, 31, -72, -17, -107, -21, -122, 51, -42, 1 },
        { 33, -76, -99, -16, -124, 68, -43, 98, 107, -67, 117, -8, -15, 66, -36, -1 },
        { 61, 23, 103, -4, 30, 59, -3, 55, -128, -97, 50, 119, -50, -104, -12, 68 },
    },
    { /* test_id=3 */
        { -77, -111, 89, -63, 12, -100, 5, 54, 4, -44, 123, 72, 122, -39, -120, -14 },
        { -57, 66, 37, 59, -5, 30, 48, -60, -46, 116, -56, -109, 125, -110, 44, -105 },
        { -1, -92, -17, -15, -35, 114, -113, 102, -36, 95, 39, -97, -62, 64, 44, -13 },
        { 114, -16, -70, 51, 96, -108, 77, -78, -81, 89, 58, 55, -35, -85, -46, -51 },
        { -125, -29, -125, 78, 80, 58, -58, 19, -16, -100, -127, 11, -88, 122, -65, -84 },
        { 22, 40, 19, -11, 94, -111, -54, 90, -70, 5, 126, -125, 125, -44, -83, 65 },
        { -108, 44, -92, -3, -23, 56, -83, 55, -120, 101, 76, 40, -63, 37, 28, -19 },
        { -53, 79, -125, -50, 106, -50, 22, 31, 94, 59, 100, -94, 73, -16, 6, 20 },
        { -50, 104, -68, -105, 76, -41, -37, 37, -4, -14, 116, 31, 28, -93, 29, -108 },
        { -118, 57, 105, 64, 24, -39, -15, -23, -111, -29, -16, 72, 122, -72, 38, -119 },
        { -17, 91, 111, -84, 44, -83, -11, -3, -35, 5, -82, -81, 78, 71, -16, -45 },
        { 87, -125, -100, 40, 7, 8, 126, -93, 32, 111, -4, 44, 107, 28, -9, -103 },
        { 22, 110, 87, -85, 106, 94, -18, 21, 30, 54, -96, 74, -109, 122, 42, -86 },
        { 89, -46, 75, -53, -116, 43, 83, 107, -115, 104, -38, 124, -66, -21, 63, 19 },
        { 33, -106, -16, -15, 33, -12, 75, -41, -92, 37, 72, 27, 85, -69, -59, 22 },
        { -48, 110, -13, -54, -9, -8, 85, -124, 80, 22, 71, -91, 119, -95, -29, 116 },
    },
    { /* test_id=4 */
        { -41, 125, 31, -113, -109, 74, -84, -108, 83, 107, 28, -59, 110, 34, 20, -5 },
        { 122, 71, 77, 42, -69, 120, 29, -4, -97, -29, 111, -17, -128, -28, -108, 111 },
        { 26, 8, -73, -88, -122, 68, -37, 17, 111, 10, 79, 9, 115, 24, -75, -8 },
        { 57, 51, 61, 77, -36, 3, -41, -61, -44, -12, -87, 115, 46, 51, 96, -45 },
        { 102, -24, 4, 10, -37, 72, -55, 4, -51, -118, 10, 88, -34, -1, -37, -17 },
        { -98, 90, 87, -57, 7, -35, 7, -124, 29, -125, -103, -36, -106, 93, 6, 82 },
        { -86, 93, 8, -127, 86, 73, -23, 100, -36, 54, 117, 9, -63, -36, 102, -94 },
        { 95, 30, -38, -52, -116, -49, 84, 12, 52, -78, 80, -49, 40, 29, 74, -102 },
        { -38, -66, -3, 41, -67, 108, -106, 43, -128, 10, -19, -99, 111, 110, 125, -58 },
        { -75, -7, -19, -67, 121, 106, 78, 39, 77, 37, 115, 57, 43, -48, -101, 57 },
        { -92, 39, -47, 111, 126, -109, 69, 67, -59, -117, -105, -47, -98, 104, 19, -102 },
        { -3, -70, -40, 28, 20, 63, -2, 105, -20, 70, 34, 120, 88, -52, 110, -71 },
        { 123, -42, 7, -69, 8, 93, 18, -120, 16, 64, -88, -93, 57, 78, -119, 13 },
        { 80, -53, 122, 10, -59, 66, 115, -35, -38, -68, -40, -50, 64, -104, -20, 83 },
        { 36, 71, 67, -12, 6, 16, 104, 77, 20, -116, 20, 117, 51, -126, -81, -48 },
        { -7, 39, 101, -78, 121, -75, 112, 114, -54, -55, 3, 33, -25, 22, -8, -55 },
    },
};

static const int32_t GOLDEN[NUM_TEST_VECTORS][ARRAY_SIZE] = {
    { -23102, -25588, 4646, 6060, -8357, 23412, 50755, 4927, 20441, -28691, -5056, 9393, 1328, 8067, 7878, -5107 },  /* test_id=0 */
    { -2904, 14265, -49756, 17852, -2810, 7620, -13115, 44238, -6380, -4825, -9765, -10295, 9432, 10194, 40624, 29771 },  /* test_id=1 */
    { 5263, 10909, 40682, -13085, -5942, 2571, 20441, 6378, -9401, -12598, -13770, -3646, -47861, -22743, 2583, 13227 },  /* test_id=2 */
    { 551, 12545, -16407, -1856, 23815, -41373, -383, -3301, 25888, -10088, 45048, -56368, 39498, -32958, -23418, 33550 },  /* test_id=3 */
    { 19358, -21299, -4984, 6087, 34654, -20879, 6129, 2654, -14610, -3065, -25723, 3728, -15766, 8344, -6728, -17381 },  /* test_id=4 */
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
 * 协议：TCP 短连接 + 单行 JSON（JSON Lines），字段：
 *   seq/test_id/array_size/result[]/pass/ts
 * host_eth_receiver.py 按行接收、JSON 解析、落盘 eth_results.jsonl，
 * 并即时用 golden_model 重新计算做二次交叉验证。
 * 3 秒发送/接收超时，避免上位机不可达时板端永久阻塞；上传失败仅
 * 打印警告、不影响本地计算流程继续。
 * ============================================================= */
static int eth_upload_result(const char *host, int port, int seq, int test_id,
                              const int32_t *result, int n, int pass_flag)
{
    int sock;
    struct sockaddr_in addr;
    char json_buf[2048];
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

    for (t = 0; t < NUM_TEST_VECTORS; t++) {
        int32_t results[ARRAY_SIZE];
        uint32_t status;
        int timeout, pass;

        if (only_test_id >= 0 && t != only_test_id)
            continue;

        printf("---- test_id=%d ----\n", t);

        for (i = 0; i < ARRAY_SIZE; i++)
            for (j = 0; j < ARRAY_SIZE; j++)
                reg_write(base_addr, REG_WEIGHT_OFF(i, j), (uint32_t)(uint8_t)TEST_B[t][i][j]);

        for (i = 0; i < ARRAY_SIZE; i++)
            reg_write(base_addr, REG_DATA_OFF(i), (uint32_t)(uint8_t)TEST_A[t][i]);

        reg_write(base_addr, REG_CTRL_OFF, CTRL_START);

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

        pass = 1;
        for (i = 0; i < ARRAY_SIZE; i++) {
            results[i] = (int32_t)reg_read(base_addr, REG_RESULT_OFF(i));
            if (results[i] != GOLDEN[t][i]) pass = 0;
            printf("RESULT_%d: %d\n", i, results[i]);
        }

        if (pass) {
            printf("  [PASS] test_id=%d 与内置 GOLDEN 表完全一致\n", t);
            total_pass++;
        } else {
            printf("  [FAIL] test_id=%d 结果不匹配\n", t);
            total_fail++;
        }

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
