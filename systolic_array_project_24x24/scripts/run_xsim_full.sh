#!/bin/bash
# =============================================================
# 文件名  : run_xsim_full.sh
# 描述    : axi_ctrl_top 全链路仿真脚本（ACU4EV 优化版，N=24）
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
echo "  axi_ctrl_top 全链路仿真 - Vivado xsim 2020.1 (N=24)"
echo "======================================================"

cat > systolic_tb_full.v << 'ENDTB'
`timescale 1ns/1ps
// 全链路仿真 Testbench (24x24, 与 golden_model.py --array_size 24 --test_id 0 一致)
// A[0][0:23] = [7, -91, 88, -107, 76, 122, -96, 69, 64, 126, 16, 38, -32, -43, -39, -17, -93, -107, 89, -19, 65, -111, 76, 90]
// 期望结果 C[0][0:23] = [2566, 36255, 23427, 4840, 36411, -6258, 7748, -32727, -27082, 13872, -30293, -7189, -4038, 39076, -43472, 37009, 4513, 2772, -32319, 9327, -33190, -21487, -9311, -6247]
module systolic_tb_full;

    localparam N = 24;

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
        axi_write(12'h0C8, 32'd12);  // B[0][0]=12
        axi_write(12'h0CC, 32'd7);  // B[0][1]=7
        axi_write(12'h0D0, 32'd149);  // B[0][2]=-107
        axi_write(12'h0D4, 32'd141);  // B[0][3]=-115
        axi_write(12'h0D8, 32'd53);  // B[0][4]=53
        axi_write(12'h0DC, 32'd5);  // B[0][5]=5
        axi_write(12'h0E0, 32'd49);  // B[0][6]=49
        axi_write(12'h0E4, 32'd106);  // B[0][7]=106
        axi_write(12'h0E8, 32'd0);  // B[0][8]=0
        axi_write(12'h0EC, 32'd18);  // B[0][9]=18
        axi_write(12'h0F0, 32'd178);  // B[0][10]=-78
        axi_write(12'h0F4, 32'd52);  // B[0][11]=52
        axi_write(12'h0F8, 32'd128);  // B[0][12]=-128
        axi_write(12'h0FC, 32'd155);  // B[0][13]=-101
        axi_write(12'h100, 32'd151);  // B[0][14]=-105
        axi_write(12'h104, 32'd11);  // B[0][15]=11
        axi_write(12'h108, 32'd210);  // B[0][16]=-46
        axi_write(12'h10C, 32'd70);  // B[0][17]=70
        axi_write(12'h110, 32'd5);  // B[0][18]=5
        axi_write(12'h114, 32'd108);  // B[0][19]=108
        axi_write(12'h118, 32'd225);  // B[0][20]=-31
        axi_write(12'h11C, 32'd65);  // B[0][21]=65
        axi_write(12'h120, 32'd120);  // B[0][22]=120
        axi_write(12'h124, 32'd240);  // B[0][23]=-16
        axi_write(12'h128, 32'd195);  // B[1][0]=-61
        axi_write(12'h12C, 32'd217);  // B[1][1]=-39
        axi_write(12'h130, 32'd59);  // B[1][2]=59
        axi_write(12'h134, 32'd174);  // B[1][3]=-82
        axi_write(12'h138, 32'd140);  // B[1][4]=-116
        axi_write(12'h13C, 32'd89);  // B[1][5]=89
        axi_write(12'h140, 32'd65);  // B[1][6]=65
        axi_write(12'h144, 32'd191);  // B[1][7]=-65
        axi_write(12'h148, 32'd22);  // B[1][8]=22
        axi_write(12'h14C, 32'd43);  // B[1][9]=43
        axi_write(12'h150, 32'd54);  // B[1][10]=54
        axi_write(12'h154, 32'd34);  // B[1][11]=34
        axi_write(12'h158, 32'd1);  // B[1][12]=1
        axi_write(12'h15C, 32'd186);  // B[1][13]=-70
        axi_write(12'h160, 32'd72);  // B[1][14]=72
        axi_write(12'h164, 32'd146);  // B[1][15]=-110
        axi_write(12'h168, 32'd80);  // B[1][16]=80
        axi_write(12'h16C, 32'd225);  // B[1][17]=-31
        axi_write(12'h170, 32'd2);  // B[1][18]=2
        axi_write(12'h174, 32'd149);  // B[1][19]=-107
        axi_write(12'h178, 32'd141);  // B[1][20]=-115
        axi_write(12'h17C, 32'd75);  // B[1][21]=75
        axi_write(12'h180, 32'd159);  // B[1][22]=-97
        axi_write(12'h184, 32'd237);  // B[1][23]=-19
        axi_write(12'h188, 32'd60);  // B[2][0]=60
        axi_write(12'h18C, 32'd120);  // B[2][1]=120
        axi_write(12'h190, 32'd85);  // B[2][2]=85
        axi_write(12'h194, 32'd168);  // B[2][3]=-88
        axi_write(12'h198, 32'd253);  // B[2][4]=-3
        axi_write(12'h19C, 32'd203);  // B[2][5]=-53
        axi_write(12'h1A0, 32'd242);  // B[2][6]=-14
        axi_write(12'h1A4, 32'd168);  // B[2][7]=-88
        axi_write(12'h1A8, 32'd143);  // B[2][8]=-113
        axi_write(12'h1AC, 32'd150);  // B[2][9]=-106
        axi_write(12'h1B0, 32'd255);  // B[2][10]=-1
        axi_write(12'h1B4, 32'd10);  // B[2][11]=10
        axi_write(12'h1B8, 32'd29);  // B[2][12]=29
        axi_write(12'h1BC, 32'd107);  // B[2][13]=107
        axi_write(12'h1C0, 32'd221);  // B[2][14]=-35
        axi_write(12'h1C4, 32'd46);  // B[2][15]=46
        axi_write(12'h1C8, 32'd17);  // B[2][16]=17
        axi_write(12'h1CC, 32'd58);  // B[2][17]=58
        axi_write(12'h1D0, 32'd173);  // B[2][18]=-83
        axi_write(12'h1D4, 32'd229);  // B[2][19]=-27
        axi_write(12'h1D8, 32'd247);  // B[2][20]=-9
        axi_write(12'h1DC, 32'd191);  // B[2][21]=-65
        axi_write(12'h1E0, 32'd108);  // B[2][22]=108
        axi_write(12'h1E4, 32'd133);  // B[2][23]=-123
        axi_write(12'h1E8, 32'd77);  // B[3][0]=77
        axi_write(12'h1EC, 32'd147);  // B[3][1]=-109
        axi_write(12'h1F0, 32'd71);  // B[3][2]=71
        axi_write(12'h1F4, 32'd176);  // B[3][3]=-80
        axi_write(12'h1F8, 32'd215);  // B[3][4]=-41
        axi_write(12'h1FC, 32'd83);  // B[3][5]=83
        axi_write(12'h200, 32'd35);  // B[3][6]=35
        axi_write(12'h204, 32'd53);  // B[3][7]=53
        axi_write(12'h208, 32'd31);  // B[3][8]=31
        axi_write(12'h20C, 32'd131);  // B[3][9]=-125
        axi_write(12'h210, 32'd230);  // B[3][10]=-26
        axi_write(12'h214, 32'd204);  // B[3][11]=-52
        axi_write(12'h218, 32'd0);  // B[3][12]=0
        axi_write(12'h21C, 32'd31);  // B[3][13]=31
        axi_write(12'h220, 32'd81);  // B[3][14]=81
        axi_write(12'h224, 32'd162);  // B[3][15]=-94
        axi_write(12'h228, 32'd189);  // B[3][16]=-67
        axi_write(12'h22C, 32'd32);  // B[3][17]=32
        axi_write(12'h230, 32'd10);  // B[3][18]=10
        axi_write(12'h234, 32'd73);  // B[3][19]=73
        axi_write(12'h238, 32'd22);  // B[3][20]=22
        axi_write(12'h23C, 32'd2);  // B[3][21]=2
        axi_write(12'h240, 32'd240);  // B[3][22]=-16
        axi_write(12'h244, 32'd185);  // B[3][23]=-71
        axi_write(12'h248, 32'd208);  // B[4][0]=-48
        axi_write(12'h24C, 32'd208);  // B[4][1]=-48
        axi_write(12'h250, 32'd242);  // B[4][2]=-14
        axi_write(12'h254, 32'd157);  // B[4][3]=-99
        axi_write(12'h258, 32'd208);  // B[4][4]=-48
        axi_write(12'h25C, 32'd171);  // B[4][5]=-85
        axi_write(12'h260, 32'd185);  // B[4][6]=-71
        axi_write(12'h264, 32'd161);  // B[4][7]=-95
        axi_write(12'h268, 32'd183);  // B[4][8]=-73
        axi_write(12'h26C, 32'd21);  // B[4][9]=21
        axi_write(12'h270, 32'd150);  // B[4][10]=-106
        axi_write(12'h274, 32'd66);  // B[4][11]=66
        axi_write(12'h278, 32'd195);  // B[4][12]=-61
        axi_write(12'h27C, 32'd120);  // B[4][13]=120
        axi_write(12'h280, 32'd12);  // B[4][14]=12
        axi_write(12'h284, 32'd46);  // B[4][15]=46
        axi_write(12'h288, 32'd62);  // B[4][16]=62
        axi_write(12'h28C, 32'd203);  // B[4][17]=-53
        axi_write(12'h290, 32'd98);  // B[4][18]=98
        axi_write(12'h294, 32'd98);  // B[4][19]=98
        axi_write(12'h298, 32'd210);  // B[4][20]=-46
        axi_write(12'h29C, 32'd213);  // B[4][21]=-43
        axi_write(12'h2A0, 32'd143);  // B[4][22]=-113
        axi_write(12'h2A4, 32'd237);  // B[4][23]=-19
        axi_write(12'h2A8, 32'd121);  // B[5][0]=121
        axi_write(12'h2AC, 32'd55);  // B[5][1]=55
        axi_write(12'h2B0, 32'd90);  // B[5][2]=90
        axi_write(12'h2B4, 32'd111);  // B[5][3]=111
        axi_write(12'h2B8, 32'd33);  // B[5][4]=33
        axi_write(12'h2BC, 32'd94);  // B[5][5]=94
        axi_write(12'h2C0, 32'd82);  // B[5][6]=82
        axi_write(12'h2C4, 32'd171);  // B[5][7]=-85
        axi_write(12'h2C8, 32'd56);  // B[5][8]=56
        axi_write(12'h2CC, 32'd88);  // B[5][9]=88
        axi_write(12'h2D0, 32'd197);  // B[5][10]=-59
        axi_write(12'h2D4, 32'd143);  // B[5][11]=-113
        axi_write(12'h2D8, 32'd65);  // B[5][12]=65
        axi_write(12'h2DC, 32'd51);  // B[5][13]=51
        axi_write(12'h2E0, 32'd32);  // B[5][14]=32
        axi_write(12'h2E4, 32'd116);  // B[5][15]=116
        axi_write(12'h2E8, 32'd242);  // B[5][16]=-14
        axi_write(12'h2EC, 32'd203);  // B[5][17]=-53
        axi_write(12'h2F0, 32'd169);  // B[5][18]=-87
        axi_write(12'h2F4, 32'd66);  // B[5][19]=66
        axi_write(12'h2F8, 32'd136);  // B[5][20]=-120
        axi_write(12'h2FC, 32'd145);  // B[5][21]=-111
        axi_write(12'h300, 32'd65);  // B[5][22]=65
        axi_write(12'h304, 32'd158);  // B[5][23]=-98
        axi_write(12'h308, 32'd248);  // B[6][0]=-8
        axi_write(12'h30C, 32'd212);  // B[6][1]=-44
        axi_write(12'h310, 32'd50);  // B[6][2]=50
        axi_write(12'h314, 32'd61);  // B[6][3]=61
        axi_write(12'h318, 32'd181);  // B[6][4]=-75
        axi_write(12'h31C, 32'd65);  // B[6][5]=65
        axi_write(12'h320, 32'd217);  // B[6][6]=-39
        axi_write(12'h324, 32'd8);  // B[6][7]=8
        axi_write(12'h328, 32'd179);  // B[6][8]=-77
        axi_write(12'h32C, 32'd226);  // B[6][9]=-30
        axi_write(12'h330, 32'd144);  // B[6][10]=-112
        axi_write(12'h334, 32'd236);  // B[6][11]=-20
        axi_write(12'h338, 32'd41);  // B[6][12]=41
        axi_write(12'h33C, 32'd254);  // B[6][13]=-2
        axi_write(12'h340, 32'd119);  // B[6][14]=119
        axi_write(12'h344, 32'd187);  // B[6][15]=-69
        axi_write(12'h348, 32'd18);  // B[6][16]=18
        axi_write(12'h34C, 32'd151);  // B[6][17]=-105
        axi_write(12'h350, 32'd241);  // B[6][18]=-15
        axi_write(12'h354, 32'd118);  // B[6][19]=118
        axi_write(12'h358, 32'd20);  // B[6][20]=20
        axi_write(12'h35C, 32'd34);  // B[6][21]=34
        axi_write(12'h360, 32'd99);  // B[6][22]=99
        axi_write(12'h364, 32'd47);  // B[6][23]=47
        axi_write(12'h368, 32'd152);  // B[7][0]=-104
        axi_write(12'h36C, 32'd11);  // B[7][1]=11
        axi_write(12'h370, 32'd44);  // B[7][2]=44
        axi_write(12'h374, 32'd142);  // B[7][3]=-114
        axi_write(12'h378, 32'd163);  // B[7][4]=-93
        axi_write(12'h37C, 32'd195);  // B[7][5]=-61
        axi_write(12'h380, 32'd70);  // B[7][6]=70
        axi_write(12'h384, 32'd143);  // B[7][7]=-113
        axi_write(12'h388, 32'd68);  // B[7][8]=68
        axi_write(12'h38C, 32'd7);  // B[7][9]=7
        axi_write(12'h390, 32'd65);  // B[7][10]=65
        axi_write(12'h394, 32'd35);  // B[7][11]=35
        axi_write(12'h398, 32'd86);  // B[7][12]=86
        axi_write(12'h39C, 32'd82);  // B[7][13]=82
        axi_write(12'h3A0, 32'd176);  // B[7][14]=-80
        axi_write(12'h3A4, 32'd150);  // B[7][15]=-106
        axi_write(12'h3A8, 32'd113);  // B[7][16]=113
        axi_write(12'h3AC, 32'd167);  // B[7][17]=-89
        axi_write(12'h3B0, 32'd220);  // B[7][18]=-36
        axi_write(12'h3B4, 32'd150);  // B[7][19]=-106
        axi_write(12'h3B8, 32'd134);  // B[7][20]=-122
        axi_write(12'h3BC, 32'd250);  // B[7][21]=-6
        axi_write(12'h3C0, 32'd246);  // B[7][22]=-10
        axi_write(12'h3C4, 32'd184);  // B[7][23]=-72
        axi_write(12'h3C8, 32'd195);  // B[8][0]=-61
        axi_write(12'h3CC, 32'd238);  // B[8][1]=-18
        axi_write(12'h3D0, 32'd254);  // B[8][2]=-2
        axi_write(12'h3D4, 32'd188);  // B[8][3]=-68
        axi_write(12'h3D8, 32'd56);  // B[8][4]=56
        axi_write(12'h3DC, 32'd181);  // B[8][5]=-75
        axi_write(12'h3E0, 32'd138);  // B[8][6]=-118
        axi_write(12'h3E4, 32'd31);  // B[8][7]=31
        axi_write(12'h3E8, 32'd121);  // B[8][8]=121
        axi_write(12'h3EC, 32'd106);  // B[8][9]=106
        axi_write(12'h3F0, 32'd10);  // B[8][10]=10
        axi_write(12'h3F4, 32'd161);  // B[8][11]=-95
        axi_write(12'h3F8, 32'd3);  // B[8][12]=3
        axi_write(12'h3FC, 32'd254);  // B[8][13]=-2
        axi_write(12'h400, 32'd166);  // B[8][14]=-90
        axi_write(12'h404, 32'd170);  // B[8][15]=-86
        axi_write(12'h408, 32'd97);  // B[8][16]=97
        axi_write(12'h40C, 32'd204);  // B[8][17]=-52
        axi_write(12'h410, 32'd61);  // B[8][18]=61
        axi_write(12'h414, 32'd82);  // B[8][19]=82
        axi_write(12'h418, 32'd202);  // B[8][20]=-54
        axi_write(12'h41C, 32'd91);  // B[8][21]=91
        axi_write(12'h420, 32'd45);  // B[8][22]=45
        axi_write(12'h424, 32'd83);  // B[8][23]=83
        axi_write(12'h428, 32'd71);  // B[9][0]=71
        axi_write(12'h42C, 32'd169);  // B[9][1]=-87
        axi_write(12'h430, 32'd107);  // B[9][2]=107
        axi_write(12'h434, 32'd13);  // B[9][3]=13
        axi_write(12'h438, 32'd58);  // B[9][4]=58
        axi_write(12'h43C, 32'd39);  // B[9][5]=39
        axi_write(12'h440, 32'd61);  // B[9][6]=61
        axi_write(12'h444, 32'd138);  // B[9][7]=-118
        axi_write(12'h448, 32'd202);  // B[9][8]=-54
        axi_write(12'h44C, 32'd91);  // B[9][9]=91
        axi_write(12'h450, 32'd220);  // B[9][10]=-36
        axi_write(12'h454, 32'd66);  // B[9][11]=66
        axi_write(12'h458, 32'd54);  // B[9][12]=54
        axi_write(12'h45C, 32'd45);  // B[9][13]=45
        axi_write(12'h460, 32'd118);  // B[9][14]=118
        axi_write(12'h464, 32'd161);  // B[9][15]=-95
        axi_write(12'h468, 32'd252);  // B[9][16]=-4
        axi_write(12'h46C, 32'd172);  // B[9][17]=-84
        axi_write(12'h470, 32'd232);  // B[9][18]=-24
        axi_write(12'h474, 32'd232);  // B[9][19]=-24
        axi_write(12'h478, 32'd201);  // B[9][20]=-55
        axi_write(12'h47C, 32'd232);  // B[9][21]=-24
        axi_write(12'h480, 32'd210);  // B[9][22]=-46
        axi_write(12'h484, 32'd161);  // B[9][23]=-95
        axi_write(12'h488, 32'd176);  // B[10][0]=-80
        axi_write(12'h48C, 32'd80);  // B[10][1]=80
        axi_write(12'h490, 32'd102);  // B[10][2]=102
        axi_write(12'h494, 32'd0);  // B[10][3]=0
        axi_write(12'h498, 32'd241);  // B[10][4]=-15
        axi_write(12'h49C, 32'd85);  // B[10][5]=85
        axi_write(12'h4A0, 32'd221);  // B[10][6]=-35
        axi_write(12'h4A4, 32'd158);  // B[10][7]=-98
        axi_write(12'h4A8, 32'd185);  // B[10][8]=-71
        axi_write(12'h4AC, 32'd10);  // B[10][9]=10
        axi_write(12'h4B0, 32'd146);  // B[10][10]=-110
        axi_write(12'h4B4, 32'd196);  // B[10][11]=-60
        axi_write(12'h4B8, 32'd78);  // B[10][12]=78
        axi_write(12'h4BC, 32'd179);  // B[10][13]=-77
        axi_write(12'h4C0, 32'd247);  // B[10][14]=-9
        axi_write(12'h4C4, 32'd79);  // B[10][15]=79
        axi_write(12'h4C8, 32'd45);  // B[10][16]=45
        axi_write(12'h4CC, 32'd48);  // B[10][17]=48
        axi_write(12'h4D0, 32'd74);  // B[10][18]=74
        axi_write(12'h4D4, 32'd105);  // B[10][19]=105
        axi_write(12'h4D8, 32'd176);  // B[10][20]=-80
        axi_write(12'h4DC, 32'd0);  // B[10][21]=0
        axi_write(12'h4E0, 32'd175);  // B[10][22]=-81
        axi_write(12'h4E4, 32'd117);  // B[10][23]=117
        axi_write(12'h4E8, 32'd196);  // B[11][0]=-60
        axi_write(12'h4EC, 32'd2);  // B[11][1]=2
        axi_write(12'h4F0, 32'd245);  // B[11][2]=-11
        axi_write(12'h4F4, 32'd167);  // B[11][3]=-89
        axi_write(12'h4F8, 32'd8);  // B[11][4]=8
        axi_write(12'h4FC, 32'd193);  // B[11][5]=-63
        axi_write(12'h500, 32'd160);  // B[11][6]=-96
        axi_write(12'h504, 32'd184);  // B[11][7]=-72
        axi_write(12'h508, 32'd136);  // B[11][8]=-120
        axi_write(12'h50C, 32'd60);  // B[11][9]=60
        axi_write(12'h510, 32'd46);  // B[11][10]=46
        axi_write(12'h514, 32'd203);  // B[11][11]=-53
        axi_write(12'h518, 32'd75);  // B[11][12]=75
        axi_write(12'h51C, 32'd70);  // B[11][13]=70
        axi_write(12'h520, 32'd248);  // B[11][14]=-8
        axi_write(12'h524, 32'd180);  // B[11][15]=-76
        axi_write(12'h528, 32'd62);  // B[11][16]=62
        axi_write(12'h52C, 32'd6);  // B[11][17]=6
        axi_write(12'h530, 32'd211);  // B[11][18]=-45
        axi_write(12'h534, 32'd168);  // B[11][19]=-88
        axi_write(12'h538, 32'd58);  // B[11][20]=58
        axi_write(12'h53C, 32'd149);  // B[11][21]=-107
        axi_write(12'h540, 32'd185);  // B[11][22]=-71
        axi_write(12'h544, 32'd38);  // B[11][23]=38
        axi_write(12'h548, 32'd143);  // B[12][0]=-113
        axi_write(12'h54C, 32'd2);  // B[12][1]=2
        axi_write(12'h550, 32'd15);  // B[12][2]=15
        axi_write(12'h554, 32'd144);  // B[12][3]=-112
        axi_write(12'h558, 32'd109);  // B[12][4]=109
        axi_write(12'h55C, 32'd247);  // B[12][5]=-9
        axi_write(12'h560, 32'd42);  // B[12][6]=42
        axi_write(12'h564, 32'd249);  // B[12][7]=-7
        axi_write(12'h568, 32'd101);  // B[12][8]=101
        axi_write(12'h56C, 32'd54);  // B[12][9]=54
        axi_write(12'h570, 32'd111);  // B[12][10]=111
        axi_write(12'h574, 32'd169);  // B[12][11]=-87
        axi_write(12'h578, 32'd175);  // B[12][12]=-81
        axi_write(12'h57C, 32'd104);  // B[12][13]=104
        axi_write(12'h580, 32'd238);  // B[12][14]=-18
        axi_write(12'h584, 32'd128);  // B[12][15]=-128
        axi_write(12'h588, 32'd91);  // B[12][16]=91
        axi_write(12'h58C, 32'd161);  // B[12][17]=-95
        axi_write(12'h590, 32'd168);  // B[12][18]=-88
        axi_write(12'h594, 32'd115);  // B[12][19]=115
        axi_write(12'h598, 32'd228);  // B[12][20]=-28
        axi_write(12'h59C, 32'd169);  // B[12][21]=-87
        axi_write(12'h5A0, 32'd84);  // B[12][22]=84
        axi_write(12'h5A4, 32'd54);  // B[12][23]=54
        axi_write(12'h5A8, 32'd186);  // B[13][0]=-70
        axi_write(12'h5AC, 32'd183);  // B[13][1]=-73
        axi_write(12'h5B0, 32'd32);  // B[13][2]=32
        axi_write(12'h5B4, 32'd94);  // B[13][3]=94
        axi_write(12'h5B8, 32'd17);  // B[13][4]=17
        axi_write(12'h5BC, 32'd195);  // B[13][5]=-61
        axi_write(12'h5C0, 32'd50);  // B[13][6]=50
        axi_write(12'h5C4, 32'd190);  // B[13][7]=-66
        axi_write(12'h5C8, 32'd87);  // B[13][8]=87
        axi_write(12'h5CC, 32'd98);  // B[13][9]=98
        axi_write(12'h5D0, 32'd151);  // B[13][10]=-105
        axi_write(12'h5D4, 32'd28);  // B[13][11]=28
        axi_write(12'h5D8, 32'd193);  // B[13][12]=-63
        axi_write(12'h5DC, 32'd118);  // B[13][13]=118
        axi_write(12'h5E0, 32'd206);  // B[13][14]=-50
        axi_write(12'h5E4, 32'd180);  // B[13][15]=-76
        axi_write(12'h5E8, 32'd234);  // B[13][16]=-22
        axi_write(12'h5EC, 32'd16);  // B[13][17]=16
        axi_write(12'h5F0, 32'd67);  // B[13][18]=67
        axi_write(12'h5F4, 32'd243);  // B[13][19]=-13
        axi_write(12'h5F8, 32'd121);  // B[13][20]=121
        axi_write(12'h5FC, 32'd141);  // B[13][21]=-115
        axi_write(12'h600, 32'd84);  // B[13][22]=84
        axi_write(12'h604, 32'd137);  // B[13][23]=-119
        axi_write(12'h608, 32'd219);  // B[14][0]=-37
        axi_write(12'h60C, 32'd233);  // B[14][1]=-23
        axi_write(12'h610, 32'd238);  // B[14][2]=-18
        axi_write(12'h614, 32'd243);  // B[14][3]=-13
        axi_write(12'h618, 32'd136);  // B[14][4]=-120
        axi_write(12'h61C, 32'd132);  // B[14][5]=-124
        axi_write(12'h620, 32'd77);  // B[14][6]=77
        axi_write(12'h624, 32'd201);  // B[14][7]=-55
        axi_write(12'h628, 32'd157);  // B[14][8]=-99
        axi_write(12'h62C, 32'd248);  // B[14][9]=-8
        axi_write(12'h630, 32'd86);  // B[14][10]=86
        axi_write(12'h634, 32'd244);  // B[14][11]=-12
        axi_write(12'h638, 32'd71);  // B[14][12]=71
        axi_write(12'h63C, 32'd176);  // B[14][13]=-80
        axi_write(12'h640, 32'd226);  // B[14][14]=-30
        axi_write(12'h644, 32'd149);  // B[14][15]=-107
        axi_write(12'h648, 32'd145);  // B[14][16]=-111
        axi_write(12'h64C, 32'd104);  // B[14][17]=104
        axi_write(12'h650, 32'd100);  // B[14][18]=100
        axi_write(12'h654, 32'd95);  // B[14][19]=95
        axi_write(12'h658, 32'd93);  // B[14][20]=93
        axi_write(12'h65C, 32'd78);  // B[14][21]=78
        axi_write(12'h660, 32'd200);  // B[14][22]=-56
        axi_write(12'h664, 32'd48);  // B[14][23]=48
        axi_write(12'h668, 32'd39);  // B[15][0]=39
        axi_write(12'h66C, 32'd210);  // B[15][1]=-46
        axi_write(12'h670, 32'd188);  // B[15][2]=-68
        axi_write(12'h674, 32'd252);  // B[15][3]=-4
        axi_write(12'h678, 32'd133);  // B[15][4]=-123
        axi_write(12'h67C, 32'd55);  // B[15][5]=55
        axi_write(12'h680, 32'd45);  // B[15][6]=45
        axi_write(12'h684, 32'd48);  // B[15][7]=48
        axi_write(12'h688, 32'd81);  // B[15][8]=81
        axi_write(12'h68C, 32'd129);  // B[15][9]=-127
        axi_write(12'h690, 32'd34);  // B[15][10]=34
        axi_write(12'h694, 32'd25);  // B[15][11]=25
        axi_write(12'h698, 32'd80);  // B[15][12]=80
        axi_write(12'h69C, 32'd69);  // B[15][13]=69
        axi_write(12'h6A0, 32'd162);  // B[15][14]=-94
        axi_write(12'h6A4, 32'd196);  // B[15][15]=-60
        axi_write(12'h6A8, 32'd187);  // B[15][16]=-69
        axi_write(12'h6AC, 32'd173);  // B[15][17]=-83
        axi_write(12'h6B0, 32'd84);  // B[15][18]=84
        axi_write(12'h6B4, 32'd150);  // B[15][19]=-106
        axi_write(12'h6B8, 32'd174);  // B[15][20]=-82
        axi_write(12'h6BC, 32'd172);  // B[15][21]=-84
        axi_write(12'h6C0, 32'd178);  // B[15][22]=-78
        axi_write(12'h6C4, 32'd198);  // B[15][23]=-58
        axi_write(12'h6C8, 32'd93);  // B[16][0]=93
        axi_write(12'h6CC, 32'd140);  // B[16][1]=-116
        axi_write(12'h6D0, 32'd77);  // B[16][2]=77
        axi_write(12'h6D4, 32'd226);  // B[16][3]=-30
        axi_write(12'h6D8, 32'd253);  // B[16][4]=-3
        axi_write(12'h6DC, 32'd97);  // B[16][5]=97
        axi_write(12'h6E0, 32'd128);  // B[16][6]=-128
        axi_write(12'h6E4, 32'd176);  // B[16][7]=-80
        axi_write(12'h6E8, 32'd95);  // B[16][8]=95
        axi_write(12'h6EC, 32'd124);  // B[16][9]=124
        axi_write(12'h6F0, 32'd74);  // B[16][10]=74
        axi_write(12'h6F4, 32'd192);  // B[16][11]=-64
        axi_write(12'h6F8, 32'd95);  // B[16][12]=95
        axi_write(12'h6FC, 32'd242);  // B[16][13]=-14
        axi_write(12'h700, 32'd72);  // B[16][14]=72
        axi_write(12'h704, 32'd58);  // B[16][15]=58
        axi_write(12'h708, 32'd115);  // B[16][16]=115
        axi_write(12'h70C, 32'd68);  // B[16][17]=68
        axi_write(12'h710, 32'd70);  // B[16][18]=70
        axi_write(12'h714, 32'd236);  // B[16][19]=-20
        axi_write(12'h718, 32'd41);  // B[16][20]=41
        axi_write(12'h71C, 32'd178);  // B[16][21]=-78
        axi_write(12'h720, 32'd41);  // B[16][22]=41
        axi_write(12'h724, 32'd86);  // B[16][23]=86
        axi_write(12'h728, 32'd30);  // B[17][0]=30
        axi_write(12'h72C, 32'd55);  // B[17][1]=55
        axi_write(12'h730, 32'd247);  // B[17][2]=-9
        axi_write(12'h734, 32'd94);  // B[17][3]=94
        axi_write(12'h738, 32'd54);  // B[17][4]=54
        axi_write(12'h73C, 32'd4);  // B[17][5]=4
        axi_write(12'h740, 32'd51);  // B[17][6]=51
        axi_write(12'h744, 32'd220);  // B[17][7]=-36
        axi_write(12'h748, 32'd240);  // B[17][8]=-16
        axi_write(12'h74C, 32'd112);  // B[17][9]=112
        axi_write(12'h750, 32'd197);  // B[17][10]=-59
        axi_write(12'h754, 32'd22);  // B[17][11]=22
        axi_write(12'h758, 32'd90);  // B[17][12]=90
        axi_write(12'h75C, 32'd92);  // B[17][13]=92
        axi_write(12'h760, 32'd70);  // B[17][14]=70
        axi_write(12'h764, 32'd148);  // B[17][15]=-108
        axi_write(12'h768, 32'd96);  // B[17][16]=96
        axi_write(12'h76C, 32'd189);  // B[17][17]=-67
        axi_write(12'h770, 32'd13);  // B[17][18]=13
        axi_write(12'h774, 32'd150);  // B[17][19]=-106
        axi_write(12'h778, 32'd0);  // B[17][20]=0
        axi_write(12'h77C, 32'd250);  // B[17][21]=-6
        axi_write(12'h780, 32'd244);  // B[17][22]=-12
        axi_write(12'h784, 32'd200);  // B[17][23]=-56
        axi_write(12'h788, 32'd232);  // B[18][0]=-24
        axi_write(12'h78C, 32'd238);  // B[18][1]=-18
        axi_write(12'h790, 32'd0);  // B[18][2]=0
        axi_write(12'h794, 32'd99);  // B[18][3]=99
        axi_write(12'h798, 32'd132);  // B[18][4]=-124
        axi_write(12'h79C, 32'd24);  // B[18][5]=24
        axi_write(12'h7A0, 32'd16);  // B[18][6]=16
        axi_write(12'h7A4, 32'd90);  // B[18][7]=90
        axi_write(12'h7A8, 32'd132);  // B[18][8]=-124
        axi_write(12'h7AC, 32'd9);  // B[18][9]=9
        axi_write(12'h7B0, 32'd136);  // B[18][10]=-120
        axi_write(12'h7B4, 32'd238);  // B[18][11]=-18
        axi_write(12'h7B8, 32'd59);  // B[18][12]=59
        axi_write(12'h7BC, 32'd72);  // B[18][13]=72
        axi_write(12'h7C0, 32'd162);  // B[18][14]=-94
        axi_write(12'h7C4, 32'd13);  // B[18][15]=13
        axi_write(12'h7C8, 32'd89);  // B[18][16]=89
        axi_write(12'h7CC, 32'd86);  // B[18][17]=86
        axi_write(12'h7D0, 32'd189);  // B[18][18]=-67
        axi_write(12'h7D4, 32'd71);  // B[18][19]=71
        axi_write(12'h7D8, 32'd86);  // B[18][20]=86
        axi_write(12'h7DC, 32'd208);  // B[18][21]=-48
        axi_write(12'h7E0, 32'd156);  // B[18][22]=-100
        axi_write(12'h7E4, 32'd101);  // B[18][23]=101
        axi_write(12'h7E8, 32'd2);  // B[19][0]=2
        axi_write(12'h7EC, 32'd9);  // B[19][1]=9
        axi_write(12'h7F0, 32'd239);  // B[19][2]=-17
        axi_write(12'h7F4, 32'd92);  // B[19][3]=92
        axi_write(12'h7F8, 32'd243);  // B[19][4]=-13
        axi_write(12'h7FC, 32'd155);  // B[19][5]=-101
        axi_write(12'h800, 32'd42);  // B[19][6]=42
        axi_write(12'h804, 32'd214);  // B[19][7]=-42
        axi_write(12'h808, 32'd37);  // B[19][8]=37
        axi_write(12'h80C, 32'd7);  // B[19][9]=7
        axi_write(12'h810, 32'd38);  // B[19][10]=38
        axi_write(12'h814, 32'd77);  // B[19][11]=77
        axi_write(12'h818, 32'd65);  // B[19][12]=65
        axi_write(12'h81C, 32'd24);  // B[19][13]=24
        axi_write(12'h820, 32'd247);  // B[19][14]=-9
        axi_write(12'h824, 32'd123);  // B[19][15]=123
        axi_write(12'h828, 32'd4);  // B[19][16]=4
        axi_write(12'h82C, 32'd101);  // B[19][17]=101
        axi_write(12'h830, 32'd89);  // B[19][18]=89
        axi_write(12'h834, 32'd190);  // B[19][19]=-66
        axi_write(12'h838, 32'd207);  // B[19][20]=-49
        axi_write(12'h83C, 32'd50);  // B[19][21]=50
        axi_write(12'h840, 32'd15);  // B[19][22]=15
        axi_write(12'h844, 32'd114);  // B[19][23]=114
        axi_write(12'h848, 32'd198);  // B[20][0]=-58
        axi_write(12'h84C, 32'd197);  // B[20][1]=-59
        axi_write(12'h850, 32'd147);  // B[20][2]=-109
        axi_write(12'h854, 32'd145);  // B[20][3]=-111
        axi_write(12'h858, 32'd118);  // B[20][4]=118
        axi_write(12'h85C, 32'd85);  // B[20][5]=85
        axi_write(12'h860, 32'd66);  // B[20][6]=66
        axi_write(12'h864, 32'd70);  // B[20][7]=70
        axi_write(12'h868, 32'd133);  // B[20][8]=-123
        axi_write(12'h86C, 32'd152);  // B[20][9]=-104
        axi_write(12'h870, 32'd18);  // B[20][10]=18
        axi_write(12'h874, 32'd217);  // B[20][11]=-39
        axi_write(12'h878, 32'd101);  // B[20][12]=101
        axi_write(12'h87C, 32'd251);  // B[20][13]=-5
        axi_write(12'h880, 32'd33);  // B[20][14]=33
        axi_write(12'h884, 32'd230);  // B[20][15]=-26
        axi_write(12'h888, 32'd205);  // B[20][16]=-51
        axi_write(12'h88C, 32'd59);  // B[20][17]=59
        axi_write(12'h890, 32'd15);  // B[20][18]=15
        axi_write(12'h894, 32'd172);  // B[20][19]=-84
        axi_write(12'h898, 32'd224);  // B[20][20]=-32
        axi_write(12'h89C, 32'd54);  // B[20][21]=54
        axi_write(12'h8A0, 32'd12);  // B[20][22]=12
        axi_write(12'h8A4, 32'd250);  // B[20][23]=-6
        axi_write(12'h8A8, 32'd219);  // B[21][0]=-37
        axi_write(12'h8AC, 32'd174);  // B[21][1]=-82
        axi_write(12'h8B0, 32'd150);  // B[21][2]=-106
        axi_write(12'h8B4, 32'd210);  // B[21][3]=-46
        axi_write(12'h8B8, 32'd178);  // B[21][4]=-78
        axi_write(12'h8BC, 32'd167);  // B[21][5]=-89
        axi_write(12'h8C0, 32'd14);  // B[21][6]=14
        axi_write(12'h8C4, 32'd41);  // B[21][7]=41
        axi_write(12'h8C8, 32'd227);  // B[21][8]=-29
        axi_write(12'h8CC, 32'd254);  // B[21][9]=-2
        axi_write(12'h8D0, 32'd74);  // B[21][10]=74
        axi_write(12'h8D4, 32'd241);  // B[21][11]=-15
        axi_write(12'h8D8, 32'd43);  // B[21][12]=43
        axi_write(12'h8DC, 32'd78);  // B[21][13]=78
        axi_write(12'h8E0, 32'd204);  // B[21][14]=-52
        axi_write(12'h8E4, 32'd237);  // B[21][15]=-19
        axi_write(12'h8E8, 32'd26);  // B[21][16]=26
        axi_write(12'h8EC, 32'd210);  // B[21][17]=-46
        axi_write(12'h8F0, 32'd25);  // B[21][18]=25
        axi_write(12'h8F4, 32'd246);  // B[21][19]=-10
        axi_write(12'h8F8, 32'd44);  // B[21][20]=44
        axi_write(12'h8FC, 32'd98);  // B[21][21]=98
        axi_write(12'h900, 32'd134);  // B[21][22]=-122
        axi_write(12'h904, 32'd171);  // B[21][23]=-85
        axi_write(12'h908, 32'd52);  // B[22][0]=52
        axi_write(12'h90C, 32'd116);  // B[22][1]=116
        axi_write(12'h910, 32'd215);  // B[22][2]=-41
        axi_write(12'h914, 32'd119);  // B[22][3]=119
        axi_write(12'h918, 32'd52);  // B[22][4]=52
        axi_write(12'h91C, 32'd75);  // B[22][5]=75
        axi_write(12'h920, 32'd238);  // B[22][6]=-18
        axi_write(12'h924, 32'd205);  // B[22][7]=-51
        axi_write(12'h928, 32'd61);  // B[22][8]=61
        axi_write(12'h92C, 32'd19);  // B[22][9]=19
        axi_write(12'h930, 32'd122);  // B[22][10]=122
        axi_write(12'h934, 32'd230);  // B[22][11]=-26
        axi_write(12'h938, 32'd132);  // B[22][12]=-124
        axi_write(12'h93C, 32'd110);  // B[22][13]=110
        axi_write(12'h940, 32'd181);  // B[22][14]=-75
        axi_write(12'h944, 32'd149);  // B[22][15]=-107
        axi_write(12'h948, 32'd94);  // B[22][16]=94
        axi_write(12'h94C, 32'd74);  // B[22][17]=74
        axi_write(12'h950, 32'd197);  // B[22][18]=-59
        axi_write(12'h954, 32'd203);  // B[22][19]=-53
        axi_write(12'h958, 32'd212);  // B[22][20]=-44
        axi_write(12'h95C, 32'd20);  // B[22][21]=20
        axi_write(12'h960, 32'd231);  // B[22][22]=-25
        axi_write(12'h964, 32'd0);  // B[22][23]=0
        axi_write(12'h968, 32'd212);  // B[23][0]=-44
        axi_write(12'h96C, 32'd158);  // B[23][1]=-98
        axi_write(12'h970, 32'd125);  // B[23][2]=125
        axi_write(12'h974, 32'd48);  // B[23][3]=48
        axi_write(12'h978, 32'd30);  // B[23][4]=30
        axi_write(12'h97C, 32'd247);  // B[23][5]=-9
        axi_write(12'h980, 32'd89);  // B[23][6]=89
        axi_write(12'h984, 32'd220);  // B[23][7]=-36
        axi_write(12'h988, 32'd34);  // B[23][8]=34
        axi_write(12'h98C, 32'd96);  // B[23][9]=96
        axi_write(12'h990, 32'd135);  // B[23][10]=-121
        axi_write(12'h994, 32'd200);  // B[23][11]=-56
        axi_write(12'h998, 32'd244);  // B[23][12]=-12
        axi_write(12'h99C, 32'd98);  // B[23][13]=98
        axi_write(12'h9A0, 32'd186);  // B[23][14]=-70
        axi_write(12'h9A4, 32'd57);  // B[23][15]=57
        axi_write(12'h9A8, 32'd192);  // B[23][16]=-64
        axi_write(12'h9AC, 32'd216);  // B[23][17]=-40
        axi_write(12'h9B0, 32'd81);  // B[23][18]=81
        axi_write(12'h9B4, 32'd47);  // B[23][19]=47
        axi_write(12'h9B8, 32'd108);  // B[23][20]=108
        axi_write(12'h9BC, 32'd107);  // B[23][21]=107
        axi_write(12'h9C0, 32'd141);  // B[23][22]=-115
        axi_write(12'h9C4, 32'd58);  // B[23][23]=58
        $display("[2] 加载数据向量 A...");
        axi_write(12'h068, 32'd7);  // A[0]=7
        axi_write(12'h06C, 32'd165);  // A[1]=-91
        axi_write(12'h070, 32'd88);  // A[2]=88
        axi_write(12'h074, 32'd149);  // A[3]=-107
        axi_write(12'h078, 32'd76);  // A[4]=76
        axi_write(12'h07C, 32'd122);  // A[5]=122
        axi_write(12'h080, 32'd160);  // A[6]=-96
        axi_write(12'h084, 32'd69);  // A[7]=69
        axi_write(12'h088, 32'd64);  // A[8]=64
        axi_write(12'h08C, 32'd126);  // A[9]=126
        axi_write(12'h090, 32'd16);  // A[10]=16
        axi_write(12'h094, 32'd38);  // A[11]=38
        axi_write(12'h098, 32'd224);  // A[12]=-32
        axi_write(12'h09C, 32'd213);  // A[13]=-43
        axi_write(12'h0A0, 32'd217);  // A[14]=-39
        axi_write(12'h0A4, 32'd239);  // A[15]=-17
        axi_write(12'h0A8, 32'd163);  // A[16]=-93
        axi_write(12'h0AC, 32'd149);  // A[17]=-107
        axi_write(12'h0B0, 32'd89);  // A[18]=89
        axi_write(12'h0B4, 32'd237);  // A[19]=-19
        axi_write(12'h0B8, 32'd65);  // A[20]=65
        axi_write(12'h0BC, 32'd145);  // A[21]=-111
        axi_write(12'h0C0, 32'd76);  // A[22]=76
        axi_write(12'h0C4, 32'd90);  // A[23]=90

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
        axi_read(12'h048, results[16]);
        axi_read(12'h04C, results[17]);
        axi_read(12'h050, results[18]);
        axi_read(12'h054, results[19]);
        axi_read(12'h058, results[20]);
        axi_read(12'h05C, results[21]);
        axi_read(12'h060, results[22]);
        axi_read(12'h064, results[23]);

        for (i = 0; i < N; i = i + 1) begin
            $display("    C[0][%0d] = %0d", i, $signed(results[i]));
            $fdisplay(result_file, "%0d", $signed(results[i]));
        end
        $fclose(result_file);

        if ($signed(results[0])==2566 && $signed(results[1])==36255 && $signed(results[2])==23427 && $signed(results[3])==4840 && $signed(results[4])==36411 && $signed(results[5])==-6258 && $signed(results[6])==7748 && $signed(results[7])==-32727 && $signed(results[8])==-27082 && $signed(results[9])==13872 && $signed(results[10])==-30293 && $signed(results[11])==-7189 && $signed(results[12])==-4038 && $signed(results[13])==39076 && $signed(results[14])==-43472 && $signed(results[15])==37009 && $signed(results[16])==4513 && $signed(results[17])==2772 && $signed(results[18])==-32319 && $signed(results[19])==9327 && $signed(results[20])==-33190 && $signed(results[21])==-21487 && $signed(results[22])==-9311 && $signed(results[23])==-6247) begin
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
echo "    python3 ../python/golden_model.py --mode sim --array_size 24 --test_id 0"
echo "======================================================"
