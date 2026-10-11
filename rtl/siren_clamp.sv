`timescale 1ns/1ps

module siren_clamp
#(
  parameter int IMG_WIDTH  = 32,
  parameter int IMG_HEIGHT = 32,
  parameter int DATA_WIDTH = 16
)
(
  input  logic                         clk,
  input  logic                         rst_in,
  input  logic                         valid_in,
  input  logic signed [DATA_WIDTH-1:0] data_in,

  output logic                         valid_out,
  output logic signed [DATA_WIDTH-1:0] data_out,
  output logic                         frame_done
);

  localparam int TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

  // -------------------------------------------------------------------------
  // Registers & Pipeline Tracking
  // -------------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] px_stage1;
  logic                         valid_stage1;
  integer                       out_pixel_cnt;

  // Rail thresholds (Q4.12 representation)
  // 0.015 * 4096 ~= 16'sh0040 (suppress baseline negative ringing)
  // 0.985 * 4096 ~= 16'sh0FC0 (clamp full-rail overflow)
  localparam signed [DATA_WIDTH-1:0] THRESH_DARK   = 16'sh0040;
  localparam signed [DATA_WIDTH-1:0] THRESH_BRIGHT = 16'sh0FC0;

  // Arithmetic signals
  logic signed [DATA_WIDTH:0]   px_ext;
  logic signed [DATA_WIDTH:0]   boosted_val;
  logic signed [DATA_WIDTH-1:0] remapped_val;

  // -------------------------------------------------------------------------
  // Stage 1: Input Registration
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      px_stage1    <= 16'sh0000;
      valid_stage1 <= 1'b0;
    end else begin
      valid_stage1 <= valid_in;
      if (valid_in) begin
        px_stage1 <= data_in;
      end
    end
  end

  // -------------------------------------------------------------------------
  // Stage 2: Adaptive Clamping & Linear Passthrough Combinational Logic
  // -------------------------------------------------------------------------
  always_comb begin
    px_ext      = 17'(signed'(px_stage1));
    boosted_val = px_ext; // Linear passthrough: preserves IC discrete gray plateaus

    if (px_stage1 < THRESH_DARK) begin
      remapped_val = 16'sh0000; // Snap negative/dark ringing cleanly to 0.0
    end else if (px_stage1 > THRESH_BRIGHT) begin
      remapped_val = 16'sh1000; // Snap overshoot cleanly to 1.0 (Q4.12: 4096)
    end else begin
      // Strict Q4.12 bounding [0.0, 1.0]
      if (boosted_val < 17'sd0)
        remapped_val = 16'sh0000;
      else if (boosted_val > 17'sd4096)
        remapped_val = 16'sh1000;
      else
        remapped_val = 16'(boosted_val);
    end
  end

  // -------------------------------------------------------------------------
  // Stage 3: Output Registration
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      valid_out     <= 1'b0;
      data_out      <= 16'sh0000;
      out_pixel_cnt <= 0;
      frame_done    <= 1'b0;
    end else begin
      if (valid_stage1) begin
        valid_out     <= 1'b1;
        data_out      <= remapped_val;
        out_pixel_cnt <= out_pixel_cnt + 1;
        frame_done    <= (out_pixel_cnt == TOTAL_PIXELS - 1);
      end else begin
        valid_out  <= 1'b0;
        frame_done <= 1'b0;
      end
    end
  end

endmodule
