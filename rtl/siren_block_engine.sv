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
output logic signed [DATA_WIDTH-1:0] pixel_out
);

logic signed [DATA_WIDTH-1:0] coord_x_latched;
logic signed [DATA_WIDTH-1:0] coord_y_latched;
logic [2:0] pass_issue_cnt;
logic [3:0] pass_retire_cnt;
logic [4:0] lane_sel_idx [0:3];
logic signed [DATA_WIDTH-1:0] w1_x_mux [0:3];
logic signed [DATA_WIDTH-1:0] w1_y_mux [0:3];
logic signed [DATA_WIDTH-1:0] b1_mux [0:3];
logic signed [DATA_WIDTH-1:0] w2_mux [0:3];

logic signed [DATA_WIDTH-1:0] tile_w1_x_q [0:3];
logic signed [DATA_WIDTH-1:0] tile_w1_y_q [0:3];
logic signed [DATA_WIDTH-1:0] tile_b1_q [0:3];
logic tile_valid_in;
logic signed [DATA_WIDTH-1:0] neuron_act_out [0:3];
logic neuron_valid_lanes [0:BLOCK_SIZE-1];
logic tile_valid_out;

logic signed [DATA_WIDTH-1:0] w2_delay_pipe [0:TILE_LATENCY-1][0:3];
logic signed [DATA_WIDTH-1:0] w2_aligned [0:3];

logic signed [PROD_WIDTH-1:0] l2_prod [0:3];
logic signed [PROD_WIDTH-1:0] l2_prod_q [0:3];
logic signed [PROD_WIDTH:0] tree_sum_01;
logic signed [PROD_WIDTH:0] tree_sum_23;
logic signed [PROD_WIDTH+1:0] block_sum;
logic signed [ACC_WIDTH-1:0] acc_reg;

typedef enum logic [1:0] {
ST_IDLE,
ST_FEED,
ST_DRAIN,
ST_FINALIZE
}state_t;
state_t state_q, state_d;

always_comb begin 
for (int lane=0;lane<BLOCK_SIZE;lane++) begin 
	lane_sel_idx[lane]={pass_issue_cnt,2'(lane)};
	w1_x_mux[lane]=w1_x_mem[(lane_sel_idx[lane])];
	w1_y_mux[lane]=w1_y_mem[(lane_sel_idx[lane])];
	b1_mux[lane]=b1_mem[(lane_sel_idx[lane])];
	w2_mux[lane]=w2_mem[(lane_sel_idx[lane])];
end
end

always_ff @(posedge clk or negedge rst_in) begin 
	if (!rst_in) begin 
		for (int lane=0;lane<BLOCK_SIZE;lane++)begin 
			tile_w1_x_q[lane]<=0;
			tile_w1_y_q[lane]<=0;
			tile_b1_q[lane]<=0;
		end
	end
	else begin
	if (state_q==ST_FEED) begin
		for (int lane=0;lane<BLOCK_SIZE;lane++)begin 
			tile_w1_x_q[lane]<=w1_x_mux[lane];
			tile_w1_y_q[lane]<=w1_y_mux[lane];
			tile_b1_q[lane]<=b1_mux[lane];
		end
	end
	end
end
genvar lane;
generate 
for (LANE=0;LANE<BLOCK_SIZE;LANE++)  begin :gen_physical_neurons
	siren_neuron sn (
        .clk       (clk),
        .rst_in    (rst_in),
        .valid_in  (tile_valid_in),
        .clr_acc   (1'b0),
        .a_in      (coord_x_latched),
        .w_in      (tile_w1_x_q[lane]),
        .bias_in   (tile_b1_q[lane]),
        .valid_out (neuron_valid_lanes[lane]),
        .act_out   (neuron_act_out[lane]),
        .cos_out   (/* unused */)
      );
end
endgenerate
assign tile_valid_out=neuron_valid_lanes[0];

always_ff @(posedge clk or negedge rst_in) begin 
	if (!rst_in) begin 
		for (int i=0;i<TILE_LATENCY;i++) begin 
			for (int lane=0;lane<BLOCK_SIZE;lane++) begin 
				w2_delay_pipe[i][lane] <=0;
			end
		end
	end
	else begin 
		for (int i=0;i<TILE_LATENCY;i++) begin 
			for (int lane=0;lane<BLOCK_SIZE;lane++) begin 
				if (i==0) begin 
					w2_delay_pipe[0][lane] <=w2_mux[lane];
				end
				else begin 
					w2_delay_pipe[i][lane] <=w2_delay_pipe[i-1][lane];
				end
			end
		end
	end
end

always_comb begin
		for (int lane=0;lane<BLOCK_SIZE;lane++) begin
			w2_aligned[lane] = w2_delay_pipe[TILE_LATENCY-1][lane];
		end
end

always_comb begin 
	for (int lane=0;lane<BLOCK_SIZE;lane++) begin 
		l2_prod[lane] = neuron_act_out[lane] * w2_aligned[lane];
	end
end

always_ff @(posedge clk or negedge rst_in) begin 
	if (!rst_in) begin 
		for (int lane=0;lane<BLOCK_SIZE;lane++) begin 
			l2_prod_q[lane]<=0;
		end
	end
	else begin
		for (int lane=0;lane<BLOCK_SIZE;lane++) begin 
			l2_prod_q[lane]<=l2_prod_lane;
		end
	end
end

always_comb begin  
	tree_sum_01=33'($signed(l2_prod_q[0]))+33'($signed(l2_prod_q[1]));
	tree_sum_23=33'($signed(l2_prod_q[2]))+33'($signed(l2_prod_q[3]));
	block_sum=34'($signed(tree_sum_01))+34'($signed(tree_sum_23));
end







endmodule
