# Step 1: Set Search Paths and Target Libraries
set_db init_lib_search_path {/home/install/FOUNDRY/digital/45nm/dig/lib}
set_db init_hdl_search_path {../rtl}

read_libs slow.lib

# Step 2: Read Design Files (Package MUST be read first)
read_hdl -language sv {
    inr_pkg.sv
    cordic_stage.sv
    cordic_wrapper.sv
    phase_folder.sv
    siren_act_unit.sv
    mac_unit.sv
    siren_neuron.sv
}

# Step 3: Elaborate Top-Level Module
elaborate siren_neuron

# Verify design hierarchy after elaboration
check_design -unresolved

# Step 4: Load Timing Constraints (SDC)
read_sdc ../scripts/constraints.sdc

# Step 5: Synthesize to Generic Gates, Map to Technology, and Optimize
syn_generic
syn_map
syn_opt

# Step 6: Generate Reports
file mkdir ../reports
report_timing > ../reports/timing_report.rpt
report_area > ../reports/area_report.rpt
report_power > ../reports/power_report.rpt
report_qor > ../reports/qor_report.rpt

# Step 7: Export Netlist for Place & Route (Innovus)
file mkdir ../outputs
write_hdl > ../outputs/neuron_netlist.v
write_sdc > ../outputs/neuron_out.sdc

gui_show
