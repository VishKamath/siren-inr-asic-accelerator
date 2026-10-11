`timescale 1ns/1ps

module siren_sharpen
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

  output logic                         pixel_valid,
  output logic signed [DATA_WIDTH-1:0] pixel_out,
  output logic                         frame_done
);

  localparam int TOTAL_PIXELS = IMG_WIDTH * IMG_HEIGHT;

  // -------------------------------------------------------------------------
  // Line Buffers & Window
  // -------------------------------------------------------------------------
  logic signed [DATA_WIDTH-1:0] line_buf_0 [0:IMG_WIDTH-1];
  logic signed [DATA_WIDTH-1:0] line_buf_1 [0:IMG_WIDTH-1];
  logic signed [DATA_WIDTH-1:0] win [0:2][0:2];

  // Pipeline tracking
  integer in_cnt;
  integer out_cnt;
  integer out_col;
  integer out_row;

  // Noise Coring Deadband (~0.039 * 4096 = 160)
  localparam signed [19:0] NOISE_CORE_THRESH = 20'sd160;

  logic signed [19:0] neighbor_sum;
  logic signed [19:0] center_scaled;
  logic signed [19:0] laplacian_delta;
  logic signed [19:0] cored_delta;
  logic signed [17:0] sharp_extended;
  logic signed [DATA_WIDTH-1:0] sharp_pixel_comb;
  logic               is_border;

  // -------------------------------------------------------------------------
  // Buffer FIFO Shift & 3x3 Window Update
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      in_cnt <= 0;
      for (int i = 0; i < IMG_WIDTH; i++) begin
        line_buf_0[i] <= 16'sh0000;
        line_buf_1[i] <= 16'sh0000;
      end
      for (int r = 0; r < 3; r++) begin
        for (int c = 0; c < 3; c++) begin
          win[r][c] <= 16'sh0000;
        end
      end
    end else if (valid_in) begin
      // Window update
      win[0][0] <= win[0][1];
      win[0][1] <= win[0][2];
      win[0][2] <= line_buf_1[IMG_WIDTH-1];

      win[1][0] <= win[1][1];
      win[1][1] <= win[1][2];
      win[1][2] <= line_buf_0[IMG_WIDTH-1];

      win[2][0] <= win[2][1];
      win[2][1] <= win[2][2];
      win[2][2] <= data_in;

      // Line buffer update
      for (int i = IMG_WIDTH-1; i > 0; i--) begin
        line_buf_1[i] <= line_buf_1[i-1];
        line_buf_0[i] <= line_buf_0[i-1];
      end
      line_buf_1[0] <= line_buf_0[IMG_WIDTH-1];
      line_buf_0[0] <= data_in;

      in_cnt <= in_cnt + 1;
    end
  end

  // -------------------------------------------------------------------------
  // Combinational Noise-Cored Laplacian Computation
  // -------------------------------------------------------------------------
  always_comb begin
    is_border = (out_row == 0) || (out_row == IMG_HEIGHT - 1) ||
                (out_col == 0) || (out_col == IMG_WIDTH - 1);

    neighbor_sum = 20'(signed'(win[0][0])) + 20'(signed'(win[0][1])) + 20'(signed'(win[0][2])) +
                   20'(signed'(win[1][0]))                            + 20'(signed'(win[1][2])) +
                   20'(signed'(win[2][0])) + 20'(signed'(win[2][1])) + 20'(signed'(win[2][2]));

    center_scaled   = 20'(signed'(win[1][1])) <<< 3;
    laplacian_delta = center_scaled - neighbor_sum;

    if (laplacian_delta > NOISE_CORE_THRESH) begin
      cored_delta = laplacian_delta - NOISE_CORE_THRESH;
    end else if (laplacian_delta < -NOISE_CORE_THRESH) begin
      cored_delta = laplacian_delta + NOISE_CORE_THRESH;
    end else begin
      cored_delta = 20'sd0;
    end

    if (is_border) begin
      sharp_extended = 18'(signed'(win[1][1]));
    end else begin
      sharp_extended = 18'(signed'(win[1][1])) + 18'(signed'(cored_delta >>> 4));
    end

    if (sharp_extended < 18'sd0) begin
      sharp_pixel_comb = 16'sh0000;
    end else if (sharp_extended > 18'sd4096) begin
      sharp_pixel_comb = 16'sh1000;
    end else begin
      sharp_pixel_comb = 16'(sharp_extended);
    end
  end

  // -------------------------------------------------------------------------
  // Output Pipeline & Coordinate Alignment
  // -------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_in) begin
    if (!rst_in) begin
      pixel_valid <= 1'b0;
      pixel_out   <= 16'sh0000;
      out_cnt     <= 0;
      out_col     <= 0;
      out_row     <= 0;
      frame_done  <= 1'b0;
    end else begin
      if (valid_in && (in_cnt >= (IMG_WIDTH + 2))) begin
        if (out_cnt < TOTAL_PIXELS) begin
          pixel_valid <= 1'b1;
          pixel_out   <= sharp_pixel_comb;
          out_cnt     <= out_cnt + 1;
          frame_done  <= (out_cnt == TOTAL_PIXELS - 1);

          if (out_col == IMG_WIDTH - 1) begin
            out_col <= 0;
            out_row <= out_row + 1;
          end else begin
            out_col <= out_col + 1;
          end
        end else begin
          pixel_valid <= 1'b0;
          frame_done  <= 1'b0;
        end
      end else begin
        pixel_valid <= 1'b0;
        frame_done  <= 1'b0;
      end
    end
  end

endmodule
