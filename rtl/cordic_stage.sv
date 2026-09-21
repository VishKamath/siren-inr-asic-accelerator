import inr_pkg::*;
module cordic_stage #(
parameter int DATA_WIDTH =16,
parameter int STAGE_IDX=0,
parameter logic signed [DATA_WIDTH-1:0] ATAN_VAL=16'sh0000)
(
	input logic clk,
	input logic rst_n,
	input logic valid_in,
	input logic signed [DATA_WIDTH-1:0] x_in,
	input logic signed [DATA_WIDTH-1:0] y_in,
	input logic signed [DATA_WIDTH-1:0] z_in,
	
	output logic valid_out,
	output logic signed [DATA_WIDTH-1:0] x_out,
	output logic signed [DATA_WIDTH-1:0] y_out,
	output logic signed  [DATA_WIDTH-1:0] z_out
);
logic signed [DATA_WIDTH-1:0] x0;
logic signed [DATA_WIDTH-1:0] y0;

always_comb begin
	x0 = x_in >>> STAGE_IDX;
	y0 = y_in >>> STAGE_IDX;
end

always_ff @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin 
		valid_out <= 0;
		x_out <= 0;
		y_out <= 0;
		z_out <= 0;
	end
	else begin 
		if (valid_in) begin
			if (z_in>=0) begin
				x_out <= x_in - y0;
				y_out <= y_in + x0;
				z_out<= z_in - ATAN_VAL;
			end
			else begin 
				x_out <= x_in + y0;
				y_out <= y_in - x0;
				z_out <= z_in + ATAN_VAL;
			end
		end
		valid_out <= valid_in;
	end
end 
endmodule
