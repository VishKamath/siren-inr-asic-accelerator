`timescale 1ns/1ps
import inr_pkg::*;

module siren_top_integrated #(
  parameter int TOTAL_NEURONS = 64,
  parameter int BLOCK_SIZE    = 4,
  parameter int DATA_WIDTH    = 16
)(
  input  logic                   clk,
  input  logic                   rst_n,

  // Top-Level Control
  input  logic                   start,
  input  logic                   mode_sel,     // 0: Program SRAM, 1: Run Inference
  output logic                   busy,
  output logic                   frame_done,

  // External SRAM Programming Port (Active when mode_sel == 0)
  input  logic                   ext_we,
  input  logic [9:0]             ext_addr,
  input  logic [DATA_WIDTH-1:0]  ext_wdata,

  // Output Pixel Stream (Post Clamp)
  output logic                   pixel_valid,
  output logic signed [DATA_WIDTH-1:0] pixel_out
);

  // -------------------------------------------------------------------------
  // 1. Weight & Bias Internal Storage (Fed to siren_block_engine)
  // -------------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] w1_x_mem [0:TOTAL_NEURONS-1];
  logic signed [DATA_WIDTH-1:0] w1_y_mem [0:TOTAL_NEURONS-1];
  logic signed [DATA_WIDTH-1:0] b1_mem   [0:TOTAL_NEURONS-1];
  logic signed [DATA_WIDTH-1:0] w2_mem   [0:TOTAL_NEURONS-1];
  logic signed [DATA_WIDTH-1:0] b2_bias;

  // -------------------------------------------------------------------------
  // 2. SRAM Interface Wires
  // -------------------------------------------------------------------------
  logic                   sram_cen;
  logic                   sram_wen;
  logic [9:0]             sram_addr;
  logic [DATA_WIDTH-1:0]  sram_din;
  logic [DATA_WIDTH-1:0]  sram_dout;

  // -------------------------------------------------------------------------
  // 3. Engine Interconnects
  // -------------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] coord_x;
  logic signed [DATA_WIDTH-1:0] coord_y;
  logic                         engine_start;
  logic                         engine_busy;
  logic                         engine_pixel_valid;
  logic signed [DATA_WIDTH-1:0] engine_pixel_out;

  logic                         sharp_valid;
  logic signed [DATA_WIDTH-1:0] sharp_pixel;
  logic                         sharp_frame_done;

  logic                         clamp_valid;
  logic signed [DATA_WIDTH-1:0] clamp_pixel;
  logic                         clamp_frame_done;

  // -------------------------------------------------------------------------
  // 4. Memory Controller & Coordinate Scanner FSM
  // -------------------------------------------------------------------------
  typedef enum logic [2:0] {
    ST_IDLE       = 3'b000,
    ST_LOAD_SRAM  = 3'b001,
    ST_LOAD_W1X   = 3'b010,
    ST_LOAD_W1Y   = 3'b011,
    ST_LOAD_B1    = 3'b100,
    ST_LOAD_W2    = 3'b101,
    ST_LOAD_B2    = 3'b110,
    ST_RUN_RASTER = 3'b111
  } fsm_state_t;

  fsm_state_t state_q, state_d;
  logic [9:0] cfg_ptr;
  logic [5:0] r_cnt;
  logic [5:0] c_cnt;

  // SRAM bus multiplexing
  assign sram_cen  = (state_q == ST_LOAD_SRAM) ? 1'b0 : ((state_q == ST_IDLE) ? 1'b1 : 1'b0);
  assign sram_wen  = (state_q == ST_LOAD_SRAM) ? ~ext_we : 1'b1;
  assign sram_addr = (state_q == ST_LOAD_SRAM) ? ext_addr : cfg_ptr;
  assign sram_din  = ext_wdata;

  // Top level status assignments
  assign busy        = (state_q != ST_IDLE && state_q != ST_LOAD_SRAM);
  assign frame_done  = clamp_frame_done;
  assign pixel_valid = clamp_valid;
  assign pixel_out   = clamp_pixel;

  // -------------------------------------------------------------------------
  // 5. SRAM Macro Instance
  // -------------------------------------------------------------------------
  sram_1024x16 u_sram (
    .clk   (clk),
    .cen   (sram_cen),
    .wen   (sram_wen),
    .addr  (sram_addr),
    .d_in  (sram_din),
    .d_out (sram_dout)
  );

  // -------------------------------------------------------------------------
  // 6. FSM State and Coordinate Generation Logic
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q      <= ST_IDLE;
      cfg_ptr      <= 10'd0;
      r_cnt        <= 6'd0;
      c_cnt        <= 6'd0;
      engine_start <= 1'b0;
      coord_x      <= '0;
      coord_y      <= '0;
      b2_bias      <= '0;
    end else begin
      state_q <= state_d;

      case (state_q)
        ST_IDLE: begin
          cfg_ptr      <= 10'd0;
          r_cnt        <= 6'd0;
          c_cnt        <= 6'd0;
          engine_start <= 1'b0;
        end

        ST_LOAD_W1X: begin
          w1_x_mem[cfg_ptr] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        ST_LOAD_W1Y: begin
          w1_y_mem[cfg_ptr - 10'd64] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        ST_LOAD_B1: begin
          b1_mem[cfg_ptr - 10'd128] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        ST_LOAD_W2: begin
          w2_mem[cfg_ptr - 10'd192] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        ST_LOAD_B2: begin
          b2_bias <= sram_dout;
          cfg_ptr <= 10'd0;
        end

        ST_RUN_RASTER: begin
          if (!engine_busy && (r_cnt < 32)) begin
            engine_start <= 1'b1;
            // Linear mapping of [0..31] into Q4.12 fixed point [-1.0, 1.0]
            coord_x <= -16'sd4096 + 16'(signed'((c_cnt * 16'sd8192) / 16'sd31));
            coord_y <= -16'sd4096 + 16'(signed'((r_cnt * 16'sd8192) / 16'sd31));

            if (c_cnt == 31) begin
              c_cnt <= 6'd0;
              r_cnt <= r_cnt + 1'b1;
            end else begin
              c_cnt <= c_cnt + 1'b1;
            end
          end else if (r_cnt >= 32 && !clamp_frame_done) begin
            // Flush coordinates to drain sharpen line buffers
            engine_start <= ~engine_busy;
            coord_x      <= 16'sh1000;
            coord_y      <= 16'sh1000;
          end else begin
            engine_start <= 1'b0;
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
        if (!mode_sel)
          state_d = ST_LOAD_SRAM;
        else if (start)
          state_d = ST_LOAD_W1X;
      end
      ST_LOAD_SRAM:  if (mode_sel) state_d = ST_IDLE;
      ST_LOAD_W1X:   if (cfg_ptr == 10'd63)  state_d = ST_LOAD_W1Y;
      ST_LOAD_W1Y:   if (cfg_ptr == 10'd127) state_d = ST_LOAD_B1;
      ST_LOAD_B1:    if (cfg_ptr == 10'd191) state_d = ST_LOAD_W2;
      ST_LOAD_W2:    if (cfg_ptr == 10'd255) state_d = ST_LOAD_B2;
      ST_LOAD_B2:    state_d = ST_RUN_RASTER;
      ST_RUN_RASTER: if (clamp_frame_done) state_d = ST_IDLE;
      default:       state_d = ST_IDLE;
    endcase
  end

  // -------------------------------------------------------------------------
  // 7. Core Compute Engine Instances (Exact Port Match)
  // -------------------------------------------------------------------------
  siren_block_engine #(
    .TOTAL_NEURONS (TOTAL_NEURONS),
    .BLOCK_SIZE    (BLOCK_SIZE),
    .DATA_WIDTH    (DATA_WIDTH)
  ) u_engine (
    .clk             (clk),
    .rst_in          (rst_n),
    .start_eval      (engine_start),
    .coord_x         (coord_x),
    .coord_y         (coord_y),
    .w1_x_mem        (w1_x_mem),
    .w1_y_mem        (w1_y_mem),
    .b1_mem          (b1_mem),
    .w2_mem          (w2_mem),
    .b2_bias         (b2_bias),
    .busy            (engine_busy),
    .pixel_valid_out (engine_pixel_valid),
    .pixel_out       (engine_pixel_out)
  );

  siren_sharpen u_sharpen (
    .clk             (clk),
    .rst_in          (rst_n),
    .data_in         (engine_pixel_out),
    .valid_in        (engine_pixel_valid),
    .pixel_valid     (sharp_valid),
    .pixel_out       (sharp_pixel),
    .frame_done      (sharp_frame_done)
  );

  siren_clamp u_clamp (
    .clk             (clk),
    .rst_in          (rst_n),
    .valid_in        (sharp_valid),
    .data_in         (sharp_pixel),
    .valid_out       (clamp_valid),
    .data_out        (clamp_pixel),
    .frame_done      (clamp_frame_done)
  );

endmodule
