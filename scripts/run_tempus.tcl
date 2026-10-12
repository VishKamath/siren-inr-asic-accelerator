######################################################################
# Cadence Tempus Signoff STA Script - siren_block_engine
######################################################################

set_multi_cpu_usage -localCpu 4
set load_netlist_ignore_undefined_cell true

set DESIGN_NAME   "siren_block_engine"
set NETLIST_FILE  "outputs/siren_block_engine_postroute.v"
set SPEF_FILE     "outputs/siren_block_engine.spef"

set LIB_DIR       "/home/install/FOUNDRY/digital/90nm/dig/lib"
set LEF_DIR       "/home/install/FOUNDRY/digital/90nm/dig/lef"
set CELL_LEF      "$LEF_DIR/gsclib090_translated_ref.lef"
set SLOW_LIB      "$LIB_DIR/slow.lib"
set FAST_LIB      "$LIB_DIR/fast.lib"

file mkdir tempus_reports

# 1. Write Fresh Signoff SDC
set SDC_FILE "tempus_reports/signoff_generated.sdc"
set sdc_fp [open $SDC_FILE w]
puts $sdc_fp "current_design siren_block_engine"
puts $sdc_fp "create_clock -name clk -period 10.000000 -waveform {0.0 5.0} \[get_ports {clk}\]"
puts $sdc_fp "set_clock_transition -rise 0.100 \[get_clocks {clk}\]"
puts $sdc_fp "set_clock_transition -fall 0.100 \[get_clocks {clk}\]"
puts $sdc_fp "set_clock_uncertainty -setup 0.100 \[get_clocks {clk}\]"
puts $sdc_fp "set_clock_uncertainty -hold  0.010 \[get_clocks {clk}\]"

puts $sdc_fp "set_load -pin_load -max 0.05 \[all_outputs\]"
puts $sdc_fp "set_load -pin_load -min 0.05 \[all_outputs\]"
puts $sdc_fp "set_output_delay -clock clk -max 2.000 \[all_outputs\]"
puts $sdc_fp "set_output_delay -clock clk -min 0.500 \[all_outputs\]"

# Data input delays
puts $sdc_fp "set in_ports \[remove_from_collection \[all_inputs\] \[get_ports {clk}\]\]"
puts $sdc_fp "set_input_delay -clock clk -max 2.000 \$in_ports"
puts $sdc_fp "set_input_delay -clock clk -min 0.700 \$in_ports"

# Asynchronous resets
puts $sdc_fp "set_false_path -hold -from \[get_ports {*rst* *reset*}\]"

puts $sdc_fp "set_wire_load_mode enclosed"
close $sdc_fp

# 2. Regenerate MMMC View Definition
set mmmc_file "tempus_reports/mmmc_generated.tcl"
set fp [open $mmmc_file w]
puts $fp "create_library_set -name lib_slow -timing \[list $SLOW_LIB\]"
puts $fp "create_library_set -name lib_fast -timing \[list $FAST_LIB\]"
puts $fp "create_rc_corner -name rc_corner_nominal -T 25.0"
puts $fp "create_delay_corner -name delay_corner_worst -library_set lib_slow -rc_corner rc_corner_nominal"
puts $fp "create_delay_corner -name delay_corner_best  -library_set lib_fast -rc_corner rc_corner_nominal"
puts $fp "create_constraint_mode -name constr_func -sdc_files \[list $SDC_FILE\]"
puts $fp "create_analysis_view -name worst_case -delay_corner delay_corner_worst -constraint_mode constr_func"
puts $fp "create_analysis_view -name best_case  -delay_corner delay_corner_best  -constraint_mode constr_func"
puts $fp "set_analysis_view -setup \[list worst_case\] -hold \[list best_case\]"
close $fp

# 3. Design Initialization
set init_lef_file       [list $CELL_LEF]
set init_mmmc_file      $mmmc_file
set init_verilog        $NETLIST_FILE
set init_top_cell       $DESIGN_NAME

init_design

set_interactive_constraint_modes [all_constraint_modes -active]
read_spef $SPEF_FILE

if {[llength [get_clocks -quiet *]] > 0} {
    set_propagated_clock [get_clocks *]
}

set_si_mode -enable_delay_report true -enable_glitch_report true
update_timing -full

# 4. Targeted ECO Setup Fix
set_eco_mode -batch_mode true
catch {
    eco_update_cell -inst gen_physical_neurons[2].sn_siren_s/const_mul_23_33_g2541 -cell NOR2X1
}
set_eco_mode -batch_mode false
update_timing -full

# 5. Generate Final Signoff Reports
report_timing -late  -view worst_case -max_paths 20 > tempus_reports/setup_signoff.rpt
report_timing -early -view best_case  -max_paths 20 > tempus_reports/hold_signoff.rpt

report_timing_summary > tempus_reports/timing_summary.rpt
report_constraint -all_violators > tempus_reports/all_violators.rpt

# 6. Export Updated Netlist
saveNetlist outputs/siren_block_engine_eco.v

puts "\n=============================================="
puts "Tempus Signoff STA Execution Complete!"
puts "Check: cat tempus_reports/timing_summary.rpt"
puts "==============================================\n"

exit
