# =============================================================
# 文件名  : build_bitstream.tcl
# 描述    : 一键：封装 IP → 创建 BD → 综合实现 → 导出 bit/xsa
# 运行    : vivado -mode batch -source scripts/build_bitstream.tcl
# =============================================================

set script_dir  [file dirname [file normalize [info script]]]
set project_dir [file normalize "${script_dir}/.."]
cd ${project_dir}

set jobs 8
set deploy_dir "${project_dir}/deploy"
file mkdir ${deploy_dir}

puts "########## [1/4] Package IP ##########"
source ${script_dir}/package_ip.tcl

puts "########## [2/4] Create Block Design ##########"
source ${script_dir}/create_bd.tcl

puts "########## [3/4] Synthesis + Implementation ##########"
set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
# 小设计用默认实现策略即可；若 WNS 不够再换 Performance_*
set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]

launch_runs synth_1 -jobs ${jobs}
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed — see vivado.log"
}

open_run synth_1
report_utilization -file ${deploy_dir}/utilization_synth.rpt
report_timing_summary -file ${deploy_dir}/timing_synth.rpt

launch_runs impl_1 -to_step write_bitstream -jobs ${jobs}
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed — see vivado.log"
}

open_run impl_1
report_utilization -file ${deploy_dir}/utilization_impl.rpt
report_timing_summary -file ${deploy_dir}/timing_impl.rpt

set wns [get_property STATS.WNS [get_runs impl_1]]
puts "INFO: Implementation WNS = ${wns} ns (must be >= 0 @ 200 MHz / 5 ns)"
if {$wns < 0} {
    puts "WARNING: Negative WNS — timing not met at 200 MHz."
    puts "         Fallback: insert Clocking Wizard 200→100 in BD."
}

puts "########## [4/4] Export bit / xsa ##########"
set bit_src [lindex [glob -nocomplain \
    ${project_dir}/vivado_project/*.runs/impl_1/*.bit \
    ${project_dir}/vivado_project/*/*.runs/impl_1/*.bit \
    ${project_dir}/vivado_project/systolic_array_top.runs/impl_1/*.bit] 0]
if {$bit_src eq ""} {
    set bit_src [lindex [get_files -quiet -of_objects [get_runs impl_1] *.bit] 0]
}
if {$bit_src eq "" || ![file exists $bit_src]} {
    error "Bitstream not found after impl_1"
}
file copy -force ${bit_src} ${deploy_dir}/systolic_gemm_accel.bit

write_hw_platform -fixed -include_bit -force \
    -file ${deploy_dir}/systolic_gemm_accel.xsa

puts "=============================================="
puts " BUILD DONE"
puts "   bit : ${deploy_dir}/systolic_gemm_accel.bit"
puts "   xsa : ${deploy_dir}/systolic_gemm_accel.xsa"
puts "   util: ${deploy_dir}/utilization_impl.rpt"
puts "   time: ${deploy_dir}/timing_impl.rpt"
puts "   WNS : ${wns} ns"
puts "=============================================="
