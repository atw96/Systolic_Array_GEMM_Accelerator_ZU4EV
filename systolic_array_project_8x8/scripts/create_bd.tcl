# =============================================================
# 文件名  : create_bd.tcl
# 描述    : Vivado 2020.1 Block Design（ACU4EV 实测修正版）
# 平台    : ALINX ACU4EV（XCZU4EV-1SFVC784I）
# 运行    : vivado -mode batch -source scripts/create_bd.tcl
#
# ── 相对 README 初版的关键修正 ────────────────────────────────
#   1. PL 时钟改用 pl_clk0 = 200 MHz（板上 edgeai_acu4ev FSBL 的
#      psu_init 只使能了 PL0_REF_CTRL，没有 PL1 —— 用 pl_clk1 会
#      导致加速器无时钟，/dev/mem 读 0x8005_0000 挂死）。
#   2. 补接 maxihpm0_lpd_aclk（原脚本漏接，主口无时钟）。
#   3. 地址 range 改为 4K（C_S_AXI_ADDR_WIDTH=12）。
#   4. 删除 UART/DDR 等 PS 配置：我们不重建 BOOT.BIN，FSBL 已固化
#      在 SD 卡里，BD 里配了也不生效。
# =============================================================

set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize "${script_dir}/.."]
cd ${project_dir}

set proj_name "systolic_array_top"
set proj_dir  "${project_dir}/vivado_project"
set part_id   "xczu4ev-sfvc784-1-i"
set bd_name   "system"
set ip_repo   "${project_dir}/ip_repo"

# ── 创建 Vivado 工程 ──────────────────────────────────────────
create_project ${proj_name} ${proj_dir} -part ${part_id} -force

set_property ip_repo_paths ${ip_repo} [current_project]
update_ip_catalog

# ── 创建 Block Design ─────────────────────────────────────────
create_bd_design ${bd_name}
open_bd_design [get_files ${bd_name}.bd]

# ── 1. Zynq UltraScale+ MPSoC PS ──────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.3 zynq_ultra_ps_e_0

# 仅配置本加速器需要的控制面主口与 PL0 时钟频率声明
# （实际频率由 SD 卡 FSBL/psu_init 决定；此处声明 200MHz 让 Vivado
#  按 5ns 做时序约束，与板上实测 pl_clk0 一致）
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {0} \
    CONFIG.PSU__USE__M_AXI_GP1 {0} \
    CONFIG.PSU__USE__M_AXI_GP2 {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {200} \
] [get_bd_cells zynq_ultra_ps_e_0]

# ── 2. Processor System Reset ────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

# ── 3. AXI Interconnect（1 Master → 1 Slave）─────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
set_property -dict [list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
] [get_bd_cells axi_interconnect_0]

# ── 4. 自定义 IP：axi_ctrl_top ────────────────────────────────
create_bd_cell -type ip -vlnv user.org:user:axi_ctrl_top:1.0 axi_ctrl_top_0

# 查找 IP 暴露的 AXI 从接口名（可能是 S_AXI / s_axi）
set axi_slave_if ""
foreach intf [get_bd_intf_pins axi_ctrl_top_0/*] {
    set vlnv [get_property VLNV $intf]
    if {[string match "*aximm*" $vlnv]} {
        set axi_slave_if $intf
        break
    }
}
if {$axi_slave_if eq ""} {
    error "axi_ctrl_top_0 has no AXI-MM slave interface"
}
puts "INFO: axi_ctrl_top AXI slave = ${axi_slave_if}"

# ── 5. 时钟 / 复位（全部走 pl_clk0 / pl_resetn0）──────────────
# PS 主口时钟输入（原脚本漏接 → 主口不工作）
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_lpd_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins axi_interconnect_0/ACLK]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins axi_interconnect_0/S00_ACLK]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
               [get_bd_pins axi_ctrl_top_0/s_axi_aclk]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] \
               [get_bd_pins proc_sys_reset_0/ext_reset_in]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] \
               [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins axi_interconnect_0/S00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins axi_interconnect_0/M00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
               [get_bd_pins axi_ctrl_top_0/s_axi_aresetn]

# ── 6. AXI 总线 ───────────────────────────────────────────────
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_LPD] \
                    [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
                    ${axi_slave_if}

# ── 7. 地址：0x8005_0000 / 4KB ────────────────────────────────
# assign_bd_address 会根据 memory map 创建段；段名可能含 Reg
assign_bd_address -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] \
    [get_bd_addr_segs axi_ctrl_top_0/*/Reg*]
set seg [get_bd_addr_segs -quiet zynq_ultra_ps_e_0/Data/SEG_axi_ctrl_top_0_*]
if {$seg eq ""} {
    set seg [lindex [get_bd_addr_segs zynq_ultra_ps_e_0/Data/*axi_ctrl*] 0]
}
set_property offset 0x80050000 $seg
set_property range 4K $seg

# ── 8. 验证 / 保存 / wrapper ──────────────────────────────────
validate_bd_design
save_bd_design

make_wrapper -files [get_files ${bd_name}.bd] -top
set wrapper_candidates [list \
    "${proj_dir}/${proj_name}.srcs/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v" \
    "${proj_dir}/${proj_name}.gen/sources_1/bd/${bd_name}/hdl/${bd_name}_wrapper.v" \
]
set wrapper_file ""
foreach cand $wrapper_candidates {
    if {[file exists $cand]} {
        set wrapper_file $cand
        break
    }
}
if {$wrapper_file eq ""} {
    set wrapper_file [lindex [get_files -quiet *_wrapper.v] 0]
}
if {$wrapper_file eq ""} {
    error "Could not find ${bd_name}_wrapper.v after make_wrapper"
}
puts "INFO: wrapper = ${wrapper_file}"
add_files -norecurse ${wrapper_file}
set_property top ${bd_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1

# BD 工程由 PS IP 自动生成时钟约束；不要加入纯 RTL 用的 acu4ev_top.xdc
set xdc_files [get_files -quiet acu4ev_top.xdc]
if {[llength $xdc_files] > 0} {
    set_property used_in_synthesis false $xdc_files
    set_property used_in_implementation false $xdc_files
}

puts "=============================================="
puts " Block Design 创建完成（ACU4EV 实测修正版）"
puts "   PS Master : M_AXI_HPM0_LPD（GP2）"
puts "   PL 时钟   : pl_clk0 = 200 MHz（与板上 FSBL 一致）"
puts "   主口时钟  : maxihpm0_lpd_aclk ← pl_clk0"
puts "   基地址    : 0x8005_0000（4KB）"
puts "=============================================="
