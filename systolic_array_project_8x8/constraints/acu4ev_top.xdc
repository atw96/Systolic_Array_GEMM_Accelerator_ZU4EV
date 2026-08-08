# =============================================================
# 文件名  : acu4ev_top.xdc
# 描述    : ALINX ACU4EV 时序约束（仅供纯 RTL 仿真/综合工程）
# 器件    : XCZU4EV-1SFVC784I
# 工具    : Vivado 2020.1
# =============================================================
# 说明：
#   板上 edgeai_acu4ev FSBL 使能的是 pl_clk0 = 200 MHz（5 ns）。
#   Block Design 工程由 PS IP 自动生成时钟约束，请勿把本文件加入 BD 工程。
# =============================================================

# ── 虚拟时钟约束（纯 RTL 工程用，BD 工程由 PS IP 自动生成）───
create_clock -period 5.000 -name pl_clk0 -waveform {0.000 2.500} \
    [get_ports s_axi_aclk]

# ── 输入延迟约束（AXI 信号，相对于 pl_clk0）─────────────────
set_input_delay -clock [get_clocks pl_clk0] -max 1.000 \
    [get_ports {s_axi_awaddr* s_axi_awvalid s_axi_wdata* s_axi_wvalid \
                s_axi_bready s_axi_araddr* s_axi_arvalid s_axi_rready}]
set_input_delay -clock [get_clocks pl_clk0] -min 0.200 \
    [get_ports {s_axi_awaddr* s_axi_awvalid s_axi_wdata* s_axi_wvalid \
                s_axi_bready s_axi_araddr* s_axi_arvalid s_axi_rready}]

# ── 输出延迟约束 ──────────────────────────────────────────────
set_output_delay -clock [get_clocks pl_clk0] -max 1.000 \
    [get_ports {s_axi_awready s_axi_wready s_axi_bresp* s_axi_bvalid \
                s_axi_arready s_axi_rdata* s_axi_rresp* s_axi_rvalid}]
set_output_delay -clock [get_clocks pl_clk0] -min 0.200 \
    [get_ports {s_axi_awready s_axi_wready s_axi_bresp* s_axi_bvalid \
                s_axi_arready s_axi_rdata* s_axi_rresp* s_axi_rvalid}]

# ── DSP 使用率报告提示（N=8）──────────────────────────────────
#   预期 DSP48E2 = 64（64 个 PE），占 XCZU4EV 728 个的 8.8%
