create_clock -period 10.0 [get_ports clk]
set_clock_transition 0.1 [get_clocks clk]
set_clock_uncertainty -setup 0.2 [get_clocks clk]
set_clock_uncertainty -hold 0.1 [get_clocks clk]

# Constrain all primary I/O relative to clk
set_input_delay  -clock clk -max 2.0 [remove_from_collection [all_inputs] [get_ports {clk rst_in}]]
set_input_delay  -clock clk -min 0.5 [remove_from_collection [all_inputs] [get_ports {clk rst_in}]]

set_output_delay -clock clk -max 2.0 [all_outputs]
set_output_delay -clock clk -min 0.5 [all_outputs]

set_false_path -from [get_ports rst_in]
set_load 0.05 [all_outputs]
