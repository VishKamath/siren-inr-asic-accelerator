`timescale 1ns/1ps
import inr_pkg::*;

module siren_block_engine
#(
  parameter int TOTAL_NEURONS = 32,
  parameter int BLOCK_SIZE    = 4,
  parameter int NUM_PASSES    = (TOTAL_NEURONS / BLOCK_SIZE),
  parameter int PASS_WIDTH    = $clog2(NUM_PASSES),
  parameter int DATA_WIDTH    = 16,
  parameter int PROD_WIDTH    = 32,
  parameter int ACC_WIDTH     = 40
)
(
  input  logic                            clk,
  input  logic                            rst_in,
  input  logic                            start_eval,
  input  logic signed [DATA_WIDTH-1:0]    coord_x,
  input  logic signed [DATA_WIDTH-1:0]    coord_y,
  input  logic signed [DATA_WIDTH-1:0]    w1_x_mem [0:TOTAL_NEURONS-1],
  input  logic signed [DATA_WIDTH-1:0]    w1_y_mem [0:TOTAL_NEURONS-1],
  input  logic signed [DATA_WIDTH-1:0]    b1_mem   [0:TOTAL_NEURONS-1],
  input  logic signed [DATA_WIDTH-1:0]    w2_mem   [0:TOTAL_NEURONS-1],
  input  logic signed [DATA_WIDTH-1:0]    b2_bias,

  output logic                            busy,
  output logic                            pixel_valid_out,
  output logic signed [DATA_WIDTH-1:0]    pixel_out
);

  logic signed [DATA_WIDTH-1:0] coord_x_latched;
  logic signed [DATA_WIDTH-1:0] coord_y_latched;
  logic [PASS_WIDTH-1:0]        pass_issue_cnt;
  logic [PASS_WIDTH:0]          pass_retire_cnt;
  logic [PASS_WIDTH:0]          feed_cycle_cnt;
  logic [$clog2(TOTAL_NEURONS)-1:0] lane_sel_idx [0:BLOCK_SIZE-1];

  logic signed [DATA_WIDTH-1:0] w1_x_mux [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w1_y_mux [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] b1_mux   [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_mux   [0:BLOCK_SIZE-1];

  logic signed [31:0]           l1_prod_x [0:BLOCK_SIZE-1];
  logic signed [31:0]           l1_prod_y [0:BLOCK_SIZE-1];
  logic signed [33:0]           l1_affine_sum [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] tile_affine_q [0:BLOCK_SIZE-1];
  logic                         tile_valid_in;

  logic signed [DATA_WIDTH-1:0] neuron_act_out [0:BLOCK_SIZE-1];
  logic                         neuron_valid_lanes [0:BLOCK_SIZE-1];
  logic                         tile_valid_out;

  // Stored weights per pass (latched during ST_FEED)
  logic signed [DATA_WIDTH-1:0] w2_p0 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p1 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p2 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p3 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p4 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p5 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p6 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_p7 [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] w2_current [0:BLOCK_SIZE-1];

  logic signed [PROD_WIDTH-1:0] l2_prod_raw [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH-1:0] l2_prod_q   [0:BLOCK_SIZE-1];
  logic signed [DATA_WIDTH+1:0] tree_sum_01;
  logic signed [DATA_WIDTH+1:0] tree_sum_23;
  logic signed [DATA_WIDTH+2:0] block_sum_q12;

  logic signed [ACC_WIDTH-1:0]  acc_reg;
  logic signed [ACC_WIDTH-1:0]  final_sum;

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_FEED,
    ST_DRAIN,
    ST_FINALIZE
  } state_t;

  state_t state_q, state_d;
  logic   drain_started;

  // =========================================================================
  // Section 1: MUX Slicing
  // =========================================================================
  always_comb begin 
    for (int l = 0; l < BLOCK_SIZE; l++) begin 
      lane_sel_idx[l] = {pass_issue_cnt, 2'(l)};
      w1_x_mux[l]     = w1_x_mem[lane_sel_idx[l]];
      w1_y_mux[l]     = w1_y_mem[lane_sel_idx[l]];
      b1_mux[l]       = b1_mem[lane_sel_idx[l]];
      w2_mux[l]       = w2_mem[lane_sel_idx[l]];
    end
  end

  // =========================================================================
  // Section 2: Layer-1 Pre-calculation
  // =========================================================================
  always_comb begin
    for (int l = 0; l < BLOCK_SIZE; l++) begin
      l1_prod_x[l] = 32'(coord_x_latched) * 32'(w1_x_mux[l]);
      l1_prod_y[l] = 32'(coord_y_latched) * 32'(w1_y_mux[l]);
      
      l1_affine_sum[l] = 34'(b1_mux[l]) + 
                         34'((l1_prod_x[l] + 32'sh0000_0800) >>> 12) + 
                         34'((l1_prod_y[l] + 32'sh0000_0800) >>> 12);
    end
  end

  always_ff @(posedge clk or negedge rst_in) begin 
    if (!rst_in) begin 
      for (int l = 0; l < BLOCK_SIZE; l++) tile_affine_q[l] <= '0;
    end else begin
      if (state_q == ST_FEED) begin
        for (int l = 0; l < BLOCK_SIZE; l++) begin 
          if (l1_affine_sum[l] > 34'sd32767)
            tile_affine_q[l] <= 16'sh7FFF;
          else if (l1_affine_sum[l] < -34'sd32768)
            tile_affine_q[l] <= 16'sh8000;
          else
            tile_affine_q[l] <= l1_affine_sum[l][15:0];
        end
      end
    end
  end

  // Latch W2 weights into per-pass registers during ST_FEED
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      for (int l = 0; l < BLOCK_SIZE; l++) begin
        w2_p0[l] <= '0; w2_p1[l] <= '0; w2_p2[l] <= '0; w2_p3[l] <= '0;
        w2_p4[l] <= '0; w2_p5[l] <= '0; w2_p6[l] <= '0; w2_p7[l] <= '0;
      end
    end else if (state_q == ST_FEED) begin
      case (pass_issue_cnt)
        3'd0: for (int l = 0; l < BLOCK_SIZE; l++) w2_p0[l] <= w2_mux[l];
        3'd1: for (int l = 0; l < BLOCK_SIZE; l++) w2_p1[l] <= w2_mux[l];
        3'd2: for (int l = 0; l < BLOCK_SIZE; l++) w2_p2[l] <= w2_mux[l];
        3'd3: for (int l = 0; l < BLOCK_SIZE; l++) w2_p3[l] <= w2_mux[l];
        3'd4: for (int l = 0; l < BLOCK_SIZE; l++) w2_p4[l] <= w2_mux[l];
        3'd5: for (int l = 0; l < BLOCK_SIZE; l++) w2_p5[l] <= w2_mux[l];
        3'd6: for (int l = 0; l < BLOCK_SIZE; l++) w2_p6[l] <= w2_mux[l];
        3'd7: for (int l = 0; l < BLOCK_SIZE; l++) w2_p7[l] <= w2_mux[l];
        default: ;
      endcase
    end
  end

  // =========================================================================
  // Section 3: Physical Neurons
  // =========================================================================
  genvar lane_i;
  generate 
    for (lane_i = 0; lane_i < BLOCK_SIZE; lane_i++) begin : gen_physical_neurons
      siren_neuron sn (
        .clk       (clk),
        .rst_in    (rst_in),
        .valid_in  (tile_valid_in),
        .clr_acc   (1'b0),
        .a_in      (16'sh0),
        .w_in      (16'sh0),
        .bias_in   (tile_affine_q[lane_i]),
        .valid_out (neuron_valid_lanes[lane_i]),
        .act_out   (neuron_act_out[lane_i]),
        .cos_out   (/* unused */)
      );
    end
  endgenerate

  assign tile_valid_out = neuron_valid_lanes[0];

  // Select W2 using pass_retire_cnt
  always_comb begin
    case (pass_retire_cnt[2:0])
      3'd0: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p0[l];
      3'd1: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p1[l];
      3'd2: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p2[l];
      3'd3: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p3[l];
      3'd4: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p4[l];
      3'd5: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p5[l];
      3'd6: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p6[l];
      3'd7: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = w2_p7[l];
      default: for (int l = 0; l < BLOCK_SIZE; l++) w2_current[l] = 16'sh0;
    endcase
  end

  // =========================================================================
  // Section 4: Layer-2 Multipliers (Direct Q4.12)
  // =========================================================================
  always_comb begin 
    for (int l = 0; l < BLOCK_SIZE; l++) begin 
      l2_prod_raw[l] = 32'(signed'(neuron_act_out[l])) * 32'(signed'(w2_current[l]));
      l2_prod_q[l]   = 16'(((l2_prod_raw[l] + 32'sh0000_0800) >>> 12));
    end

    tree_sum_01   = 18'(signed'(l2_prod_q[0])) + 18'(signed'(l2_prod_q[1]));
    tree_sum_23   = 18'(signed'(l2_prod_q[2])) + 18'(signed'(l2_prod_q[3]));
    block_sum_q12 = 19'(signed'(tree_sum_01))  + 19'(signed'(tree_sum_23));
  end

  // =========================================================================
  // Section 5: Control FSM
  // =========================================================================
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin 
      state_q         <= ST_IDLE;
      coord_x_latched <= '0;
      coord_y_latched <= '0;
      pass_issue_cnt  <= '0;
      feed_cycle_cnt  <= '0;
    end else begin 
      state_q <= state_d;
      case (state_q)
        ST_IDLE: begin
          feed_cycle_cnt <= '0;
          pass_issue_cnt <= '0;
          if (start_eval) begin
            coord_x_latched <= coord_x;
            coord_y_latched <= coord_y;
          end
        end
        ST_FEED: begin 
          feed_cycle_cnt <= feed_cycle_cnt + 1'b1;
          if (pass_issue_cnt < (NUM_PASSES - 1)) begin
            pass_issue_cnt <= pass_issue_cnt + 1'b1;
          end
        end
        default: ;
      endcase
    end
  end

  always_comb begin 
    state_d = state_q;
    case (state_q) 	
      ST_IDLE: begin 
        if (start_eval) state_d = ST_FEED;
      end
      ST_FEED: begin 
        // Feed for 8 clock cycles to register affine values and send 8 valid pulses into tile
        if (feed_cycle_cnt == NUM_PASSES) begin
          state_d = ST_DRAIN;
        end
      end
      ST_DRAIN: begin 
        if (pass_retire_cnt == NUM_PASSES) begin 
          state_d = ST_FINALIZE;
        end
      end	
      ST_FINALIZE: begin 
        state_d = ST_IDLE;
      end
      default: state_d = ST_IDLE;
    endcase
  end

  // tile_valid_in is registered to align with the 1-cycle latency of tile_affine_q
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      tile_valid_in <= 1'b0;
    end else begin
      tile_valid_in <= (state_q == ST_FEED);
    end
  end

  // =========================================================================
  // Section 6: Accumulator
  // =========================================================================
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      drain_started   <= 1'b0;
      pass_retire_cnt <= '0;
      acc_reg         <= '0;
    end else begin
      if (state_q == ST_IDLE) begin
        drain_started   <= 1'b0;
        pass_retire_cnt <= '0;
        acc_reg         <= '0;
      end else if (state_q == ST_DRAIN) begin
        if (!drain_started) begin
          if (tile_valid_out && (neuron_act_out[0] != 16'sh0001)) begin
            drain_started   <= 1'b1;
            pass_retire_cnt <= 3'd1;
            acc_reg         <= 40'($signed(block_sum_q12));
          end
        end else if (pass_retire_cnt < NUM_PASSES) begin
          pass_retire_cnt <= pass_retire_cnt + 1'b1;
          acc_reg         <= acc_reg + 40'($signed(block_sum_q12));
        end
      end
    end
  end

  // Output formatting & clamp
  always_comb begin 
    final_sum = acc_reg + 40'($signed(b2_bias));

    if (final_sum > 40'sd32767) begin
      pixel_out = 16'sh7FFF;
    end else if (final_sum < -40'sd32768) begin 
      pixel_out = 16'sh8000;	
    end else begin 
      pixel_out = 16'(final_sum);	
    end
  end

  assign busy            = (state_q != ST_IDLE);
  assign pixel_valid_out = (state_q == ST_FINALIZE);

endmodule
