# =============================================================
# 文件名  : package_ip.tcl
# 描述    : 将 axi_ctrl_top 及其依赖 RTL 自动封装为 AXI4-Lite IP
# 平台    : ALINX ACU4EV（XCZU4EV） / Vivado 2020.1
# 运行    : vivado -mode batch -source scripts/package_ip.tcl
# =============================================================

set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize "${script_dir}/.."]
cd ${project_dir}

set part_id "xczu4ev-sfvc784-1-i"
set ip_name "axi_ctrl_top"
set ip_ver  "1.0"
set ip_repo "${project_dir}/ip_repo"
set pkg_tmp "${project_dir}/ip_pkg_tmp"
set ip_dest "${ip_repo}/${ip_name}_${ip_ver}"

puts "======================================================"
puts " Packaging ${ip_name}:${ip_ver}"
puts " Project : ${project_dir}"
puts " Dest    : ${ip_dest}"
puts "======================================================"

file delete -force ${pkg_tmp}
file delete -force ${ip_dest}
file mkdir ${ip_repo}
file mkdir ${pkg_tmp}

create_project ip_pkg ${pkg_tmp} -part ${part_id} -force

add_files -norecurse [list \
    ${project_dir}/rtl/pe_unit.v \
    ${project_dir}/rtl/systolic_array.v \
    ${project_dir}/rtl/ctrl_fsm.v \
    ${project_dir}/rtl/axi_ctrl_top.v \
]
set_property file_type SystemVerilog [get_files *.v]
set_property top axi_ctrl_top [current_fileset]
update_compile_order -fileset sources_1

ipx::package_project -root_dir ${ip_dest} -vendor user.org -library user \
    -taxonomy /UserIP -import_files -set_current true -force

set_property name ${ip_name} [ipx::current_core]
set_property version ${ip_ver} [ipx::current_core]
set_property display_name "INT8 Systolic GEMM AXI Ctrl" [ipx::current_core]
set_property description "Weight-Stationary INT8 systolic array with AXI4-Lite control" [ipx::current_core]
set_property vendor_display_name "User" [ipx::current_core]
set_property company_url "http://user.org" [ipx::current_core]
set_property supported_families {zynquplus Production} [ipx::current_core]

# 查找自动推断出的 AXI 从接口（通常名为 s_axi 或 S_AXI）
set axi_if ""
foreach bif [ipx::get_bus_interfaces -of_objects [ipx::current_core]] {
    set btype [get_property bus_type_name $bif]
    set mode  [get_property interface_mode $bif]
    if {$btype eq "aximm" && $mode eq "slave"} {
        set axi_if [get_property name $bif]
        break
    }
}
if {$axi_if eq ""} {
    error "No AXI slave interface inferred from RTL ports — check s_axi_* naming"
}
puts "INFO: inferred AXI slave bus interface = ${axi_if}"

# 关联时钟
ipx::associate_bus_interfaces -busif ${axi_if} -clock s_axi_aclk [ipx::current_core]

# 地址块（C_S_AXI_ADDR_WIDTH=12 → 4KB）
set mmap_list [ipx::get_memory_maps -of_objects [ipx::current_core]]
if {[llength $mmap_list] == 0} {
    ipx::add_memory_map ${axi_if} [ipx::current_core]
    set_property slave_memory_map_ref ${axi_if} \
        [ipx::get_bus_interfaces ${axi_if} -of_objects [ipx::current_core]]
}
set mmap [lindex [ipx::get_memory_maps -of_objects [ipx::current_core]] 0]
set ablocks [ipx::get_address_blocks -of_objects $mmap]
if {[llength $ablocks] == 0} {
    ipx::add_address_block Reg $mmap
    set ablocks [ipx::get_address_blocks -of_objects $mmap]
}
set ablock [lindex $ablocks 0]
set_property range {4096} $ablock
set_property width {32} $ablock

set_property core_revision 1 [ipx::current_core]
ipx::create_xgui_files [ipx::current_core]
ipx::update_checksums [ipx::current_core]
ipx::save_core [ipx::current_core]

close_project -delete
file delete -force ${pkg_tmp}

puts "======================================================"
puts " IP packaged OK: ${ip_dest}"
puts " VLNV: user.org:user:${ip_name}:${ip_ver}"
puts "======================================================"
