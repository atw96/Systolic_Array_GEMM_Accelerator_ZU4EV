`timescale 1ns/1ps
// =============================================================
// 文件名  : systolic_array.v
// 描述    : N×N Weight Stationary 脉动阵列顶层（参数化规模，ACU4EV 优化版）
// 功能    : 计算 C[row] = A[row][0:N-1] × B[0:N-1][0:N-1]（一行输出）
// 器件    : XCZU4EV，N×N 个 PE 各消耗 1 个 DSP48E2
//
// 【优化说明】对照 porting_env_hardware_config.md 记录的板卡资源余量
// （LUT 88,000 / DSP48E2 728，原 4×4 设计仅用 16 DSP≈2.2%），本文件
// 已从"硬编码 4 行错位寄存器"重构为 generate 循环生成的通用 N 级错位链，
// 可直接通过 ARRAY_SIZE 参数扩展到 8×8 / 16×16 等任意规模，无需改代码。
//
// ── 数据流示意图（Weight Stationary，以 N=4 为例）──────────
//
//   data_in[row][0..N-1] → 各行输入（经移位链错位）
//
//        col0      col1      col2      col3
//  row0  PE[0][0]→PE[0][1]→PE[0][2]→PE[0][3]
//          ↓         ↓         ↓         ↓        psum 向下流
//  row1  PE[1][0]→PE[1][1]→PE[1][2]→PE[1][3]
//          ↓         ↓         ↓         ↓
//  row2  PE[2][0]→PE[2][1]→PE[2][2]→PE[2][3]
//          ↓         ↓         ↓         ↓
//  row3  PE[3][0]→PE[3][1]→PE[3][2]→PE[3][3]
//          ↓         ↓         ↓         ↓
//       result[0] result[1] result[2] result[3]
//
//  权重预加载（Weight Stationary）：
//    PE[i][j].weight_reg = B[i][j]
//
//  行输入错位（Skewing）原理：
//    对于 C[m][j] = Σ_i(A[m][i] × B[i][j])
//    A[m][i] 进入 row-i 需比 A[m][0] 延迟 i 拍（第 i 行用 i 级移位寄存器）
//    这样 PE[i][j] 在同一时刻收到正确的 A 元素和来自上方的 psum
//    result_valid 在 2×ARRAY_SIZE-1 拍后置高
//
// =============================================================

module systolic_array #(
    parameter ARRAY_SIZE = 8    // 【优化】默认由 4 提升为 8（板卡资源余量充足）
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        compute_en,   // 来自 ctrl_fsm，COMPUTE 状态时为高
    input  wire        weight_load,  // 来自 ctrl_fsm，LOAD_WEIGHT 状态时脉冲
    // 行数据输入：data_in[i*8 +: 8] = A[m][i]（第 i 行输入）
    input  wire [ARRAY_SIZE*8-1:0]            data_in,
    // 权重总线：weight_flat[(i*ARRAY_SIZE+j)*8 +: 8] = B[i][j]
    input  wire [ARRAY_SIZE*ARRAY_SIZE*8-1:0] weight_flat,
    // 结果输出：result_flat[j*32 +: 32] = C[m][j]
    output wire [ARRAY_SIZE*32-1:0]           result_flat,
    output reg                                 result_valid  // 结果有效标志
);

    // ================================================================
    // 【重构】行输入错位寄存器链（generate 生成，支持任意 ARRAY_SIZE）
    // 第 row 行需要 row 级移位寄存器延迟（第 0 行无延迟，直接连接）
    // 原实现对 4 行分别手写 4 个 always 块，仅适用于 ARRAY_SIZE=4；
    // 现改为二维 generate 循环，第 row 行例化 row 级移位寄存器。
    // ================================================================
    wire signed [7:0] row_data_skewed [0:ARRAY_SIZE-1];

    genvar srow, sstage;
    generate
        for (srow = 0; srow < ARRAY_SIZE; srow = srow + 1) begin : GEN_SKEW_ROW
            if (srow == 0) begin : SKEW_ROW0
                // 第 0 行无延迟，直接连接原始输入
                assign row_data_skewed[0] = $signed(data_in[7:0]);
            end else begin : SKEW_ROWN
                // 第 srow 行：srow 级移位寄存器链
                reg signed [7:0] skew_chain [0:srow-1];
                integer sk;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (sk = 0; sk < srow; sk = sk + 1)
                            skew_chain[sk] <= 8'sd0;
                    end else begin
                        skew_chain[0] <= $signed(data_in[srow*8 +: 8]);
                        for (sk = 1; sk < srow; sk = sk + 1)
                            skew_chain[sk] <= skew_chain[sk-1];
                    end
                end
                assign row_data_skewed[srow] = skew_chain[srow-1];
            end
        end
    endgenerate

    // ================================================================
    // PE 间连接信号
    // pe_d[row][col]：PE[row][col] 的 data_in（水平方向）
    //   col=0 来自 row_data_skewed，col>0 来自左侧 PE 的 data_out
    // pe_p[row][col]：PE[row][col] 的 psum_in（垂直方向）
    //   row=0 接 0，row>0 接上方 PE 的 psum_out
    // ================================================================
    wire signed [7:0]  pe_d [0:ARRAY_SIZE-1][0:ARRAY_SIZE];   // data wires
    wire signed [31:0] pe_p [0:ARRAY_SIZE]  [0:ARRAY_SIZE-1]; // psum wires

    // 第 0 列数据来自错位寄存器
    genvar gi;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : GEN_DATA_COL0
            assign pe_d[gi][0] = row_data_skewed[gi];
        end
    endgenerate

    // 第 0 行 psum_in = 0（无上方 PE）
    genvar gj;
    generate
        for (gj = 0; gj < ARRAY_SIZE; gj = gj + 1) begin : GEN_PSUM_ROW0
            assign pe_p[0][gj] = 32'sd0;
        end
    endgenerate

    // ================================================================
    // N×N 个 PE 例化（generate 双重循环）
    // PE[row][col] 存储权重 B[row][col]
    // ================================================================
    genvar row, col;
    generate
        for (row = 0; row < ARRAY_SIZE; row = row + 1) begin : ROW_GEN
            for (col = 0; col < ARRAY_SIZE; col = col + 1) begin : COL_GEN
                pe_unit pe_inst (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .pe_en      (compute_en),
                    .weight_load(weight_load),
                    // 数据：水平流动（左→右）
                    .data_in    (pe_d[row][col]),
                    .data_out   (pe_d[row][col+1]),  // 传给右侧 PE
                    // 权重：weight_flat 中对应切片
                    .weight_in  ($signed(weight_flat[(row*ARRAY_SIZE+col)*8 +: 8])),
                    // 部分和：垂直流动（上→下）
                    .psum_in    (pe_p[row][col]),
                    .psum_out   (pe_p[row+1][col])   // 传给下方 PE
                );
            end
        end
    endgenerate

    // ================================================================
    // 结果输出：pe_p[ARRAY_SIZE][j] 为列 j 的最终部分和
    // 即 C[m][0..N-1] = pe_p[N][0..N-1]
    // ================================================================
    genvar rj;
    generate
        for (rj = 0; rj < ARRAY_SIZE; rj = rj + 1) begin : GEN_RESULT
            assign result_flat[rj*32 +: 32] = pe_p[ARRAY_SIZE][rj];
        end
    endgenerate

    // ================================================================
    // result_valid：计算开始后 2×ARRAY_SIZE-1 拍置高
    // 【优化】valid_cnt 位宽原硬编码 4 位（仅支持 N≤8），现改为按
    // ARRAY_SIZE 自动计算所需位宽，支持任意规模（含未来扩展到 16/32）。
    // ================================================================
    localparam VALID_LATENCY = 2*ARRAY_SIZE - 1;
    // clog2 手动展开（避免依赖 SystemVerilog $clog2 在部分老工具链的兼容性问题）
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            for (clog2 = 0; v > 0; clog2 = clog2 + 1)
                v = v >> 1;
        end
    endfunction
    localparam VALID_CNT_WIDTH = clog2(VALID_LATENCY + 1) + 1; // 留 1 位余量

    reg [VALID_CNT_WIDTH-1:0] valid_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_cnt    <= {VALID_CNT_WIDTH{1'b0}};
            result_valid <= 1'b0;
        end else if (compute_en) begin
            if (valid_cnt < VALID_LATENCY)
                valid_cnt <= valid_cnt + 1'b1;
            result_valid <= (valid_cnt == VALID_LATENCY - 1);
        end else begin
            valid_cnt    <= {VALID_CNT_WIDTH{1'b0}};
            result_valid <= 1'b0;
        end
    end

endmodule
