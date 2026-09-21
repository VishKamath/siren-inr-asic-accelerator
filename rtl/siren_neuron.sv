import inr_pkg::*;
module siren_neuron (
input logic clk,
input logic rst_in,
input logic valid_in,
input logic clr_acc,
input logic signed [ACT_WIDTH-1:0] a_in,
input logic signed [ACT_WIDTH-1:0] w_in,
input logic signed [ACT_WIDTH-1:0] bias_in,

output logic valid_out,
output logic signed [ACT_WIDTH-1:0] act_out,
output logic signed [ACT_WIDTH-1:0] cos_out
);
logic wire_mac;
logic signed [ACT_WIDTH-1:0] mac_result;
logic wire_scaler;
logic signed [ACT_WIDTH-1:0] scaled_result;

mac_unit mac (.clk(clk),.rst_in(rst_in),.valid_in(valid_in),.a_in(a_in),.w_in(w_in),.bias_in(bias_in),.clr_acc(clr_acc),.valid_out(wire_mac),.acc_out(mac_result));

siren_scaler siren_s (.clk(clk),.rst_in(rst_in),.valid_in(wire_mac),.data_in(mac_result),.data_out(scaled_result),.valid_out(wire_scaler));

siren_act_unit siren_act (.clk(clk),.rst_in(rst_in),.valid_in(wire_scaler),.angle_in(scaled_result),.sin_out(act_out),.cos_out(cos_out),.valid_out(valid_out));


endmodule
