import inr_pkg::*;

module siren_act_unit(
input logic clk,
input logic rst_in,
input logic valid_in,
input logic signed [ACT_WIDTH-1:0] angle_in,

output logic valid_out,
output logic signed [ACT_WIDTH-1:0] sin_out,
output logic signed [ACT_WIDTH-1:0] cos_out
);
logic signed [ACT_WIDTH-1:0] phase_folded;
logic folder_valid;

phase_folder phase_f (.clk(clk),.rst_in(rst_in),.valid_in(valid_in),.angle_in(angle_in),.valid_out_folded(folder_valid),.phase_out_folded(phase_folded));

cordic_wrapper u_cordic (.clk(clk),.rst_in(rst_in),.valid_in(folder_valid),.phase_in(phase_folded),.valid_out(valid_out),.sin_out(sin_out),.cos_out(cos_out));

endmodule
