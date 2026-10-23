`timescale 1ns/1ps
import inr_pkg::*;

module siren_top #(
  parameter int TOTAL_NEURONS = 64,
  parameter int BLOCK_SIZE    = 4
)(
  input  logic        clk,
  input  logic        rst_n,

  // Control Interface
  input  logic        start,
  input  logic        mode_sel,       // 0: Program Weights to SRAM, 1: Execute Inference
  output logic        busy,
  output logic        frame_done,

  // External SRAM Programming Interface (when mode_sel = 0)
  input  logic        ext_we,
  input  logic [9:0]  ext_addr,
  input  logic [15:0] ext_wdata,

  // Filtered Output Stream (from Clamp unit)
  output logic        pixel_valid,
  output logic [15:0] pixel_out
);

  // -------------------------------------------------------------
  // 1. Parameter Register Files
  // -------------------------------------------------------------
  logic signed [15:0] w1_x_mem [0:TOTAL_NEURONS-1];
  logic signed [15:0] w1_y_mem [0:TOTAL_NEURONS-1];
  logic signed [15:0] b1_mem   [0:TOTAL_NEURONS-1];
  logic signed [15:0] w2_mem   [0:TOTAL_NEURONS-1];
  logic signed [15:0] b2_bias;

  // -------------------------------------------------------------
  // 2. SRAM Macro Interface Signals
  // -------------------------------------------------------------
  logic        sram_cen;
  logic        sram_wen;
  logic [9:0]  sram_addr;
  logic [15:0] sram_din;
  logic [15:0] sram_dout;

  // -------------------------------------------------------------
  // 3. Coordinate Generation & Pipeline Control Signals
  // -------------------------------------------------------------
  logic signed [15:0] x_coord, y_coord;
  logic        engine_start;
  logic        engine_busy;
  logic        raw_valid;
  logic signed [15:0] raw_pixel;

  logic        sharp_valid;
  logic signed [15:0] sharp_pixel;
  logic        sharp_done;

  logic        clamp_valid;
  logic signed [15:0] clamp_pixel;
  logic        clamp_done;

  // -------------------------------------------------------------
  // 4. Memory Controller & Raster Scan FSM
  // -------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE      = 3'b000,
    S_LOAD_SRAM = 3'b001,
    S_LOAD_W1X  = 3'b010,
    S_LOAD_W1Y  = 3'b011,
    S_LOAD_B1   = 3'b100,
    S_LOAD_W2   = 3'b101,
    S_LOAD_B2   = 3'b110,
    S_RUN_RASTER= 3'b111
  } state_t;

  state_t state, next_state;
  logic [9:0] r_cnt, c_cnt;
  logic [9:0] cfg_ptr;
  logic [9:0] flush_cnt;

  // SRAM Multiplexing
  assign sram_cen  = (state == S_LOAD_SRAM) ? 1'b0 : (state == S_IDLE ? 1'b1 : 1'b0);
  assign sram_wen  = (state == S_LOAD_SRAM) ? ~ext_we : 1'b1;
  assign sram_addr = (state == S_LOAD_SRAM) ? ext_addr : cfg_ptr;
  assign sram_din  = ext_wdata;

  // Top status outputs
  assign busy        = (state != S_IDLE && state != S_LOAD_SRAM);
  assign frame_done  = clamp_done;
  assign pixel_valid = clamp_valid;
  assign pixel_out   = clamp_pixel;

  // -------------------------------------------------------------
  // 5. SRAM Macro Instantiation
  // -------------------------------------------------------------
  sram_1024x16 u_sram_macro (
    .clk   (clk),
    .cen   (sram_cen),
    .wen   (sram_wen),
    .addr  (sram_addr),
    .d_in  (sram_din),
    .d_out (sram_dout)
  );

  // -------------------------------------------------------------
  // 6. Weight Loading & Coordinate Scan State Machine
  // -------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      cfg_ptr      <= 10'd0;
      r_cnt        <= 10'd0;
      c_cnt        <= 10'd0;
      flush_cnt    <= 10'd0;
      engine_start <= 1'b0;
    end else begin
      state <= next_state;

      case (state)
        S_IDLE: begin
          cfg_ptr      <= 10'd0;
          r_cnt        <= 10'd0;
          c_cnt        <= 10'd0;
          flush_cnt    <= 10'd0;
          engine_start <= 1'b0;
        end

        S_LOAD_W1X: begin
          w1_x_mem[cfg_ptr] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        S_LOAD_W1Y: begin
          w1_y_mem[cfg_ptr - 10'd64] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        S_LOAD_B1: begin
          b1_mem[cfg_ptr - 10'd128] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        S_LOAD_W2: begin
          w2_mem[cfg_ptr - 10'd192] <= sram_dout;
          cfg_ptr <= cfg_ptr + 1'b1;
        end

        S_LOAD_B2: begin
          b2_bias <= sram_dout;
          cfg_ptr <= 10'd0;
        end

        S_RUN_RASTER: begin
          if (!engine_busy && (r_cnt < 32)) begin
            engine_start <= 1'b1;
            // Q4.12 fixed-point linear coordinates mapping [-1.0, 1.0] across 32 steps
            x_coord <= -16'sd4096 + 16'(signed'((c_cnt * 16'sd8192) / 16'sd31));
            y_coord <= -16'sd4096 + 16'(signed'((r_cnt * 16'sd8192) / 16'sd31));

            if (c_cnt == 31) begin
              c_cnt <= 10'd0;
              r_cnt <= r_cnt + 1'b1;
            end else begin
              c_cnt <= c_cnt + 1'b1;
            end
          end else if (r_cnt >= 32 && !clamp_done) begin
            // Automatic pipeline drain
            engine_start <= ~engine_busy;
            x_coord      <= 16'sh1000;
            y_coord      <= 16'sh1000;
            if (raw_valid) flush_cnt <= flush_cnt + 1'b1;
          end else begin
            engine_start <= 1'b0;
          end
        end

        default: ;
      endcase
    end
  end

  // Next State Logic
  always_comb begin
    next_state = state;
    case (state)
      S_IDLE: begin
        if (!mode_sel)
          next_state = S_LOAD_SRAM;
        else if (start)
          next_state = S_LOAD_W1X;
      end
      S_LOAD_SRAM: if (mode_sel) next_state = S_IDLE;
      S_LOAD_W1X:  if (cfg_ptr == 10'd63)  next_state = S_LOAD_W1Y;
      S_LOAD_W1Y:  if (cfg_ptr == 10'd127) next_state = S_LOAD_B1;
      S_LOAD_B1:   if (cfg_ptr == 10'd191) next_state = S_LOAD_W2;
      S_LOAD_W2:   if (cfg_ptr == 10'd255) next_state = S_LOAD_B2;
      S_LOAD_B2:   next_state = S_RUN_RASTER;
      S_RUN_RASTER:if (clamp_done) next_state = S_IDLE;
      default:     next_state = S_IDLE;
    endcase
  end

  // -------------------------------------------------------------
  // 7. Core Compute Engine Instances (Unchanged)
  // -------------------------------------------------------------
  siren_block_engine #(
    .TOTAL_NEURONS (TOTAL_NEURONS),
    .BLOCK_SIZE    (BLOCK_SIZE)
  ) u_engine (
    .clk             (clk),
    .rst_in          (rst_n),
    .start_eval      (engine_start),
    .coord_x         (x_coord),
    .coord_y         (y_coord),
    .w1_x_mem        (w1_x_mem),
    .w1_y_mem        (w1_y_mem),
    .b1_mem          (b1_mem),
    .w2_mem          (w2_mem),
    .b2_bias         (b2_bias),
    .busy            (engine_busy),
    .pixel_valid_out (raw_valid),
    .pixel_out       (raw_pixel)
  );

  siren_sharpen u_sharpen (
    .clk         (clk),
    .rst_in      (rst_n),
    .data_in     (raw_pixel),
    .valid_in    (raw_valid),
    .pixel_valid (sharp_valid),
    .pixel_out   (sharp_pixel),
    .frame_done  (sharp_done)
  );

  siren_clamp u_clamp (
    .clk         (clk),
    .rst_in      (rst_n),
    .valid_in    (sharp_valid),
    .data_in     (sharp_pixel),
    .valid_out   (clamp_valid),
    .data_out    (clamp_pixel),
    .frame_done  (clamp_done)
  );

endmodule
