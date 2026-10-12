###############################################################
# Signoff SDC Constraints - siren_block_engine (90nm)
###############################################################
current_design siren_block_engine

# 1. Clock Definition (100 MHz / 10.0 ns period)
create_clock -name clk -period 10.000000 -waveform {0.0 5.0} [get_ports {clk}]

# 2. Clock Transition & Realistic Post-Route Uncertainty
set_clock_transition -rise 0.100 [get_clocks {clk}]
set_clock_transition -fall 0.100 [get_clocks {clk}]

# Post-route signoff jitter & margin (Tightened for physical stage)
set_clock_uncertainty -setup 0.100 [get_clocks {clk}]
set_clock_uncertainty -hold  0.030 [get_clocks {clk}]

# 3. Output Load (50 fF standard cell load)
set_load -pin_load -max 0.05 [all_outputs]
set_load -pin_load -min 0.05 [all_outputs]

# 4. Output Delays
set_output_delay -clock clk -max 2.0 [all_outputs]
set_output_delay -clock clk -min 0.5 [all_outputs]

# 5. Input Delays (Applies to ALL memory & coordinate input ports)
set all_data_inputs [remove_from_collection [all_inputs] [get_ports {clk}]]

set_input_delay -clock clk -max 2.000 $all_data_inputs
set_input_delay -clock clk -min 0.500 $all_data_inputs

# 6. Design Rules
set_wire_load_mode enclosed
