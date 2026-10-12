###############################################################
# Signoff SDC Constraints - siren_block_engine (90nm)
###############################################################
current_design siren_block_engine

# 1. Clock Definition (100 MHz / 10.0 ns)
create_clock -name clk -period 10.000000 -waveform {0.0 5.0} [get_ports {clk}]

# 2. Clock Transition & Realistic Signoff Uncertainty
set_clock_transition -rise 0.100 [get_clocks {clk}]
set_clock_transition -fall 0.100 [get_clocks {clk}]

set_clock_uncertainty -setup 0.100 [get_clocks {clk}]
set_clock_uncertainty -hold  0.030 [get_clocks {clk}]

# 3. Output Delays and Loads
set_load -pin_load -max 0.05 [all_outputs]
set_load -pin_load -min 0.05 [all_outputs]

set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]

# 4. Input Delays on ALL Primary Data Inputs (Resolves IN2REG hold)
set_input_delay -clock clk -max 2.000 [get_ports {w1_* w2_* b1_* b2_* coord_* in_* start rst*}]
set_input_delay -clock clk -min 0.500 [get_ports {w1_* w2_* b1_* b2_* coord_* in_* start rst*}]

set_wire_load_mode enclosed
