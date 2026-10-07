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
logic adder_valid_q;
logic signed [DATA_WIDTH-1:0] w2_delay_pipe [0:TILE_LATENCY-1][0:3];
logic signed [DATA_WIDTH-1:0] w2_aligned [0:3];

logic signed [PROD_WIDTH-1:0] l2_prod [0:3];
logic signed [PROD_WIDTH-1:0] l2_prod_q [0:3];
logic signed [PROD_WIDTH:0] tree_sum_01;
logic signed [PROD_WIDTH:0] tree_sum_23;
logic signed [PROD_WIDTH+1:0] block_sum;
logic signed [ACC_WIDTH-1:0] acc_reg;

logic signed [ACC_WIDTH-1:0] acc_with_bias;
logic signed [27:0] pre_clamp;


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
for (lane=0;lane<BLOCK_SIZE;lane++)  begin :gen_physical_neurons
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
			l2_prod_q[lane]<=l2_prod[lane];
		end
	end
end

always_comb begin  
	tree_sum_01=33'($signed(l2_prod_q[0]))+33'($signed(l2_prod_q[1]));
	tree_sum_23=33'($signed(l2_prod_q[2]))+33'($signed(l2_prod_q[3]));
	block_sum=34'($signed(tree_sum_01))+34'($signed(tree_sum_23));
end


always_ff @(posedge clk or negedge rst_in) begin
	if (!rst_in) begin 
		state_q<=ST_IDLE;
		coord_x_latched <=0;
		coord_y_latched<=0;
		pass_issue_cnt<=0;
	end
	else begin 
		state_q<=state_d;
	case(state_q)
		ST_IDLE: if (start_eval) begin
				coord_x_latched<=coord_x;
				coord_y_latched<=coord_y;
				pass_issue_cnt<=0;
			 end
		ST_FEED:begin pass_issue_cnt <= pass_issue_cnt+1'b1;end
		default : ;
	endcase
	end
end

always_comb begin 
	state_d =state_q;
	case(state_q) 	
		ST_IDLE:begin 
				if (start_eval) begin state_d=ST_FEED;	end		
			end
		ST_FEED:begin 
				if (pass_issue_cnt==NUM_PASSES-1) begin
					state_d=ST_DRAIN;
				end
			end
		ST_DRAIN:begin 
			 	if (pass_retire_cnt==NUM_PASSES) begin 
					state_d=ST_FINALIZE;
				end
			 end	
		ST_FINALIZE: begin 
			     		state_d=ST_IDLE;
			     end
		default:state_d=ST_IDLE;
	endcase
end
assign tile_valid_in=(state_q==ST_FEED);
always_ff @(posedge clk or negedge rst_in) begin 
	if (!rst_in) begin 
		adder_valid_q<=0;
		pass_retire_cnt<=0;
		acc_reg<='0;
	end
	else begin 
		adder_valid_q<=tile_valid_out;
		if (state_q==ST_IDLE) begin 
			pass_retire_cnt<=0;
			acc_reg<=0;		
		end
		if (adder_valid_q) begin 
			pass_retire_cnt <= pass_retire_cnt+1'b1;
			acc_reg<=acc_reg+40'($signed(block_sum));		
		end
	end

end
always_comb begin 
	acc_with_bias=acc_reg+40'($signed({b2_bias,12'b0}));
	pre_clamp=acc_with_bias>>>12;
	if (pre_clamp > 28'sh0007FFF) begin
		pixel_out=16'sh7FFF;
	end	
	else if (pre_clamp <-28'sh0008000) begin 
		pixel_out=16'sh8000;	
	end
	else begin 
		pixel_out=pre_clamp[15:0];	
	end
end
assign busy            = (state_q != ST_IDLE);
assign pixel_valid_out = (state_q == ST_FINALIZE);
endmodule
