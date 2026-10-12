# =========================================================================
# Cadence Genus Synthesis Script - Full INR Block Engine
# =========================================================================

# Step 1: Set Search Paths and Target Libraries (using 90nm / 45nm)
set_db init_lib_search_path {/home/install/FOUNDRY/digital/90nm/dig/lib}
set_db init_hdl_search_path {rtl .}
set_db max_cpus_per_server 8

read_libs slow.lib

# Step 2: Read Design Files in order
read_hdl -language sv {
    rtl/inr_pkg.sv
    rtl/cordic_stage.sv
    rtl/cordic_wrapper.sv
    rtl/phase_folder.sv
    rtl/siren_scaler.sv
    rtl/siren_act_unit.sv
    rtl/mac_unit.sv
    rtl/siren_neuron.sv
    rtl/siren_block_engine.sv
    rtl/siren_sharpen.sv
    rtl/siren_clamp.sv
}

# Step 3: Elaborate Top-Level Module
set TOP_MODULE siren_block_engine
elaborate $TOP_MODULE

check_design -unresolved

# Step 4: Load Timing Constraints
read_sdc scripts/constraints.sdc

# Step 5: Synthesize and Optimize
syn_generic
syn_map
syn_opt

# Step 6: Generate Complete Reports
file mkdir reports
report_timing > reports/timing_report.rpt
report_area   > reports/area_report.rpt
report_gates  > reports/gates_report.rpt
report_power  > reports/power_report.rpt
report_qor    > reports/qor_report.rpt

# Step 7: Export Netlist & SDC for Innovus
file mkdir outputs
write_hdl > outputs/inr_accelerator_netlist.v
write_sdc > outputs/inr_accelerator_out.sdc

puts "\n=============================================="
puts "  GENUS SYNTHESIS COMPLETED SUCCESSFULLY      "
puts "==============================================\n"
