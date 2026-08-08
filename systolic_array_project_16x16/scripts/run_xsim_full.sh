#!/bin/bash
# =============================================================
# 文件名  : run_xsim_full.sh
# 描述    : axi_ctrl_top 全链路仿真脚本（ACU4EV 优化版，N=16）
#           包含 axi_ctrl_top + ctrl_fsm + systolic_array + pe_unit
#           仿真结果写入 result.txt（格式与 golden_model.py 兼容）
#
# 【本版本相对初版的两处关键修复，务必了解】
#   1. AXI write/read task 时序 bug：原任务分别在两个不同的 negedge
#      清除 awvalid 与 wvalid，导致 W 通道被 stale wvalid 错误地
#      重新握手一次，bvalid 永不再置位——AXI 写事务死锁。已改为
#      awvalid/wvalid（以及 arvalid 与数据捕获）在同一个 negedge
#      一起清除，消除该竞争条件。
#   2. done 信号仅单拍脉冲：原 ctrl_fsm 的 done 只在 DONE_ST 状态
#      维持 1 个时钟周期。软件轮询几乎必然错过这个瞬间脉冲，导致
#      永久超时。已在 rtl/ctrl_fsm.v 改为电平保持（sticky）done，
#      直到下次 start 才清零。
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
echo "  axi_ctrl_top 全链路仿真 - Vivado xsim 2020.1 (N=16)"
echo "======================================================"

