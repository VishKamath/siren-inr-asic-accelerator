`timescale 1ns/1ps
import inr_pkg::*;

module tb_siren_block_engine;

  localparam int TOTAL_NEURONS = 64;
  localparam int BLOCK_SIZE    = 4;

  logic               clk;
  logic               rst_n;
  logic               start;
  logic signed [15:0] x_coord;
  logic signed [15:0] y_coord;
  logic               busy;

  logic signed [15:0] w1_x_mem [0:TOTAL_NEURONS-1];
  logic signed [15:0] w1_y_mem [0:TOTAL_NEURONS-1];
  logic signed [15:0] b1_mem   [0:TOTAL_NEURONS-1];
  logic signed [15:0] w2_mem   [0:TOTAL_NEURONS-1];
  logic signed [15:0] b2_mem   [0:0];
  logic signed [15:0] b2_bias;

  logic               pixel_valid_raw;
  logic signed [15:0] pixel_out_raw;

  logic               sharp_valid_w;
  logic signed [15:0] sharp_pixel_w;
  logic               sharp_frame_done_w;

  logic               clamp_valid_w;
  logic signed [15:0] clamp_pixel_w;
  logic               clamp_frame_done_w;

  // DUT Stage 1
  siren_block_engine #(
    .TOTAL_NEURONS (TOTAL_NEURONS),
    .BLOCK_SIZE    (BLOCK_SIZE)
  ) u_engine (
    .clk             (clk),
    .rst_in          (rst_n),
    .start_eval      (start),
    .coord_x         (x_coord),
    .coord_y         (y_coord),
    .w1_x_mem        (w1_x_mem),
    .w1_y_mem        (w1_y_mem),
    .b1_mem          (b1_mem),
    .w2_mem          (w2_mem),
    .b2_bias         (b2_bias),
    .busy            (busy),
    .pixel_valid_out (pixel_valid_raw),
    .pixel_out       (pixel_out_raw)
  );

  // DUT Stage 2
  siren_sharpen u_sharpen (
    .clk         (clk),
    .rst_in      (rst_n),
    .data_in     (pixel_out_raw),
    .valid_in    (pixel_valid_raw),
    .pixel_valid (sharp_valid_w),
    .pixel_out   (sharp_pixel_w),
    .frame_done  (sharp_frame_done_w)
  );

  // DUT Stage 3
  siren_clamp u_clamp (
    .clk         (clk),
    .rst_in      (rst_n),
    .valid_in    (sharp_valid_w),
    .data_in     (sharp_pixel_w),
    .valid_out   (clamp_valid_w),
    .data_out    (clamp_pixel_w),
    .frame_done  (clamp_frame_done_w)
  );

  // 50 MHz Clock
  initial begin
    clk = 1'b0;
    forever #10 clk = ~clk;
  end

  // Pixel loggers
  integer f_raw, f_sharp, f_clamp;
  integer raw_cnt, sharp_cnt, clamp_cnt;

  initial begin
    f_raw     = $fopen("raw_pixels.txt", "w");
    f_sharp   = $fopen("sharpened_pixels.txt", "w");
    f_clamp   = $fopen("clamped_pixels.txt", "w");
    raw_cnt   = 0;
    sharp_cnt = 0;
    clamp_cnt = 0;
  end

  always @(posedge clk) begin
    if (pixel_valid_raw && raw_cnt < 1024) begin
      $fwrite(f_raw, "%d\n", pixel_out_raw);
      raw_cnt = raw_cnt + 1;
    end
    if (sharp_valid_w && sharp_cnt < 1024) begin
      $fwrite(f_sharp, "%d\n", sharp_pixel_w);
      sharp_cnt = sharp_cnt + 1;
    end
    if (clamp_valid_w && clamp_cnt < 1024) begin
      $fwrite(f_clamp, "%d\n", clamp_pixel_w);
      clamp_cnt = clamp_cnt + 1;
    end
  end

  // Weight Memory Loading
  initial begin
    for (int i = 0; i < TOTAL_NEURONS; i++) begin
      w1_x_mem[i] = 16'sh0000;
      w1_y_mem[i] = 16'sh0000;
      b1_mem[i]   = 16'sh0000;
      w2_mem[i]   = 16'sh0000;
    end
    b2_mem[0] = 16'sh0000;

    $readmemh("sim/layer1_weights_x.hex", w1_x_mem);
    $readmemh("sim/layer1_weights_y.hex", w1_y_mem);
    $readmemh("sim/layer1_biases.hex",    b1_mem);
    $readmemh("sim/layer2_weights.hex",   w2_mem);
    $readmemh("sim/layer2_bias.hex",      b2_mem);
    b2_bias = b2_mem[0];
  end

  // Stimulus & Flush Execution
  real x_real, y_real;
  integer r, c;

  initial begin
    rst_n   = 1'b0;
    start   = 1'b0;
    x_coord = 16'sd0;
    y_coord = 16'sd0;

    #100;
    rst_n = 1'b1;
    #40;

    $display("[TB] Starting 32x32 Raster Scan through siren_block_engine...");

    for (r = 0; r < 32; r = r + 1) begin
      for (c = 0; c < 32; c = c + 1) begin
        y_real = -1.0 + (real'(r) / 31.0) * 2.0;
        x_real = -1.0 + (real'(c) / 31.0) * 2.0;

        @(posedge clk);
        x_coord <= 16'(signed'(integer'(x_real * 4096.0)));
        y_coord <= 16'(signed'(integer'(y_real * 4096.0)));
        start   <= 1'b1;

        @(posedge clk);
        start <= 1'b0;

        wait (pixel_valid_raw == 1'b1);
      end
    end

    $display("[TB] 1024 coordinates injected. Flushing pipeline...");

    // Send flush coordinates to drain the remaining 33 line-buffer latency cycles
    while (clamp_cnt < 1024) begin
      @(posedge clk);
      if (!busy) begin
        start   <= 1'b1;
        x_coord <= 16'sh1000;
        y_coord <= 16'sh1000;
        @(posedge clk);
        start <= 1'b0;
        wait (pixel_valid_raw == 1'b1);
      end
    end

    #200;

    $fclose(f_raw);
    $fclose(f_sharp);
    $fclose(f_clamp);

    $display("[TB] Final Capture Summary -> Raw: %0d | Sharpened: %0d | Clamped: %0d", 
             raw_cnt, sharp_cnt, clamp_cnt);
    $display("[TB] Simulation completed successfully.");
    $finish;
  end

endmodule
