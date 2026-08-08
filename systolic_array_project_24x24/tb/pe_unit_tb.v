`timescale 1ns/1ps
// =============================================================
// 文件名  : pe_unit_tb.v
// 描述    : pe_unit 功能仿真测试台
// 工具    : Vivado xsim 2020.1（无需 ModelSim）
// 运行    : ./run_xsim.sh
// 测试向量: 7 组，覆盖全正/全负/全零/单位/混合/累加溢出/流水
// =============================================================

module pe_unit_tb;

    // ── 信号声明 ──────────────────────────────────────────────
    reg        clk, rst_n, pe_en, weight_load;
    reg  signed [7:0]  data_in, weight_in;
    reg  signed [31:0] psum_in;
    wire signed [7:0]  data_out;
    wire signed [31:0] psum_out;

    integer pass_cnt, fail_cnt;

    // ── DUT 例化 ──────────────────────────────────────────────
    pe_unit uut (
        .clk        (clk),
        .rst_n      (rst_n),
        .pe_en      (pe_en),
        .weight_load(weight_load),
        .data_in    (data_in),
        .weight_in  (weight_in),
        .psum_in    (psum_in),
        .data_out   (data_out),
        .psum_out   (psum_out)
    );

    // ── 时钟：周期 10 ns（100 MHz）─────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── 辅助任务：设置权重 + 执行一次 MAC + 验证结果 ──────────────
    task run_test;
        input signed [7:0]  t_data;
        input signed [7:0]  t_weight;
        input signed [31:0] t_psum;
        input integer       t_id;
        input signed [31:0] t_expect;
        reg  signed [31:0]  got_psum;
        reg  signed [7:0]   got_data;
        begin
            // 1. 加载权重（weight_load 脉冲，negedge 操作避免建立时间问题）
            @(negedge clk);
            weight_in   = t_weight;
            weight_load = 1'b1;
            @(negedge clk);
            weight_load = 1'b0;

            // 2. 送入数据，使能 PE
            @(negedge clk);
            data_in = t_data;
            psum_in = t_psum;
            pe_en   = 1'b1;
            @(negedge clk);
            pe_en   = 1'b0;

            // 3. 等一拍让寄存器输出稳定
            @(negedge clk);
            got_psum = psum_out;
            got_data = data_out;

            // 4. 比较结果
            if (got_psum === t_expect) begin
                $display("[PASS] Test %0d | data=%4d weight=%4d psum_in=%10d => psum_out=%10d",
                         t_id, t_data, t_weight, t_psum, got_psum);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] Test %0d | data=%4d weight=%4d psum_in=%10d => psum_out=%10d (expected=%10d)",
                         t_id, t_data, t_weight, t_psum, got_psum, t_expect);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    // ── 主测试流程 ────────────────────────────────────────────
    initial begin
        // 初始化
        pass_cnt    = 0;
        fail_cnt    = 0;
        rst_n       = 1'b0;
        pe_en       = 1'b0;
        weight_load = 1'b0;
        data_in     = 8'sd0;
        weight_in   = 8'sd0;
        psum_in     = 32'sd0;

        // 复位 4 拍
        repeat(4) @(negedge clk);
        rst_n = 1'b1;
        repeat(2) @(negedge clk);

        $display("======================================================");
        $display("  pe_unit Testbench — Vivado xsim 2020.1");
        $display("  Device: XCZU4EV  DSP48E2  INT8 MAC");
        $display("======================================================");

        // ── Test 1：全最大正值  127 × 127 + 0 = 16129 ──────────
        // 验证 INT8 最大正值乘法
        $display("\n[Test 1] Max positive: 127 x 127 + 0 = 16129");
        run_test(8'sd127, 8'sd127, 32'sd0, 1, 32'sd16129);

        // ── Test 2：全最小负值  -128 × -128 + 0 = 16384 ─────────
        // 验证 INT8 最小负值（负负得正）
        $display("[Test 2] Min negative: -128 x -128 + 0 = 16384");
        run_test(-8'sd128, -8'sd128, 32'sd0, 2, 32'sd16384);

        // ── Test 3：全零  0 × 0 + 0 = 0 ─────────────────────────
        // 验证零值处理
        $display("[Test 3] All zeros: 0 x 0 + 0 = 0");
        run_test(8'sd0, 8'sd0, 32'sd0, 3, 32'sd0);

        // ── Test 4：单位矩阵  1 × 1 + 100 = 101 ─────────────────
        // 验证 psum 非零初值累加
        $display("[Test 4] Identity-like: 1 x 1 + 100 = 101");
        run_test(8'sd1, 8'sd1, 32'sd100, 4, 32'sd101);

        // ── Test 5：正负混合  -50 × 30 + 200 = -1300 ────────────
        // 验证符号位处理
        $display("[Test 5] Mixed sign: -50 x 30 + 200 = -1300");
        run_test(-8'sd50, 8'sd30, 32'sd200, 5, -32'sd1300);

        // ── Test 6：4 次累加不溢出  127×127 + 48387 = 64516 ─────
        // 验证 4 次累加上限（模拟 4x4 阵列内 4 次 MAC 后的 psum）
        $display("[Test 6] Accumulation ceiling: 127 x 127 + 48387 = 64516");
        run_test(8'sd127, 8'sd127, 32'sd48387, 6, 32'sd64516);

        // ── Test 7：data_out 流水延迟验证 ───────────────────────
        // data_out 应在 pe_en 后延迟 1 拍输出
        $display("[Test 7] data_out pipeline delay (data_in=42 should appear 1 cycle later)");
        begin
            reg signed [7:0] captured;
            @(negedge clk);
            weight_in   = 8'sd1;
            weight_load = 1'b1;
            @(negedge clk);
            weight_load = 1'b0;

            @(negedge clk);
            data_in = 8'sd42;
            psum_in = 32'sd0;
            pe_en   = 1'b1;
            @(negedge clk);
            pe_en = 1'b0;
            @(negedge clk);
            captured = data_out;

            if (captured === 8'sd42) begin
                $display("[PASS] Test 7 | data_out=%0d (expected=42)", captured);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] Test 7 | data_out=%0d (expected=42)", captured);
                fail_cnt = fail_cnt + 1;
            end
        end

        // ── 汇总 ─────────────────────────────────────────────
        repeat(4) @(negedge clk);
        $display("\n======================================================");
        $display("  Results: %0d PASS,  %0d FAIL  (Total: %0d)",
                 pass_cnt, fail_cnt, pass_cnt+fail_cnt);
        if (fail_cnt == 0)
            $display("  *** ALL TESTS PASSED — pe_unit 功能验证通过 ***");
        else
            $display("  *** ATTENTION: %0d test(s) FAILED ***", fail_cnt);
        $display("======================================================");

        $finish;
    end

    // ── 超时保护：1 μs 后强制结束 ──────────────────────────────
    initial begin
        #100000;
        $display("[TIMEOUT] Simulation exceeded 100 us, forcing finish");
        $finish;
    end

    // ── 波形转储（xsim 格式）────────────────────────────────────
    initial begin
        $dumpfile("pe_unit_wave.vcd");
        $dumpvars(0, pe_unit_tb);
    end

endmodule