cat > systolic_tb_full.v << 'ENDTB'
`timescale 1ns/1ps
// 全链路仿真 Testbench (16x16, 与 golden_model.py --array_size 16 --test_id 0 一致)
// A[0][0:15] = [7, -91, 88, -107, 76, 122, -96, 69, 64, 126, 16, 38, -32, -43, -39, -17]
// 期望结果 C[0][0:15] = [-23102, -25588, 4646, 6060, -8357, 23412, 50755, 4927, 20441, -28691, -5056, 9393, 1328, 8067, 7878, -5107]
module systolic_tb_full;

    localparam N = 16;

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
        $display("[1] 加载权重矩阵 B...");
        axi_write(12'h088, 32'd163);  // B[0][0]=-93
        axi_write(12'h08C, 32'd149);  // B[0][1]=-107
        axi_write(12'h090, 32'd89);  // B[0][2]=89
        axi_write(12'h094, 32'd237);  // B[0][3]=-19
        axi_write(12'h098, 32'd65);  // B[0][4]=65
        axi_write(12'h09C, 32'd145);  // B[0][5]=-111
        axi_write(12'h0A0, 32'd76);  // B[0][6]=76
        axi_write(12'h0A4, 32'd90);  // B[0][7]=90
        axi_write(12'h0A8, 32'd12);  // B[0][8]=12
        axi_write(12'h0AC, 32'd7);  // B[0][9]=7
        axi_write(12'h0B0, 32'd149);  // B[0][10]=-107
        axi_write(12'h0B4, 32'd141);  // B[0][11]=-115
        axi_write(12'h0B8, 32'd53);  // B[0][12]=53
        axi_write(12'h0BC, 32'd5);  // B[0][13]=5
        axi_write(12'h0C0, 32'd49);  // B[0][14]=49
        axi_write(12'h0C4, 32'd106);  // B[0][15]=106
        axi_write(12'h0C8, 32'd0);  // B[1][0]=0
        axi_write(12'h0CC, 32'd18);  // B[1][1]=18
        axi_write(12'h0D0, 32'd178);  // B[1][2]=-78
        axi_write(12'h0D4, 32'd52);  // B[1][3]=52
        axi_write(12'h0D8, 32'd128);  // B[1][4]=-128
        axi_write(12'h0DC, 32'd155);  // B[1][5]=-101
        axi_write(12'h0E0, 32'd151);  // B[1][6]=-105
        axi_write(12'h0E4, 32'd11);  // B[1][7]=11
        axi_write(12'h0E8, 32'd210);  // B[1][8]=-46
        axi_write(12'h0EC, 32'd70);  // B[1][9]=70
        axi_write(12'h0F0, 32'd5);  // B[1][10]=5
        axi_write(12'h0F4, 32'd108);  // B[1][11]=108
        axi_write(12'h0F8, 32'd225);  // B[1][12]=-31
        axi_write(12'h0FC, 32'd65);  // B[1][13]=65
        axi_write(12'h100, 32'd120);  // B[1][14]=120
        axi_write(12'h104, 32'd240);  // B[1][15]=-16
        axi_write(12'h108, 32'd195);  // B[2][0]=-61
        axi_write(12'h10C, 32'd217);  // B[2][1]=-39
        axi_write(12'h110, 32'd59);  // B[2][2]=59
        axi_write(12'h114, 32'd174);  // B[2][3]=-82
        axi_write(12'h118, 32'd140);  // B[2][4]=-116
        axi_write(12'h11C, 32'd89);  // B[2][5]=89
        axi_write(12'h120, 32'd65);  // B[2][6]=65
        axi_write(12'h124, 32'd191);  // B[2][7]=-65
        axi_write(12'h128, 32'd22);  // B[2][8]=22
        axi_write(12'h12C, 32'd43);  // B[2][9]=43
        axi_write(12'h130, 32'd54);  // B[2][10]=54
        axi_write(12'h134, 32'd34);  // B[2][11]=34
        axi_write(12'h138, 32'd1);  // B[2][12]=1
        axi_write(12'h13C, 32'd186);  // B[2][13]=-70
        axi_write(12'h140, 32'd72);  // B[2][14]=72
        axi_write(12'h144, 32'd146);  // B[2][15]=-110
        axi_write(12'h148, 32'd80);  // B[3][0]=80
        axi_write(12'h14C, 32'd225);  // B[3][1]=-31
        axi_write(12'h150, 32'd2);  // B[3][2]=2
        axi_write(12'h154, 32'd149);  // B[3][3]=-107
        axi_write(12'h158, 32'd141);  // B[3][4]=-115
        axi_write(12'h15C, 32'd75);  // B[3][5]=75
        axi_write(12'h160, 32'd159);  // B[3][6]=-97
        axi_write(12'h164, 32'd237);  // B[3][7]=-19
        axi_write(12'h168, 32'd60);  // B[3][8]=60
        axi_write(12'h16C, 32'd120);  // B[3][9]=120
        axi_write(12'h170, 32'd85);  // B[3][10]=85
        axi_write(12'h174, 32'd168);  // B[3][11]=-88
        axi_write(12'h178, 32'd253);  // B[3][12]=-3
        axi_write(12'h17C, 32'd203);  // B[3][13]=-53
        axi_write(12'h180, 32'd242);  // B[3][14]=-14
        axi_write(12'h184, 32'd168);  // B[3][15]=-88
        axi_write(12'h188, 32'd143);  // B[4][0]=-113
        axi_write(12'h18C, 32'd150);  // B[4][1]=-106
        axi_write(12'h190, 32'd255);  // B[4][2]=-1
        axi_write(12'h194, 32'd10);  // B[4][3]=10
        axi_write(12'h198, 32'd29);  // B[4][4]=29
        axi_write(12'h19C, 32'd107);  // B[4][5]=107
        axi_write(12'h1A0, 32'd221);  // B[4][6]=-35
        axi_write(12'h1A4, 32'd46);  // B[4][7]=46
        axi_write(12'h1A8, 32'd17);  // B[4][8]=17
        axi_write(12'h1AC, 32'd58);  // B[4][9]=58
        axi_write(12'h1B0, 32'd173);  // B[4][10]=-83
        axi_write(12'h1B4, 32'd229);  // B[4][11]=-27
        axi_write(12'h1B8, 32'd247);  // B[4][12]=-9
        axi_write(12'h1BC, 32'd191);  // B[4][13]=-65
        axi_write(12'h1C0, 32'd108);  // B[4][14]=108
        axi_write(12'h1C4, 32'd133);  // B[4][15]=-123
        axi_write(12'h1C8, 32'd77);  // B[5][0]=77
        axi_write(12'h1CC, 32'd147);  // B[5][1]=-109
        axi_write(12'h1D0, 32'd71);  // B[5][2]=71
        axi_write(12'h1D4, 32'd176);  // B[5][3]=-80
        axi_write(12'h1D8, 32'd215);  // B[5][4]=-41
        axi_write(12'h1DC, 32'd83);  // B[5][5]=83
        axi_write(12'h1E0, 32'd35);  // B[5][6]=35
        axi_write(12'h1E4, 32'd53);  // B[5][7]=53
        axi_write(12'h1E8, 32'd31);  // B[5][8]=31
        axi_write(12'h1EC, 32'd131);  // B[5][9]=-125
        axi_write(12'h1F0, 32'd230);  // B[5][10]=-26
        axi_write(12'h1F4, 32'd204);  // B[5][11]=-52
        axi_write(12'h1F8, 32'd0);  // B[5][12]=0
        axi_write(12'h1FC, 32'd31);  // B[5][13]=31
        axi_write(12'h200, 32'd81);  // B[5][14]=81
        axi_write(12'h204, 32'd162);  // B[5][15]=-94
        axi_write(12'h208, 32'd189);  // B[6][0]=-67
        axi_write(12'h20C, 32'd32);  // B[6][1]=32
        axi_write(12'h210, 32'd10);  // B[6][2]=10
        axi_write(12'h214, 32'd73);  // B[6][3]=73
        axi_write(12'h218, 32'd22);  // B[6][4]=22
        axi_write(12'h21C, 32'd2);  // B[6][5]=2
        axi_write(12'h220, 32'd240);  // B[6][6]=-16
        axi_write(12'h224, 32'd185);  // B[6][7]=-71
        axi_write(12'h228, 32'd208);  // B[6][8]=-48
        axi_write(12'h22C, 32'd208);  // B[6][9]=-48
        axi_write(12'h230, 32'd242);  // B[6][10]=-14
        axi_write(12'h234, 32'd157);  // B[6][11]=-99
        axi_write(12'h238, 32'd208);  // B[6][12]=-48
        axi_write(12'h23C, 32'd171);  // B[6][13]=-85
        axi_write(12'h240, 32'd185);  // B[6][14]=-71
        axi_write(12'h244, 32'd161);  // B[6][15]=-95
        axi_write(12'h248, 32'd183);  // B[7][0]=-73
        axi_write(12'h24C, 32'd21);  // B[7][1]=21
        axi_write(12'h250, 32'd150);  // B[7][2]=-106
        axi_write(12'h254, 32'd66);  // B[7][3]=66
        axi_write(12'h258, 32'd195);  // B[7][4]=-61
        axi_write(12'h25C, 32'd120);  // B[7][5]=120
        axi_write(12'h260, 32'd12);  // B[7][6]=12
        axi_write(12'h264, 32'd46);  // B[7][7]=46
        axi_write(12'h268, 32'd62);  // B[7][8]=62
        axi_write(12'h26C, 32'd203);  // B[7][9]=-53
        axi_write(12'h270, 32'd98);  // B[7][10]=98
        axi_write(12'h274, 32'd98);  // B[7][11]=98
        axi_write(12'h278, 32'd210);  // B[7][12]=-46
        axi_write(12'h27C, 32'd213);  // B[7][13]=-43
        axi_write(12'h280, 32'd143);  // B[7][14]=-113
        axi_write(12'h284, 32'd237);  // B[7][15]=-19
        axi_write(12'h288, 32'd121);  // B[8][0]=121
        axi_write(12'h28C, 32'd55);  // B[8][1]=55
        axi_write(12'h290, 32'd90);  // B[8][2]=90
        axi_write(12'h294, 32'd111);  // B[8][3]=111
        axi_write(12'h298, 32'd33);  // B[8][4]=33
        axi_write(12'h29C, 32'd94);  // B[8][5]=94
        axi_write(12'h2A0, 32'd82);  // B[8][6]=82
        axi_write(12'h2A4, 32'd171);  // B[8][7]=-85
        axi_write(12'h2A8, 32'd56);  // B[8][8]=56
        axi_write(12'h2AC, 32'd88);  // B[8][9]=88
        axi_write(12'h2B0, 32'd197);  // B[8][10]=-59
        axi_write(12'h2B4, 32'd143);  // B[8][11]=-113
        axi_write(12'h2B8, 32'd65);  // B[8][12]=65
        axi_write(12'h2BC, 32'd51);  // B[8][13]=51
        axi_write(12'h2C0, 32'd32);  // B[8][14]=32
        axi_write(12'h2C4, 32'd116);  // B[8][15]=116
        axi_write(12'h2C8, 32'd242);  // B[9][0]=-14
        axi_write(12'h2CC, 32'd203);  // B[9][1]=-53
        axi_write(12'h2D0, 32'd169);  // B[9][2]=-87
        axi_write(12'h2D4, 32'd66);  // B[9][3]=66
        axi_write(12'h2D8, 32'd136);  // B[9][4]=-120
        axi_write(12'h2DC, 32'd145);  // B[9][5]=-111
        axi_write(12'h2E0, 32'd65);  // B[9][6]=65
        axi_write(12'h2E4, 32'd158);  // B[9][7]=-98
        axi_write(12'h2E8, 32'd248);  // B[9][8]=-8
        axi_write(12'h2EC, 32'd212);  // B[9][9]=-44
        axi_write(12'h2F0, 32'd50);  // B[9][10]=50
        axi_write(12'h2F4, 32'd61);  // B[9][11]=61
        axi_write(12'h2F8, 32'd181);  // B[9][12]=-75
        axi_write(12'h2FC, 32'd65);  // B[9][13]=65
        axi_write(12'h300, 32'd217);  // B[9][14]=-39
        axi_write(12'h304, 32'd8);  // B[9][15]=8
        axi_write(12'h308, 32'd179);  // B[10][0]=-77
        axi_write(12'h30C, 32'd226);  // B[10][1]=-30
        axi_write(12'h310, 32'd144);  // B[10][2]=-112
        axi_write(12'h314, 32'd236);  // B[10][3]=-20
        axi_write(12'h318, 32'd41);  // B[10][4]=41
        axi_write(12'h31C, 32'd254);  // B[10][5]=-2
        axi_write(12'h320, 32'd119);  // B[10][6]=119
        axi_write(12'h324, 32'd187);  // B[10][7]=-69
        axi_write(12'h328, 32'd18);  // B[10][8]=18
        axi_write(12'h32C, 32'd151);  // B[10][9]=-105
        axi_write(12'h330, 32'd241);  // B[10][10]=-15
        axi_write(12'h334, 32'd118);  // B[10][11]=118
        axi_write(12'h338, 32'd20);  // B[10][12]=20
        axi_write(12'h33C, 32'd34);  // B[10][13]=34
        axi_write(12'h340, 32'd99);  // B[10][14]=99
        axi_write(12'h344, 32'd47);  // B[10][15]=47
        axi_write(12'h348, 32'd152);  // B[11][0]=-104
        axi_write(12'h34C, 32'd11);  // B[11][1]=11
        axi_write(12'h350, 32'd44);  // B[11][2]=44
        axi_write(12'h354, 32'd142);  // B[11][3]=-114
        axi_write(12'h358, 32'd163);  // B[11][4]=-93
        axi_write(12'h35C, 32'd195);  // B[11][5]=-61
        axi_write(12'h360, 32'd70);  // B[11][6]=70
        axi_write(12'h364, 32'd143);  // B[11][7]=-113
        axi_write(12'h368, 32'd68);  // B[11][8]=68
        axi_write(12'h36C, 32'd7);  // B[11][9]=7
        axi_write(12'h370, 32'd65);  // B[11][10]=65
        axi_write(12'h374, 32'd35);  // B[11][11]=35
        axi_write(12'h378, 32'd86);  // B[11][12]=86
        axi_write(12'h37C, 32'd82);  // B[11][13]=82
        axi_write(12'h380, 32'd176);  // B[11][14]=-80
        axi_write(12'h384, 32'd150);  // B[11][15]=-106
        axi_write(12'h388, 32'd113);  // B[12][0]=113
        axi_write(12'h38C, 32'd167);  // B[12][1]=-89
        axi_write(12'h390, 32'd220);  // B[12][2]=-36
        axi_write(12'h394, 32'd150);  // B[12][3]=-106
        axi_write(12'h398, 32'd134);  // B[12][4]=-122
        axi_write(12'h39C, 32'd250);  // B[12][5]=-6
        axi_write(12'h3A0, 32'd246);  // B[12][6]=-10
        axi_write(12'h3A4, 32'd184);  // B[12][7]=-72
        axi_write(12'h3A8, 32'd195);  // B[12][8]=-61
        axi_write(12'h3AC, 32'd238);  // B[12][9]=-18
        axi_write(12'h3B0, 32'd254);  // B[12][10]=-2
        axi_write(12'h3B4, 32'd188);  // B[12][11]=-68
        axi_write(12'h3B8, 32'd56);  // B[12][12]=56
        axi_write(12'h3BC, 32'd181);  // B[12][13]=-75
        axi_write(12'h3C0, 32'd138);  // B[12][14]=-118
        axi_write(12'h3C4, 32'd31);  // B[12][15]=31
        axi_write(12'h3C8, 32'd121);  // B[13][0]=121
        axi_write(12'h3CC, 32'd106);  // B[13][1]=106
        axi_write(12'h3D0, 32'd10);  // B[13][2]=10
        axi_write(12'h3D4, 32'd161);  // B[13][3]=-95
        axi_write(12'h3D8, 32'd3);  // B[13][4]=3
        axi_write(12'h3DC, 32'd254);  // B[13][5]=-2
        axi_write(12'h3E0, 32'd166);  // B[13][6]=-90
        axi_write(12'h3E4, 32'd170);  // B[13][7]=-86
        axi_write(12'h3E8, 32'd97);  // B[13][8]=97
        axi_write(12'h3EC, 32'd204);  // B[13][9]=-52
        axi_write(12'h3F0, 32'd61);  // B[13][10]=61
        axi_write(12'h3F4, 32'd82);  // B[13][11]=82
        axi_write(12'h3F8, 32'd202);  // B[13][12]=-54
        axi_write(12'h3FC, 32'd91);  // B[13][13]=91
        axi_write(12'h400, 32'd45);  // B[13][14]=45
        axi_write(12'h404, 32'd83);  // B[13][15]=83
        axi_write(12'h408, 32'd71);  // B[14][0]=71
        axi_write(12'h40C, 32'd169);  // B[14][1]=-87
        axi_write(12'h410, 32'd107);  // B[14][2]=107
        axi_write(12'h414, 32'd13);  // B[14][3]=13
        axi_write(12'h418, 32'd58);  // B[14][4]=58
        axi_write(12'h41C, 32'd39);  // B[14][5]=39
        axi_write(12'h420, 32'd61);  // B[14][6]=61
        axi_write(12'h424, 32'd138);  // B[14][7]=-118
        axi_write(12'h428, 32'd202);  // B[14][8]=-54
        axi_write(12'h42C, 32'd91);  // B[14][9]=91
        axi_write(12'h430, 32'd220);  // B[14][10]=-36
        axi_write(12'h434, 32'd66);  // B[14][11]=66
        axi_write(12'h438, 32'd54);  // B[14][12]=54
        axi_write(12'h43C, 32'd45);  // B[14][13]=45
        axi_write(12'h440, 32'd118);  // B[14][14]=118
        axi_write(12'h444, 32'd161);  // B[14][15]=-95
        axi_write(12'h448, 32'd252);  // B[15][0]=-4
        axi_write(12'h44C, 32'd172);  // B[15][1]=-84
        axi_write(12'h450, 32'd232);  // B[15][2]=-24
        axi_write(12'h454, 32'd232);  // B[15][3]=-24
        axi_write(12'h458, 32'd201);  // B[15][4]=-55
        axi_write(12'h45C, 32'd232);  // B[15][5]=-24
        axi_write(12'h460, 32'd210);  // B[15][6]=-46
        axi_write(12'h464, 32'd161);  // B[15][7]=-95
        axi_write(12'h468, 32'd176);  // B[15][8]=-80
        axi_write(12'h46C, 32'd80);  // B[15][9]=80
        axi_write(12'h470, 32'd102);  // B[15][10]=102
        axi_write(12'h474, 32'd0);  // B[15][11]=0
        axi_write(12'h478, 32'd241);  // B[15][12]=-15
        axi_write(12'h47C, 32'd85);  // B[15][13]=85
        axi_write(12'h480, 32'd221);  // B[15][14]=-35
        axi_write(12'h484, 32'd158);  // B[15][15]=-98
        $display("[2] 加载数据向量 A...");
        axi_write(12'h048, 32'd7);  // A[0]=7
        axi_write(12'h04C, 32'd165);  // A[1]=-91
        axi_write(12'h050, 32'd88);  // A[2]=88
        axi_write(12'h054, 32'd149);  // A[3]=-107
        axi_write(12'h058, 32'd76);  // A[4]=76
        axi_write(12'h05C, 32'd122);  // A[5]=122
        axi_write(12'h060, 32'd160);  // A[6]=-96
        axi_write(12'h064, 32'd69);  // A[7]=69
        axi_write(12'h068, 32'd64);  // A[8]=64
        axi_write(12'h06C, 32'd126);  // A[9]=126
        axi_write(12'h070, 32'd16);  // A[10]=16
        axi_write(12'h074, 32'd38);  // A[11]=38
        axi_write(12'h078, 32'd224);  // A[12]=-32
        axi_write(12'h07C, 32'd213);  // A[13]=-43
        axi_write(12'h080, 32'd217);  // A[14]=-39
        axi_write(12'h084, 32'd239);  // A[15]=-17

        $display("[3] 触发计算...");
        axi_write(12'h000, 32'h1);

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
                if (timeout_cnt > 3000) begin
                    $display("[ERROR] 超时！STATUS=%h", status);
                    $finish;
                end
            end
        end

        $display("[5] 读取结果寄存器...");
        result_file = $fopen("result.txt", "w");
        axi_read(12'h008, results[0]);
        axi_read(12'h00C, results[1]);
        axi_read(12'h010, results[2]);
        axi_read(12'h014, results[3]);
        axi_read(12'h018, results[4]);
        axi_read(12'h01C, results[5]);
        axi_read(12'h020, results[6]);
        axi_read(12'h024, results[7]);
        axi_read(12'h028, results[8]);
        axi_read(12'h02C, results[9]);
        axi_read(12'h030, results[10]);
        axi_read(12'h034, results[11]);
        axi_read(12'h038, results[12]);
        axi_read(12'h03C, results[13]);
        axi_read(12'h040, results[14]);
        axi_read(12'h044, results[15]);

        for (i = 0; i < N; i = i + 1) begin
            $display("    C[0][%0d] = %0d", i, $signed(results[i]));
            $fdisplay(result_file, "%0d", $signed(results[i]));
        end
        $fclose(result_file);

        if ($signed(results[0])==-23102 && $signed(results[1])==-25588 && $signed(results[2])==4646 && $signed(results[3])==6060 && $signed(results[4])==-8357 && $signed(results[5])==23412 && $signed(results[6])==50755 && $signed(results[7])==4927 && $signed(results[8])==20441 && $signed(results[9])==-28691 && $signed(results[10])==-5056 && $signed(results[11])==9393 && $signed(results[12])==1328 && $signed(results[13])==8067 && $signed(results[14])==7878 && $signed(results[15])==-5107) begin
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
        #1000000;
        $display("[TIMEOUT] 仿真超时");
        $finish;
    end

    initial begin
        $dumpfile("systolic_full_wave.vcd");
        $dumpvars(0, systolic_tb_full);
    end

endmodule
ENDTB

echo "Testbench 生成完成"

echo "[Step 1] 编译所有 RTL 源文件..."
xvlog -sv \
    ../rtl/pe_unit.v \
    ../rtl/systolic_array.v \
    ../rtl/ctrl_fsm.v \
    ../rtl/axi_ctrl_top.v \
    systolic_tb_full.v \
    -log xvlog_full.log

echo "[Step 2] 精化..."
xelab -debug typical \
    systolic_tb_full \
    -s systolic_full_sim \
    -log xelab_full.log

echo "[Step 3] 运行仿真..."
xsim systolic_full_sim -runall -log xsim_full.log

echo ""
echo "======================================================"
echo "  仿真结果："
grep -E "PASS|FAIL|C\[0\]|ERROR|TIMEOUT" xsim_full.log || true
echo ""
echo "  结果文件: sim_work/result.txt"
echo "  使用 golden_model.py 验证："
echo "    python3 ../python/golden_model.py --mode sim --array_size 16 --test_id 0"
echo "======================================================"
