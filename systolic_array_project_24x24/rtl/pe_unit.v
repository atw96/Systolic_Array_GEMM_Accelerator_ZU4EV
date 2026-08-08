`timescale 1ns/1ps
// =============================================================
// 文件名  : pe_unit.v
// 描述    : Weight Stationary 脉动阵列 — 单个处理单元（PE）
// 目标器件: Xilinx XCZU4EV（DSP48E2）
// 工具    : Vivado 2020.1 / xsim
// =============================================================
// 溢出分析：
//   INT8 × INT8 最大乘积：127 × 127 = 16129（需 15 bit）
//   4 次 INT32 累加最大：4 × 127 × 127 = 64516（需 17 bit）
//   INT32（32bit 有符号）范围 ±2^31，完全安全，无需饱和处理
// =============================================================

(* use_dsp = "yes" *)   // 强制 Vivado 将 MAC 映射到 DSP48E2，每个 PE 消耗 1 个 DSP
                        // 16 个 PE → DSP 占用 16/728 = 2.2%（XCZU4EV 共 728 个）
module pe_unit (
    input  wire        clk,          // 系统时钟（来自 PS pl_clk0 = 100 MHz）
    input  wire        rst_n,        // 低有效同步复位
    input  wire        pe_en,        // PE 使能（由 ctrl_fsm compute_en 驱动）
    input  wire        weight_load,  // 权重加载脉冲（由 ctrl_fsm LOAD_WEIGHT 状态驱动）
    input  wire signed [7:0]  data_in,    // 数据输入：来自左侧 PE 的 data_out
    input  wire signed [7:0]  weight_in,  // 权重输入：来自 AXI 权重寄存器总线
    input  wire signed [31:0] psum_in,    // 部分和输入：来自上方 PE 的 psum_out
    output reg  signed [7:0]  data_out,   // 数据输出：向右侧 PE 传递（打一拍）
    output reg  signed [31:0] psum_out    // 部分和输出：向下方 PE 传递
);

    // ------------------------------------------------------------------
    // 权重寄存器（Weight Stationary 核心）
    // 在 LOAD_WEIGHT 阶段由 weight_load 脉冲锁存一次
    // COMPUTE 阶段全程保持不变，不消耗额外带宽
    // ------------------------------------------------------------------
    reg signed [7:0] weight_reg;

    // 权重加载：weight_load=1 时锁存，其余时刻保持
    always @(posedge clk or negedge rst_n) begin : WEIGHT_LOAD
        if (!rst_n)
            weight_reg <= 8'sd0;
        else if (weight_load)
            weight_reg <= weight_in;
        // weight_load=0 时自动保持（Stationary 特性）
    end

    // ------------------------------------------------------------------
    // MAC 运算 + 数据流水
    // psum_out = psum_in + (data_in × weight_reg)
    //
    // DSP48E2 端口映射（Vivado 自动推断）：
    //   A[29:0]  ← {22'b0, data_in[7:0]}  (符号扩展)
    //   B[17:0]  ← {10'b0, weight_reg[7:0]}
    //   C[47:0]  ← {16'b0, psum_in[31:0]}
    //   P[47:0]  → psum_out（取低 32 位）
    //
    // data_out 打一拍：数据沿行方向向右流动
    // 每个 PE 增加 1 拍延迟，实现数据在阵列中以"波前"方式传播
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin : MAC_COMPUTE
        if (!rst_n) begin
            data_out <= 8'sd0;
            psum_out <= 32'sd0;
        end else if (pe_en) begin
            data_out <= data_in;                           // 数据透传给右侧 PE
            psum_out <= psum_in + (data_in * weight_reg); // MAC：Verilog signed 自动符号扩展
        end
        // pe_en=0 时保持寄存器值（等待有效数据窗口）
    end

endmodule
