`timescale 1ns/1ps
// =============================================================
// 文件名  : ctrl_fsm.v
// 描述    : 脉动阵列控制状态机（5 状态 Moore FSM，两段式写法，ACU4EV 优化版）
// 状态转移：IDLE → LOAD_WEIGHT → COMPUTE → OUTPUT → DONE → IDLE
//
// ── ASCII 波形时序图 ────────────────────────────────────────
//
// CLK     ─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─┐ ┌─
// start   ──┘1└────────────────────────────────────────────
//
// state   IDLE│LW │  COMPUTE(2N-1 cycles)   │OUT│DONE│IDLE
//         ────┼───┼────────────────────────┼───┼────┼────
//
// weight_load  ┌─┐
//         ─────┘ └───────────────────────────────────────
//
// compute_en     ┌───────────────────────┐
//         ───────┘                       └───────────────
//
// done                                             ┌───────...──┐
//         ────────────────────────────────────────┘             └── (下次 start 时清零)
//
// result                                    (OUTPUT 状态读取)
//         ────────────────────────────────────────────────
//
// ── 状态说明 ────────────────────────────────────────────────
//   IDLE        : 等待 start 脉冲
//   LOAD_WEIGHT : weight_load=1，持续 1 拍，加载所有 PE 权重
//   COMPUTE     : compute_en=1，持续 2×ARRAY_SIZE-1 拍（本变体 N=24 时为 47 拍）
//                 数据波前在阵列中传播
//   OUTPUT      : 结果已稳定，等待 AXI 读取
//   DONE_ST     : 进入本状态时置位 done_sticky，下一拍返回 IDLE
//
// ── 【重要修复】done 由单拍脉冲改为电平保持（sticky）───────────
//   原实现中 done 仅在 DONE_ST 状态期间为高，只维持 1 个时钟周期
//   （@100MHz 即 10ns）。通过完整 AXI 事务级仿真验证发现：
//   软件轮询 STATUS_REG（无论是 xsim 里的 AXI 读事务，还是真实
//   ARM 通过 /dev/mem 的软件轮询，单次轮询开销都是微秒级，远大于
//   10ns）几乎必然会错过这个瞬间脉冲，导致轮询永久超时——这在真实
//   板卡上会表现为 test_app 卡死在等待 done 的循环里。
//   修复方案：新增 done_sticky 寄存器，在进入 DONE_ST 时置位并
//   保持，直到下一次 start 脉冲到来时才清零（软件语义："本次结果
//   已就绪，直到你发起下一次计算前一直有效"），done 输出直接来自
//   该寄存器。busy 仍为组合逻辑（瞬时状态指示，非轮询关键路径）。
// =============================================================

module ctrl_fsm #(
    parameter ARRAY_SIZE = 8    // 【优化】默认由 4 提升为 8（板卡资源余量充足）
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,        // 来自 AXI CTRL_REG bit0（单脉冲）
    output reg        weight_load,  // 连接 systolic_array.weight_load
    output reg        compute_en,   // 连接 systolic_array.compute_en
    output reg        result_latch, // 通知顶层锁存结果
    output wire        done,         // 计算完成标志 → AXI STATUS_REG bit0（电平保持型）
    output reg        busy,         // 计算进行中   → AXI STATUS_REG bit1
    output reg [2:0]  state_out     // 调试用：当前状态
);

    // ── 状态编码 ───────────────────────────────────────────────
    localparam [2:0]
        IDLE        = 3'd0,
        LOAD_WEIGHT = 3'd1,
        COMPUTE     = 3'd2,
        OUTPUT      = 3'd3,
        DONE_ST     = 3'd4;

    // COMPUTE 持续 2×ARRAY_SIZE-1 拍（计数器从 0 到 COMPUTE_CYCLES-1）
    // 本变体 N=24 时为 47 拍（通用公式 2N-1，适用任意 ARRAY_SIZE）
    localparam COMPUTE_CYCLES = 2*ARRAY_SIZE - 1;

    // ── 【优化】compute_cnt 位宽原硬编码 4 位（最大计数 15，仅够 N≤8），
    // 现按 ARRAY_SIZE 自动计算所需位宽，支持任意规模（含未来扩展到 32）。
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction
    localparam CNT_WIDTH = clog2(COMPUTE_CYCLES + 1) + 1; // 留 1 位余量

    // ── 寄存器 ────────────────────────────────────────────────
    reg [2:0] state_r, next_state;
    reg [CNT_WIDTH-1:0] compute_cnt; // 最大需计数到 COMPUTE_CYCLES-1
    reg done_sticky;                 // 【修复】电平保持型 done

    // ── 第一段：状态寄存器（时序逻辑）────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state_r <= IDLE;
        else
            state_r <= next_state;
    end

    // ── 计数器（COMPUTE 状态计拍数）──────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            compute_cnt <= {CNT_WIDTH{1'b0}};
        else if (state_r == COMPUTE)
            compute_cnt <= compute_cnt + 1'b1;
        else
            compute_cnt <= {CNT_WIDTH{1'b0}};
    end

    // ── 【修复】done_sticky：进入 DONE_ST 时置位，下次 start 时清零 ──
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done_sticky <= 1'b0;
        else if (state_r == DONE_ST)
            done_sticky <= 1'b1;   // 计算完成，置位并保持（电平）
        else if (start)
            done_sticky <= 1'b0;   // 新一轮计算开始时清零，供下一次轮询使用
    end
    assign done = done_sticky;

    // ── 第二段：次态逻辑（组合逻辑）──────────────────────────────
    always @(*) begin
        case (state_r)
            IDLE        : next_state = start ? LOAD_WEIGHT : IDLE;
            LOAD_WEIGHT : next_state = COMPUTE;  // 权重加载 1 拍，立即进入计算
            COMPUTE     : next_state = (compute_cnt == COMPUTE_CYCLES - 1) ? OUTPUT : COMPUTE;
            OUTPUT      : next_state = DONE_ST;  // 1 拍输出窗口
            DONE_ST     : next_state = IDLE;     // 状态机立即返回 IDLE（done 电平由 done_sticky 单独保持）
            default     : next_state = IDLE;
        endcase
    end

    // ── 输出逻辑（Moore FSM：只由当前状态决定，done 除外见上）──────
    always @(*) begin
        // 默认值，避免 latch
        weight_load  = 1'b0;
        compute_en   = 1'b0;
        result_latch = 1'b0;
        busy         = 1'b0;
        state_out    = state_r;

        case (state_r)
            IDLE        : begin
                busy = 1'b0;
            end
            LOAD_WEIGHT : begin
                weight_load = 1'b1;  // 所有 PE 并行加载权重
                busy        = 1'b1;
            end
            COMPUTE     : begin
                compute_en  = 1'b1;  // 驱动 pe_en，数据波前传播
                busy        = 1'b1;
            end
            OUTPUT      : begin
                result_latch = 1'b1; // 顶层在此拍锁存 result_flat
                busy         = 1'b1;
            end
            DONE_ST     : begin
                busy = 1'b0;         // done 电平由 done_sticky 时序逻辑单独驱动
            end
            default     : begin end
        endcase
    end

endmodule
