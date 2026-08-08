#!/bin/bash
# =============================================================
# 文件名  : run_xsim_full.sh
# 描述    : axi_ctrl_top 全链路仿真脚本（ACU4EV 优化版，N=8)
#           包含 axi_ctrl_top + ctrl_fsm + systolic_array + pe_unit
#           仿真结果写入 result.txt（格式与 golden_model.py 兼容）
#
# 【本版本相对初版的两处关键修复，务必了解】
#   1. AXI write/read task 时序 bug：原任务分别在两个不同的 negedge
#      清除 awvalid 与 wvalid（先清 aw 再清 w），中间因 Verilog
#      `@(negedge)` 不会在"已经过去的沿"上重新触发，wvalid 会多保持
#      一个额外的半周期，导致 W 通道在 aw_done 已清零后又被 stale
#      wvalid 错误地重新握手一次，使 w_done 永久卡在 1、aw_done
#      卡在 0，bvalid 永不再置位——AXI 写事务从此死锁。
#      本版本已改为 awvalid/wvalid（以及 arvalid 与数据捕获）在
#      同一个 negedge 一起清除，消除该竞争条件。
#   2. done 信号仅单拍脉冲：原 ctrl_fsm 的 done 只在 DONE_ST 状态
#      维持 1 个时钟周期（@100MHz 即 10ns）。真实场景下无论是 xsim
#      的 AXI 读事务，还是 ARM 端 /dev/mem 软件轮询，单次开销都是
#      微秒级，几乎必然错过这个瞬间脉冲，导致轮询永久超时——这在
#      真实板卡上会直接表现为 test_app 卡死。已在 rtl/ctrl_fsm.v
#      改为电平保持（sticky）done，直到下次 start 才清零。
#   这两处问题都是通过本次完整 AXI 事务级仿真才真正发现和修复的，
#   在此之前的版本从未被端到端仿真验证过。
#
# 运行    : bash run_xsim_full.sh
# 输出    : sim_work/result.txt, sim_work/xsim_full.log
# =============================================================

set -e

VIVADO_SETTINGS="/tools/Xilinx/Vivado/2020.1/settings64.sh"
source "${VIVADO_SETTINGS}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
cd "${PROJECT_DIR}"
mkdir -p sim_work
cd sim_work

echo "======================================================"
echo "  axi_ctrl_top 全链路仿真 - Vivado xsim 2020.1 (N=8)"
echo "======================================================"

