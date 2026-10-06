import inr_pkg::*;
module siren_block_engine
#(
parameter int TOTAL_NEURONS=32,
parameter int BLOCK_SIZE=4,
parameter int NUM_PASSES=(TOTAL_NEURONS/BLOCK_SIZE),
parameter int PASS_WIDTH=$clog2(NUM_PASSES),
parameter int DATA_WIDTH=16,
parameter int PROD_WIDTH=32,
parameter int ACC_WIDTH=40,
parameter int TILE_LATENCY=20
)
(
input logic clk,
input logic rst_in,
input logic start_eval,
input logic signed [15:0] coord_x,
input logic signed [15:0] coord_y,
input logic signed [DATA_WIDTH-1:0] w1_x_mem [0:TOTAL_NEURONS-1],
input logic signed [DATA_WIDTH-1:0] w1_y_mem [0:TOTAL_NEURONS-1],
input logic signed [DATA_WIDTH-1:0] b1_mem [0:TOTAL_NEURONS-1],
input logic signed [DATA_WIDTH-1:0] w2_mem [0:TOTAL_NEURONS-1],
input logic signed [DATA_WIDTH-1:0] b2_bias,

output logic busy,
output logic pixel_valid_out,
output logic [15:0] pixel_out
);

logic [15:0] coord_x_latched;
logic [15:0] coord_y_latched;
logic [2:0] pass_issue_cnt;
logic [3:0] pass_retire_cnt;
logic [4:0] lane_sel_idx [0:3];
logic [15:0] w1_x_mux [0:3];
logic [15:0] w1_y_mux [0:3];
logic [15:0] b1_mux [0:3];
logic [15:0] w2_mux [0:3];



endmodule
