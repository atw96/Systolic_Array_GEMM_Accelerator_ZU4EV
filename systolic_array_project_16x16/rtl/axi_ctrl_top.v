`timescale 1ns/1ps
// =============================================================
// 文件名  : axi_ctrl_top.v
// 描述    : AXI4-Lite 控制接口顶层（ACU4EV 优化版：参数化寄存器堆）
//           例化 systolic_array + ctrl_fsm，对外暴露 AXI4-Lite Slave
//
// ── 为何用 AXI4-Lite 而非 AXI4-Stream ─────────────────────
//   AXI4-Lite：低带宽控制/状态寄存器访问，PS 随机读写，无流控开销
//               适合：启动/停止控制、状态查询、少量结果读取
//   AXI4-Stream：高吞吐量流式数据，需要握手和 FIFO，延迟高
//               适合：图像/音频数据搬运，不适合寄存器控制面
//   → 控制面选 AXI4-Lite，数据面（若扩展）再考虑 AXI4-Stream
//
// 【优化说明】对照 porting_env_hardware_config.md 记录的板卡资源余量
// （LUT 88,000 / DSP48E2 728，原 4×4 设计仅用 16 DSP≈2.2%），本文件
// 已从"硬编码 4×4 寄存器 case 列表"重构为参数化寄存器堆（generic
// register file），寄存器数量、地址随 ARRAY_SIZE 自动计算，无需为
// 每个新增寄存器手写 case 分支。
//
// ── 寄存器映射（公式化，AXI Base Addr 由 Block Design 分配，
//    ACU4EV 移植版为 0x8005_0000，详见 create_bd.tcl）──────────
//
//   字索引(word index)          字节偏移            内容
//   0                            0x00                CTRL_REG (R/W)
//                                                     bit0=start（写1自动清零）
//   1                            0x04                STATUS_REG (R)
//                                                     bit0=done，bit1=busy
//   [2 .. 2+N-1]                 0x08 起              RESULT_0 .. RESULT_{N-1} (R)
//                                                     结果向量 C[0..N-1]（INT32）
//   [2+N .. 2+2N-1]               ...                 DATA_IN_0 .. DATA_IN_{N-1} (R/W)
//                                                     数据向量 A[0..N-1]（INT8）
//   [2+2N .. 2+2N+N²-1]           ...                 WEIGHT_00 .. WEIGHT_{N-1,N-1} (R/W)
//                                                     权重矩阵 B[i][j]，行主序
//                                                     字索引 = 2+2N + i*N+j
//
//   总寄存器数 = 2 + 2N + N²，总字节数 = 4×(2+2N+N²)
//
// ── 默认 ARRAY_SIZE=16 的具体寄存器地址表（供软件/文档参考）─────
//   0x00        CTRL_REG
//   0x04        STATUS_REG
//   0x08~0x44   RESULT_0~15      (16 个)
//   0x48~0x84   DATA_IN_0~15     (16 个)
//   0x88~0x484  WEIGHT_00~1515    (256 个，行主序 B[i][j] @ 0x88+(i*16+j)*4)
//   总计 290 个寄存器，1160 字节（仍小于分配的 64KB 地址空间）
//
// ── Vivado IP Packager 注释头（封装为 AXI IP 时使用）────────
//   IP Name        : axi_ctrl_top
//   IP Version     : 1.0
//   IP Library     : user
//   IP Taxonomy    : /UserIP
//   AXI Interface  : S_AXI（Slave，AXI4-Lite，32bit data，参数化 addr 位宽）
//   Clock Domain   : s_axi_aclk（ACU4EV 移植版：连接 PS pl_clk1 = 100 MHz，
//                    经 M_AXI_HPM0_LPD 主口下挂，与板上其他调试外设
//                    axi_gpio_debug/axi_gpio_led/axi_uart_dbg 同一时钟域）
// =============================================================

module axi_ctrl_top #(
    parameter integer ARRAY_SIZE        = 16,  // 【优化】脉动阵列规模，原固定 4，本版本默认 16
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    // 【优化】地址位宽原固定 8（256B，仅够 4x4=22 个寄存器）。
    // 现默认 12 位（4096B），可覆盖 ARRAY_SIZE 至 27（DSP 预算早已封顶，
    // 728 个 DSP 最大约支持 26x26，故 4096B 地址空间留有充分余量）。
    parameter integer C_S_AXI_ADDR_WIDTH = 12
)(
    // AXI4-Lite Slave 接口
    input  wire                          s_axi_aclk,
    input  wire                          s_axi_aresetn,
    // Write Address Channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire [2:0]                    s_axi_awprot,
    input  wire                          s_axi_awvalid,
    output reg                           s_axi_awready,
    // Write Data Channel
    input  wire [C_S_AXI_DATA_WIDTH-1:0] s_axi_wdata,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] s_axi_wstrb,
    input  wire                          s_axi_wvalid,
    output reg                           s_axi_wready,
    // Write Response Channel
    output reg  [1:0]                    s_axi_bresp,
    output reg                           s_axi_bvalid,
    input  wire                          s_axi_bready,
    // Read Address Channel
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire [2:0]                    s_axi_arprot,
    input  wire                          s_axi_arvalid,
    output reg                           s_axi_arready,
    // Read Data Channel
    output reg  [C_S_AXI_DATA_WIDTH-1:0] s_axi_rdata,
    output reg  [1:0]                    s_axi_rresp,
    output reg                           s_axi_rvalid,
    input  wire                          s_axi_rready
);

    // ── 【优化】寄存器堆布局常量（公式化，替代硬编码地址表）───────
    localparam integer NUM_WEIGHTS   = ARRAY_SIZE * ARRAY_SIZE;
    localparam integer RESULT_BASE   = 2;                       // 字索引
    localparam integer DATA_BASE     = RESULT_BASE + ARRAY_SIZE;
    localparam integer WEIGHT_BASE   = DATA_BASE   + ARRAY_SIZE;
    localparam integer TOTAL_REGS    = WEIGHT_BASE + NUM_WEIGHTS;

    // ── 寄存器定义（数组深度随 ARRAY_SIZE 自动伸缩）───────────────
    reg [31:0] ctrl_reg;                            // 字索引 0
    reg [31:0] result_regs [0:ARRAY_SIZE-1];         // 只读，由 FSM 锁存
    reg [7:0]  data_in_regs [0:ARRAY_SIZE-1];
    reg [7:0]  weight_regs  [0:NUM_WEIGHTS-1];

    // ── 内部信号 ───────────────────────────────────────────────
    wire        start_pulse;            // ctrl_reg bit0 单拍触发
    wire        weight_load_w;
    wire        compute_en_w;
    wire        result_latch_w;
    wire        done_w, busy_w;
    wire [2:0]  fsm_state;

    // start 单脉冲：AXI 写 0x00 bit0=1 后下一拍自动清零
    // 【修复】ctrl_reg 只在下方写通道 always 块中驱动，避免多驱动综合报错
    assign start_pulse = ctrl_reg[0];

    // ── ctrl_fsm 例化（ARRAY_SIZE 透传）──────────────────────────
    ctrl_fsm #(.ARRAY_SIZE(ARRAY_SIZE)) u_fsm (
        .clk         (s_axi_aclk),
        .rst_n       (s_axi_aresetn),
        .start       (start_pulse),
        .weight_load (weight_load_w),
        .compute_en  (compute_en_w),
        .result_latch(result_latch_w),
        .done        (done_w),
        .busy        (busy_w),
        .state_out   (fsm_state)
    );

    // ── 权重总线拼接（NUM_WEIGHTS×8bit → NUM_WEIGHTS*8 bit）────────
    wire [NUM_WEIGHTS*8-1:0] weight_flat_bus;
    genvar wi;
    generate
        for (wi = 0; wi < NUM_WEIGHTS; wi = wi + 1) begin : GEN_WBUS
            assign weight_flat_bus[wi*8 +: 8] = weight_regs[wi];
        end
    endgenerate

    // ── 数据总线拼接（ARRAY_SIZE×8bit → ARRAY_SIZE*8 bit）─────────
    wire [ARRAY_SIZE*8-1:0] data_in_bus;
    genvar di;
    generate
        for (di = 0; di < ARRAY_SIZE; di = di + 1) begin : GEN_DBUS
            assign data_in_bus[di*8 +: 8] = data_in_regs[di];
        end
    endgenerate

    // ── systolic_array 例化（ARRAY_SIZE 透传）──────────────────────
    wire [ARRAY_SIZE*32-1:0] sa_result_flat;
    wire                     sa_result_valid;

    systolic_array #(.ARRAY_SIZE(ARRAY_SIZE)) u_sa (
        .clk         (s_axi_aclk),
        .rst_n       (s_axi_aresetn),
        .compute_en  (compute_en_w),
        .weight_load (weight_load_w),
        .data_in     (data_in_bus),
        .weight_flat (weight_flat_bus),
        .result_flat (sa_result_flat),
        .result_valid(sa_result_valid)
    );

    // ── 结果锁存：OUTPUT 状态时锁存 result_flat 到 AXI 结果寄存器 ──
    integer ri;
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                result_regs[ri] <= 32'd0;
        end else if (result_latch_w) begin
            for (ri = 0; ri < ARRAY_SIZE; ri = ri + 1)
                result_regs[ri] <= sa_result_flat[ri*32 +: 32];
        end
    end

    // ================================================================
    // AXI4-Lite 写通道状态机
    // 策略：同时接受 AW 和 W，两者都就绪时完成写操作
    // ================================================================
    reg        aw_done;  // AW 地址已锁存
    reg        w_done;   // W 数据已锁存
    reg [C_S_AXI_ADDR_WIDTH-1:0] aw_addr_r;
    reg [31:0] w_data_r;

    // AW Channel
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0;
            aw_done       <= 1'b0;
            aw_addr_r     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (s_axi_awvalid && !aw_done) begin
                s_axi_awready <= 1'b1;
                aw_addr_r     <= s_axi_awaddr;
                aw_done       <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
                if (s_axi_bvalid && s_axi_bready)
                    aw_done <= 1'b0;
            end
        end
    end

    // W Channel
    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_wready <= 1'b0;
            w_done       <= 1'b0;
            w_data_r     <= 32'd0;
        end else begin
            if (s_axi_wvalid && !w_done) begin
                s_axi_wready <= 1'b1;
                w_data_r     <= s_axi_wdata;
                w_done       <= 1'b1;
            end else begin
                s_axi_wready <= 1'b0;
                if (s_axi_bvalid && s_axi_bready)
                    w_done <= 1'b0;
            end
        end
    end

    // ── 写操作执行（AW 和 W 均完成）─────────────────────────────
    // 【优化】原实现为每个寄存器手写一条 case 分支（16个weight+4个data，
    // 共 20+ 条，且无法随 ARRAY_SIZE 扩展）。现改为基于字索引区间判断的
    // 通用译码（RESULT 只读不接受写；DATA_IN / WEIGHT 区间用可变下标
    // 数组写入），任意 ARRAY_SIZE 均可直接综合，无需手改。
    integer wi2;
    wire [C_S_AXI_ADDR_WIDTH-3:0] wr_word_idx = aw_addr_r[C_S_AXI_ADDR_WIDTH-1:2];

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
            ctrl_reg     <= 32'd0;
            for (wi2 = 0; wi2 < NUM_WEIGHTS; wi2 = wi2 + 1)
                weight_regs[wi2] <= 8'd0;
            for (wi2 = 0; wi2 < ARRAY_SIZE; wi2 = wi2 + 1)
                data_in_regs[wi2] <= 8'd0;
        end else begin
            // start 单脉冲：bit0 写 1 后下一拍自动清零（单一驱动进程）
            if (ctrl_reg[0])
                ctrl_reg[0] <= 1'b0;

            if (aw_done && w_done && !s_axi_bvalid) begin
                s_axi_bvalid <= 1'b1;
                s_axi_bresp  <= 2'b00; // OKAY

                if (wr_word_idx == 0) begin
                    // 0x00 CTRL_REG
                    ctrl_reg <= w_data_r;
                end
                // 字索引 1 (STATUS) 及 RESULT 区间只读，忽略写
                else if (wr_word_idx >= DATA_BASE && wr_word_idx < DATA_BASE + ARRAY_SIZE) begin
                    data_in_regs[wr_word_idx - DATA_BASE] <= w_data_r[7:0];
                end
                else if (wr_word_idx >= WEIGHT_BASE && wr_word_idx < WEIGHT_BASE + NUM_WEIGHTS) begin
                    weight_regs[wr_word_idx - WEIGHT_BASE] <= w_data_r[7:0];
                end
                // 其余未定义地址：忽略写（仍返回 OKAY，与原实现行为一致）

            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    // ================================================================
    // AXI4-Lite 读通道
    // 【优化】同上，改为区间判断的通用译码，替代硬编码 case 列表
    // ================================================================
    reg [C_S_AXI_ADDR_WIDTH-1:0] ar_addr_r;
    wire [C_S_AXI_ADDR_WIDTH-3:0] rd_word_idx = s_axi_araddr[C_S_AXI_ADDR_WIDTH-1:2];

    always @(posedge s_axi_aclk or negedge s_axi_aresetn) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rdata   <= 32'd0;
            s_axi_rresp   <= 2'b00;
            ar_addr_r     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1'b1;
                ar_addr_r     <= s_axi_araddr;
                s_axi_rvalid  <= 1'b1;
                s_axi_rresp   <= 2'b00;

                if (rd_word_idx == 0) begin
                    s_axi_rdata <= {31'd0, ctrl_reg[0]};                        // 0x00 CTRL
                end else if (rd_word_idx == 1) begin
                    s_axi_rdata <= {30'd0, busy_w, done_w};                     // 0x04 STATUS
                end else if (rd_word_idx >= RESULT_BASE && rd_word_idx < RESULT_BASE + ARRAY_SIZE) begin
                    s_axi_rdata <= result_regs[rd_word_idx - RESULT_BASE];      // RESULT_0..N-1
                end else if (rd_word_idx >= DATA_BASE && rd_word_idx < DATA_BASE + ARRAY_SIZE) begin
                    s_axi_rdata <= {24'd0, data_in_regs[rd_word_idx - DATA_BASE]}; // DATA_IN_0..N-1
                end else if (rd_word_idx >= WEIGHT_BASE && rd_word_idx < WEIGHT_BASE + NUM_WEIGHTS) begin
                    s_axi_rdata <= {24'd0, weight_regs[rd_word_idx - WEIGHT_BASE]}; // WEIGHT_00..N-1,N-1
                end else begin
                    s_axi_rdata <= 32'hDEAD_BEEF;                              // 未定义地址
                end
            end else begin
                s_axi_arready <= 1'b0;
                if (s_axi_rvalid && s_axi_rready)
                    s_axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