# 生成顶层仿真 Testbench（内嵌测试向量，与 golden_model.py --array_size 8 --test_id 0 一致）
cat > systolic_tb_full.v << 'ENDTB'
`timescale 1ns/1ps
// =============================================================
// 全链路仿真 Testbench (8x8, 与 golden_model.py --array_size 8 --test_id 0 一致)
// 测试矩阵:
//   A[0][0:7] = [7, -91, 88, -107, 76, 122, -96, 69]
//   B = 8x8 矩阵（见下方写入序列，行主序 B[i][j]）
// 期望结果 C[0][0:7] = [2437, 3604, -6525, -26132, -12318, 48740, 11803, -55]
// =============================================================
module systolic_tb_full;

    localparam N = 8;

    // AXI4-Lite 信号
    reg         aclk, aresetn;
    reg  [11:0] awaddr;
    reg         awvalid;
    wire        awready;
    reg  [31:0] wdata;
    reg  [3:0]  wstrb;
    reg         wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready;
    reg  [11:0] araddr;
    reg         arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready;

    integer result_file;
    integer timeout_cnt;
    integer i;
    reg [31:0] results [0:N-1];

    // DUT 例化
    axi_ctrl_top #(.ARRAY_SIZE(N), .C_S_AXI_ADDR_WIDTH(12)) dut (
        .s_axi_aclk    (aclk),
        .s_axi_aresetn (aresetn),
        .s_axi_awaddr  (awaddr),
        .s_axi_awprot  (3'b0),
        .s_axi_awvalid (awvalid),
        .s_axi_awready (awready),
        .s_axi_wdata   (wdata),
        .s_axi_wstrb   (wstrb),
        .s_axi_wvalid  (wvalid),
        .s_axi_wready  (wready),
        .s_axi_bresp   (bresp),
        .s_axi_bvalid  (bvalid),
        .s_axi_bready  (bready),
        .s_axi_araddr  (araddr),
        .s_axi_arprot  (3'b0),
        .s_axi_arvalid (arvalid),
        .s_axi_arready (arready),
        .s_axi_rdata   (rdata),
        .s_axi_rresp   (rresp),
        .s_axi_rvalid  (rvalid),
        .s_axi_rready  (rready)
    );

    initial aclk = 0;
    always #5 aclk = ~aclk;

    // AXI4-Lite 写操作任务【已修复：awvalid/wvalid 同一 negedge 一起清除】
    task axi_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge aclk);
            awaddr  = addr;
            awvalid = 1'b1;
            wdata   = data;
            wstrb   = 4'hF;
            wvalid  = 1'b1;
            bready  = 1'b1;
            @(posedge aclk);
            while (!awready) @(posedge aclk);
            while (!wready)  @(posedge aclk);
            @(negedge aclk);
            awvalid = 1'b0;
            wvalid  = 1'b0;
            while (!bvalid) @(posedge aclk);
            @(negedge aclk);
            bready  = 1'b0;
        end
    endtask

    // AXI4-Lite 读操作任务【已修复】
    task axi_read;
        input  [11:0] addr;
        output [31:0] data;
        begin
            @(negedge aclk);
            araddr  = addr;
            arvalid = 1'b1;
            rready  = 1'b1;
            @(posedge aclk);
            while (!arready) @(posedge aclk);
            while (!rvalid)  @(posedge aclk);
            @(negedge aclk);
            arvalid = 1'b0;
            data    = rdata;
            rready  = 1'b0;
        end
    endtask

    initial begin
        aresetn = 1'b0;
        awvalid = 0; wvalid = 0; bready = 0;
        arvalid = 0; rready = 0;
        awaddr  = 0; wdata  = 0; wstrb = 4'hF;
        araddr  = 0;

        repeat(8) @(negedge aclk);
        aresetn = 1'b1;
        repeat(4) @(negedge aclk);

        $display("=== axi_ctrl_top 全链路仿真 (N=%0d) ===", N);
        $display("测试矩阵: A[0]=[7, -91, 88, -107, 76, 122, -96, 69]");

        // 加载权重矩阵 B (WEIGHT_BASE 字索引=18, 字节偏移=0x48 起)
        $display("[1] 加载权重矩阵 B...");
        axi_write(12'h048, 32'd64);  // B[0][0]=64
        axi_write(12'h04C, 32'd126);  // B[0][1]=126
        axi_write(12'h050, 32'd16);  // B[0][2]=16
        axi_write(12'h054, 32'd38);  // B[0][3]=38
        axi_write(12'h058, 32'd224);  // B[0][4]=-32
        axi_write(12'h05C, 32'd213);  // B[0][5]=-43
        axi_write(12'h060, 32'd217);  // B[0][6]=-39
        axi_write(12'h064, 32'd239);  // B[0][7]=-17
        axi_write(12'h068, 32'd163);  // B[1][0]=-93
        axi_write(12'h06C, 32'd149);  // B[1][1]=-107
        axi_write(12'h070, 32'd89);  // B[1][2]=89
        axi_write(12'h074, 32'd237);  // B[1][3]=-19
        axi_write(12'h078, 32'd65);  // B[1][4]=65
        axi_write(12'h07C, 32'd145);  // B[1][5]=-111
        axi_write(12'h080, 32'd76);  // B[1][6]=76
        axi_write(12'h084, 32'd90);  // B[1][7]=90
        axi_write(12'h088, 32'd12);  // B[2][0]=12
        axi_write(12'h08C, 32'd7);  // B[2][1]=7
        axi_write(12'h090, 32'd149);  // B[2][2]=-107
        axi_write(12'h094, 32'd141);  // B[2][3]=-115
        axi_write(12'h098, 32'd53);  // B[2][4]=53
        axi_write(12'h09C, 32'd5);  // B[2][5]=5
        axi_write(12'h0A0, 32'd49);  // B[2][6]=49
        axi_write(12'h0A4, 32'd106);  // B[2][7]=106
        axi_write(12'h0A8, 32'd0);  // B[3][0]=0
        axi_write(12'h0AC, 32'd18);  // B[3][1]=18
        axi_write(12'h0B0, 32'd178);  // B[3][2]=-78
        axi_write(12'h0B4, 32'd52);  // B[3][3]=52
        axi_write(12'h0B8, 32'd128);  // B[3][4]=-128
        axi_write(12'h0BC, 32'd155);  // B[3][5]=-101
        axi_write(12'h0C0, 32'd151);  // B[3][6]=-105
        axi_write(12'h0C4, 32'd11);  // B[3][7]=11
        axi_write(12'h0C8, 32'd210);  // B[4][0]=-46
        axi_write(12'h0CC, 32'd70);  // B[4][1]=70
        axi_write(12'h0D0, 32'd5);  // B[4][2]=5
        axi_write(12'h0D4, 32'd108);  // B[4][3]=108
        axi_write(12'h0D8, 32'd225);  // B[4][4]=-31
        axi_write(12'h0DC, 32'd65);  // B[4][5]=65
        axi_write(12'h0E0, 32'd120);  // B[4][6]=120
        axi_write(12'h0E4, 32'd240);  // B[4][7]=-16
        axi_write(12'h0E8, 32'd195);  // B[5][0]=-61
        axi_write(12'h0EC, 32'd217);  // B[5][1]=-39
        axi_write(12'h0F0, 32'd59);  // B[5][2]=59
        axi_write(12'h0F4, 32'd174);  // B[5][3]=-82
        axi_write(12'h0F8, 32'd140);  // B[5][4]=-116
        axi_write(12'h0FC, 32'd89);  // B[5][5]=89
        axi_write(12'h100, 32'd65);  // B[5][6]=65
        axi_write(12'h104, 32'd191);  // B[5][7]=-65
        axi_write(12'h108, 32'd22);  // B[6][0]=22
        axi_write(12'h10C, 32'd43);  // B[6][1]=43
        axi_write(12'h110, 32'd54);  // B[6][2]=54
        axi_write(12'h114, 32'd34);  // B[6][3]=34
        axi_write(12'h118, 32'd1);  // B[6][4]=1
        axi_write(12'h11C, 32'd186);  // B[6][5]=-70
        axi_write(12'h120, 32'd72);  // B[6][6]=72
        axi_write(12'h124, 32'd146);  // B[6][7]=-110
        axi_write(12'h128, 32'd80);  // B[7][0]=80
        axi_write(12'h12C, 32'd225);  // B[7][1]=-31
        axi_write(12'h130, 32'd2);  // B[7][2]=2
        axi_write(12'h134, 32'd149);  // B[7][3]=-107
        axi_write(12'h138, 32'd141);  // B[7][4]=-115
        axi_write(12'h13C, 32'd75);  // B[7][5]=75
        axi_write(12'h140, 32'd159);  // B[7][6]=-97
        axi_write(12'h144, 32'd237);  // B[7][7]=-19

        // 加载数据向量 A (DATA_BASE 字索引=10, 字节偏移=0x28 起)
        $display("[2] 加载数据向量 A...");
        axi_write(12'h028, 32'd7);  // A[0]=7
        axi_write(12'h02C, 32'd165);  // A[1]=-91
        axi_write(12'h030, 32'd88);  // A[2]=88
        axi_write(12'h034, 32'd149);  // A[3]=-107
        axi_write(12'h038, 32'd76);  // A[4]=76
        axi_write(12'h03C, 32'd122);  // A[5]=122
        axi_write(12'h040, 32'd160);  // A[6]=-96
        axi_write(12'h044, 32'd69);  // A[7]=69

        // 触发计算（写 CTRL_REG bit0=1）
        $display("[3] 触发计算...");
        axi_write(12'h000, 32'h1);

        // 轮询 STATUS_REG（等待 done=1，现为电平保持型信号）
        $display("[4] 等待完成...");
        timeout_cnt = 0;
        begin : poll_block
            reg [31:0] status;
            forever begin
                axi_read(12'h004, status);
                if (status[0] == 1'b1) begin
                    $display("    done=1，计算完成");
                    disable poll_block;
                end
                timeout_cnt = timeout_cnt + 1;
                if (timeout_cnt > 2000) begin
                    $display("[ERROR] 超时！STATUS=%h", status);
                    $finish;
                end
            end
        end

        // 读取结果
        $display("[5] 读取结果寄存器...");
        result_file = $fopen("result.txt", "w");
        // RESULT_BASE 字索引=2, 字节偏移=0x8 起
        axi_read(12'h008, results[0]);
        axi_read(12'h00C, results[1]);
        axi_read(12'h010, results[2]);
        axi_read(12'h014, results[3]);
        axi_read(12'h018, results[4]);
        axi_read(12'h01C, results[5]);
        axi_read(12'h020, results[6]);
        axi_read(12'h024, results[7]);

        for (i = 0; i < N; i = i + 1) begin
            $display("    C[0][%0d] = %0d", i, $signed(results[i]));
            $fdisplay(result_file, "%0d", $signed(results[i]));
        end
        $fclose(result_file);

        if ($signed(results[0])==2437 && $signed(results[1])==3604 && $signed(results[2])==-6525 && $signed(results[3])==-26132 && $signed(results[4])==-12318 && $signed(results[5])==48740 && $signed(results[6])==11803 && $signed(results[7])==-55) begin
            $display("");
            $display("*** 全链路仿真 PASS *** 结果已写入 result.txt");
        end else begin
            $display("");
            $display("*** 全链路仿真 FAIL *** 请检查 RTL 逻辑");
        end

        repeat(10) @(negedge aclk);
        $finish;
    end

    initial begin
        #500000;
        $display("[TIMEOUT] 仿真超时 500us");
        $finish;
    end

    initial begin
        $dumpfile("systolic_full_wave.vcd");
        $dumpvars(0, systolic_tb_full);
    end

endmodule
ENDTB

echo "Testbench 生成完成"

# 编译
echo "[Step 1] 编译所有 RTL 源文件..."
xvlog -sv \
    ../rtl/pe_unit.v \
    ../rtl/systolic_array.v \
    ../rtl/ctrl_fsm.v \
    ../rtl/axi_ctrl_top.v \
    systolic_tb_full.v \
    -log xvlog_full.log

# 精化
echo "[Step 2] 精化..."
xelab -debug typical \
    systolic_tb_full \
    -s systolic_full_sim \
    -log xelab_full.log

# 仿真
echo "[Step 3] 运行仿真..."
xsim systolic_full_sim -runall -log xsim_full.log

echo ""
echo "======================================================"
echo "  仿真结果："
grep -E "PASS|FAIL|C\[0\]|ERROR|TIMEOUT" xsim_full.log || true
echo ""
echo "  结果文件: sim_work/result.txt"
echo "  使用 golden_model.py 验证："
echo "    python3 ../python/golden_model.py --mode sim --array_size 8 --test_id 0"
echo "======================================================"
