`timescale 1ns/1ps
import inr_pkg::*;

module tb_siren_block_engine64n;

  localparam int CLK_PERIOD    = 10;
  localparam int TOTAL_NEURONS = 64; // Scaled to 64
  localparam int BLOCK_SIZE    = 4;
  localparam int TOTAL_PIXELS  = 1024;

  logic clk;
  logic rst_in;
  logic start_eval;
  logic busy;
  logic raw_pixel_valid;

  logic signed [15:0] coord_x;
  logic signed [15:0] coord_y;
  logic signed [15:0] raw_pixel_out;

  // Sharpen signals
  logic               sharp_pixel_valid;
  logic signed [15:0] sharp_pixel_out;
  logic               sharp_frame_done;

  logic signed [15:0] w1_x_mem [0:TOTAL_NEURONS-1];
  logic signed [15:0] w1_y_mem [0:TOTAL_NEURONS-1];
  logic signed [15:0] b1_mem   [0:TOTAL_NEURONS-1];
  logic signed [15:0] w2_mem   [0:TOTAL_NEURONS-1];
  logic signed [15:0] b2_bias;

  logic [15:0] raw_w1     [0:(TOTAL_NEURONS*2)-1];
  logic [15:0] raw_coords [0:(TOTAL_PIXELS*2)-1];
  logic [15:0] raw_b2     [0:0];

  // 1. Folded Block Engine (64 Neurons / 4 Lanes = 16 Passes)
  siren_block_engine #(
    .TOTAL_NEURONS (TOTAL_NEURONS),
    .BLOCK_SIZE    (BLOCK_SIZE)
  ) dut_engine (
    .clk             (clk),
    .rst_in          (rst_in),
    .start_eval      (start_eval),
    .coord_x         (coord_x),
    .coord_y         (coord_y),
    .w1_x_mem        (w1_x_mem),
    .w1_y_mem        (w1_y_mem),
    .b1_mem          (b1_mem),
    .w2_mem          (w2_mem),
    .b2_bias         (b2_bias),
    .busy            (busy),
    .pixel_valid_out (raw_pixel_valid),
    .pixel_out       (raw_pixel_out)
  );

  // 2. Hardware Post-Processor (7C - 1.5Sum)
  siren_sharpen dut_sharpen (
    .clk         (clk),
    .rst_in      (rst_in),
    .data_in     (raw_pixel_out),
    .valid_in    (raw_pixel_valid),
    .pixel_valid (sharp_pixel_valid),
    .pixel_out   (sharp_pixel_out),
    .frame_done  (sharp_frame_done)
  );

  always #(CLK_PERIOD / 2) clk = ~clk;

  int raw_file, sharp_file;
  int raw_count, sharp_count;
  int wait_cycles;

  initial begin
    clk         = 1'b0;
    rst_in      = 1'b0;
    start_eval  = 1'b0;
    coord_x     = '0;
    coord_y     = '0;
    raw_count   = 0;
    sharp_count = 0;

    $readmemh("sim/layer1_weights.hex", raw_w1);
    $readmemh("sim/layer1_biases.hex",  b1_mem);
    $readmemh("sim/layer2_weights.hex", w2_mem);
    $readmemh("sim/layer2_bias.hex",    raw_b2);
    $readmemh("sim/coords.hex",         raw_coords);

    for (int n = 0; n < TOTAL_NEURONS; n++) begin
      w1_x_mem[n] = raw_w1[2*n];
      w1_y_mem[n] = raw_w1[2*n + 1];
    end
    b2_bias = raw_b2[0];

    raw_file   = $fopen("sim/out_pixels_raw.hex", "w");
    sharp_file = $fopen("sim/out_pixels_sharpened.hex", "w");
    if (!raw_file || !sharp_file) begin
      $display("[FATAL] Could not open output hex files!");
      $finish;
    end

    #(CLK_PERIOD * 5);
    rst_in = 1'b1;
    #(CLK_PERIOD * 2);

    $display("[TB] Starting evaluation of %0d pixels on 64-neuron folded block engine...", TOTAL_PIXELS);

    fork
      // Collector: Raw Pixels
      forever @(posedge clk) begin
        if (raw_pixel_valid) begin
          $fdisplay(raw_file, "%h", raw_pixel_out);
          raw_count++;
          if (raw_count % 128 == 0)
            $display("[RAW MONITOR] %0d / %0d pixels evaluated...", raw_count, TOTAL_PIXELS);
        end
      end

      // Collector: Sharpened Pixels
      forever @(posedge clk) begin
        if (sharp_pixel_valid) begin
          $fdisplay(sharp_file, "%h", sharp_pixel_out);
          sharp_count++;
          if (sharp_count % 128 == 0)
            $display("[SHARP MONITOR] %0d / %0d pixels filtered...", sharp_count, TOTAL_PIXELS);
        end
      end

      // Driver: Coordinate evaluation
      begin
        for (int p = 0; p < TOTAL_PIXELS; p++) begin
          coord_x = raw_coords[2*p];
          coord_y = raw_coords[2*p + 1];

          @(posedge clk);
          start_eval = 1'b1;
          @(posedge clk);
          start_eval = 1'b0;

          wait_cycles = 0;
          while (!raw_pixel_valid) begin
            @(posedge clk);
            wait_cycles++;
            if (wait_cycles > 400) begin
              $display("[TIMEOUT] Pixel %0d evaluation hung.", p);
              $finish;
            end
          end
          @(posedge clk);
        end

        // Wait for sharpening pipeline flush
        @(posedge sharp_frame_done);
        $display("\n=======================================================");
        $display("[SUCCESS] 64-Neuron Folded Pipeline Finished!");
        $display("Raw Pixels Emitted       : %0d / %0d", raw_count, TOTAL_PIXELS);
        $display("Sharpened Pixels Emitted : %0d / %0d", sharp_count, TOTAL_PIXELS);
        $display("=======================================================\n");

        $fclose(raw_file);
        $fclose(sharp_file);
        #100;
        $finish;
      end
    join
  end

endmodule
