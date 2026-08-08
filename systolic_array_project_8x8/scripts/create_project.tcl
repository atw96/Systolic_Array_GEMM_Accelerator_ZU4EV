# =============================================================
# 文件名  : create_project.tcl
# 描述    : Vivado 2020.1 非 Block Design 仿真/综合工程创建脚本
#           （用于 RTL 仿真验证，不含 Block Design）
# 平台    : XCZU4EV-1SFVC784I（ALINX ACU4EV）
# 运行    : source /tools/Xilinx/Vivado/2020.1/settings64.sh
#           vivado -mode batch -source create_project.tcl
# =============================================================

set proj_name "systolic_sim"
set proj_dir  "./vivado_sim_project"

# !! 注意：Vivado 2020.1 器件名格式
#    XCZU4EV-1SFVC784I → xczu4ev-sfvc784-1-i（全小写，连字符分隔）
set part_id   "xczu4ev-sfvc784-1-i"

# ── 创建工程 ──────────────────────────────────────────────────
create_project ${proj_name} ${proj_dir} -part ${part_id} -force

# 设置仿真器为 xsim（Vivado 自带，无需额外安装）
set_property simulator_language Mixed [current_project]
set_property target_simulator XSim    [current_project]

# ── 添加 RTL 源文件 ───────────────────────────────────────────
add_files -norecurse {
    ./rtl/pe_unit.v
    ./rtl/systolic_array.v
    ./rtl/ctrl_fsm.v
    ./rtl/axi_ctrl_top.v
}
set_property file_type SystemVerilog [get_files *.v]

# ── 添加约束文件 ──────────────────────────────────────────────
add_files -fileset constrs_1 -norecurse ./constraints/acu4ev_top.xdc

# ── 添加仿真文件 ──────────────────────────────────────────────
add_files -fileset sim_1 -norecurse ./tb/pe_unit_tb.v
set_property top pe_unit_tb [get_filesets sim_1]

# ── 设置综合顶层 ──────────────────────────────────────────────
set_property top axi_ctrl_top [current_fileset]

# ── Vivado 2020.1 综合策略（可选）────────────────────────────
set_property strategy "Vivado Synthesis Defaults" [get_runs synth_1]
set_property strategy "Vivado Implementation Defaults" [get_runs impl_1]

# ── 运行综合（取消注释以执行）────────────────────────────────
# launch_runs synth_1 -jobs 4
# wait_on_run synth_1
# open_run synth_1 -name synth_1
# report_utilization -file ./reports/utilization_synth.rpt
# report_timing_summary -file ./reports/timing_synth.rpt

# ── 运行仿真（取消注释以执行）────────────────────────────────
# launch_simulation
# run all

puts "工程创建完成：${proj_dir}/${proj_name}.xpr"
puts "可用命令："
puts "  综合：launch_runs synth_1"
puts "  仿真：launch_simulation（或直接运行 run_xsim.sh）"
