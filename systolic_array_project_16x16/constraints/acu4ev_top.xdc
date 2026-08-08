# =============================================================
# 文件名  : acu4ev_top.xdc
# 描述    : ALINX ACU4EV 时序约束
# 器件    : XCZU4EV-1SFVC784I
# 工具    : Vivado 2020.1
# =============================================================
# 说明：
#   本设计中 PL 使用 PS 提供的 pl_clk0（100 MHz），
#   该时钟由 PS IP 内部生成，不需要外部引脚时钟约束。
#   Vivado Block Design 中 PS IP 会自动创建时钟约束，
#   以下约束仅供纯 RTL 仿真/综合验证工程使用。
# =============================================================

# ── 虚拟时钟约束（纯 RTL 工程用，BD 工程由 PS IP 自动生成）───
# 注：如果是 Block Design 工程，请删除此行，PS IP 自动处理
create_clock -period 10.000 -name pl_clk0 -waveform {0.000 5.000} \
    [get_ports s_axi_aclk]

# ── 输入延迟约束（AXI 信号，相对于 pl_clk0）─────────────────
# AXI4-Lite 信号来自 PS，约束 2ns 输入延迟（典型值）
set_input_delay -clock [get_clocks pl_clk0] -max 2.000 \
    [get_ports {s_axi_awaddr* s_axi_awvalid s_axi_wdata* s_axi_wvalid \
                s_axi_bready s_axi_araddr* s_axi_arvalid s_axi_rready}]
set_input_delay -clock [get_clocks pl_clk0] -min 0.500 \
    [get_ports {s_axi_awaddr* s_axi_awvalid s_axi_wdata* s_axi_wvalid \
                s_axi_bready s_axi_araddr* s_axi_arvalid s_axi_rready}]

# ── 输出延迟约束 ──────────────────────────────────────────────
set_output_delay -clock [get_clocks pl_clk0] -max 2.000 \
    [get_ports {s_axi_awready s_axi_wready s_axi_bresp* s_axi_bvalid \
                s_axi_arready s_axi_rdata* s_axi_rresp* s_axi_rvalid}]
set_output_delay -clock [get_clocks pl_clk0] -min 0.500 \
    [get_ports {s_axi_awready s_axi_wready s_axi_bresp* s_axi_bvalid \
                s_axi_arready s_axi_rdata* s_axi_rresp* s_axi_rvalid}]

# ── 虚假路径（跨时钟域，本设计单时钟域无需设置）─────────────
# set_false_path -from [get_clocks clkA] -to [get_clocks clkB]

# ── DSP 使用率报告提示 ────────────────────────────────────────
# 综合后查看报告：
#   预期 DSP48E2 = 16（16 个 PE），占 XCZU4EV 728 个的 2.2%
#   预期 LUT     < 2000（控制逻辑 + AXI 接口）
#   预期 FF      < 3000
