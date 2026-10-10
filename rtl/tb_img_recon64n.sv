`timescale 1ns/1ps
import inr_pkg::*;

module tb_image_recon64n;

    localparam int NUM_NEURONS  = 64;
    localparam int TOTAL_PIXELS = 1024;

    logic clk;
    logic rst_in;
    logic valid_in;
    logic clr_acc;

    logic signed [15:0] a_in;
    logic signed [15:0] l1_w_in    [0:NUM_NEURONS-1];
    logic signed [15:0] l1_bias_in [0:NUM_NEURONS-1];
    logic signed [15:0] l2_w_in    [0:NUM_NEURONS-1];
    logic signed [15:0] l2_bias_in;

    // SIREN Network Raw Outputs
    logic               pixel_valid_out;
    logic signed [15:0] pixel_out;

    // Sharpen Filter Outputs
    logic               sharp_pixel_valid;
    logic signed [15:0] sharp_pixel_out;
    logic               sharp_frame_done;

    // Memory Arrays (64 Neurons)
    logic signed [15:0] coords_mem [0:2047];
    logic signed [15:0] l1_w_mem   [0:(NUM_NEURONS*2)-1]; // 128 words
    logic signed [15:0] l1_b_mem   [0:NUM_NEURONS-1];     // 64 words
    logic signed [15:0] l2_w_mem   [0:NUM_NEURONS-1];     // 64 words
    logic signed [15:0] l2_b_mem   [0:0];

    int raw_file;
    int sharp_file;
    int raw_pixels_received;
    int sharp_pixels_received;

    // -------------------------------------------------------------------------
    // 1. SIREN INR Neural Engine (64 Neurons)
    // -------------------------------------------------------------------------
    siren_network_nVIIV #(.NUM_NEURONS(NUM_NEURONS)) dut (
        .clk             (clk),
        .rst_in          (rst_in),
        .valid_in        (valid_in),
        .clr_acc         (clr_acc),
        .a_in            (a_in),
        .l1_w_in         (l1_w_in),
        .l1_bias_in      (l1_bias_in),
        .l2_w_in         (l2_w_in),
        .l2_bias_in      (l2_bias_in),
        .pixel_valid_out (pixel_valid_out),
        .pixel_out       (pixel_out)
    );

    // -------------------------------------------------------------------------
    // 2. Hardware Post-Processing Sharpening Filter
    // -------------------------------------------------------------------------
    siren_sharpen dut_sharpen (
        .clk         (clk),
        .rst_in      (rst_in),
        .data_in     (pixel_out),
        .valid_in    (pixel_valid_out),
        .pixel_valid (sharp_pixel_valid),
        .pixel_out   (sharp_pixel_out),
        .frame_done  (sharp_frame_done)
    );

    // Clock Generator: 100 MHz (10 ns period)
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // Monitor: Record both Raw and Sharpened pixel streams
    initial begin
        raw_pixels_received   = 0;
        sharp_pixels_received = 0;

        raw_file   = $fopen("sim/out_pixels_raw.hex", "w");
        sharp_file = $fopen("sim/out_pixels_sharpened.hex", "w");

        if (!raw_file || !sharp_file) begin
            $display("[ERROR] Could not open output hex files for writing!");
            $finish;
        end

        fork
            // Collector 1: Raw SIREN stream
            forever @(posedge clk) begin
                if (pixel_valid_out) begin
                    $fdisplay(raw_file, "%h", pixel_out);
                    raw_pixels_received++;
                    if (raw_pixels_received % 128 == 0) begin
                        $display("[SIREN RAW] Processed %0d / %0d pixels...", raw_pixels_received, TOTAL_PIXELS);
                    end
                end
            end

            // Collector 2: Sharpened output stream
            forever @(posedge clk) begin
                if (sharp_pixel_valid) begin
                    $fdisplay(sharp_file, "%h", sharp_pixel_out);
                    sharp_pixels_received++;
                    if (sharp_pixels_received % 128 == 0) begin
                        $display("[SHARPENED] Filtered %0d / %0d pixels...", sharp_pixels_received, TOTAL_PIXELS);
                    end
                end
            end

            // Wait for Sharpen filter to drain remaining pixels
            begin
                @(posedge sharp_frame_done);
                $display("\n=======================================================");
                $display("[SUCCESS] 64-Neuron Pipeline Finished!");
                $display("Raw Pixels Emitted       : %0d / %0d", raw_pixels_received, TOTAL_PIXELS);
                $display("Sharpened Pixels Emitted : %0d / %0d", sharp_pixels_received, TOTAL_PIXELS);
                $display("=======================================================\n");

                $fclose(raw_file);
                $fclose(sharp_file);
                #100;
                $finish;
            end
        join
    end

    // Stimulus Process
    initial begin
        rst_in   = 1'b1; 
        valid_in = 1'b0;
        clr_acc  = 1'b0;
        a_in     = 16'sh0;

        $readmemh("sim/coords.hex",         coords_mem);
        $readmemh("sim/layer1_weights.hex", l1_w_mem);
        $readmemh("sim/layer1_biases.hex",  l1_b_mem);
        $readmemh("sim/layer2_weights.hex", l2_w_mem);
        $readmemh("sim/layer2_bias.hex",    l2_b_mem);

        $display("[TB CHECK] NUM_NEURONS = %0d | L1 Weight 0: %h | L1 Weight 127: %h", 
                 NUM_NEURONS, l1_w_mem[0], l1_w_mem[127]);

        for (int i = 0; i < NUM_NEURONS; i++) begin
            l1_bias_in[i] = l1_b_mem[i];
            l2_w_in[i]    = l2_w_mem[i];
        end
        l2_bias_in = l2_b_mem[0];

        #25;
        rst_in = 1'b0; 
        #20;
        rst_in = 1'b1; 
        @(posedge clk);

        $display("[SIM START] Streaming %0d coordinate pairs into %0d-neuron SIREN...", TOTAL_PIXELS, NUM_NEURONS);

        for (int p = 0; p < TOTAL_PIXELS; p++) begin
            // Coordinate X
            @(posedge clk);
            valid_in <= 1'b1;
            clr_acc  <= 1'b1; 
            a_in     <= coords_mem[2*p];
            for (int n = 0; n < NUM_NEURONS; n++) begin
                l1_w_in[n] <= l1_w_mem[2*n];     
            end

            // Coordinate Y
            @(posedge clk);
            valid_in <= 1'b1;
            clr_acc  <= 1'b0; 
            a_in     <= coords_mem[2*p + 1];
            for (int n = 0; n < NUM_NEURONS; n++) begin
                l1_w_in[n] <= l1_w_mem[2*n + 1]; 
            end

            // Deassert and wait for coordinate evaluation
            @(posedge clk);
            valid_in <= 1'b0;
            clr_acc  <= 1'b0;
            a_in     <= 16'sh0;

            @(posedge pixel_valid_out);
        end
    end

endmodule
