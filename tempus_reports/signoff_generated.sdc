current_design siren_block_engine
create_clock -name clk -period 10.000000 -waveform {0.0 5.0} [get_ports {clk}]
set_clock_transition -rise 0.100 [get_clocks {clk}]
set_clock_transition -fall 0.100 [get_clocks {clk}]
set_clock_uncertainty -setup 0.100 [get_clocks {clk}]
set_clock_uncertainty -hold  0.010 [get_clocks {clk}]
set_load -pin_load -max 0.05 [all_outputs]
set_load -pin_load -min 0.05 [all_outputs]
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]
set in_ports [remove_from_collection [all_inputs] [get_ports {clk}]]
set_input_delay -clock clk -max 2.000 $in_ports
set_input_delay -clock clk -min 0.700 $in_ports
set_false_path -hold -from [get_ports {*rst* *reset*}]
set_wire_load_mode enclosed
