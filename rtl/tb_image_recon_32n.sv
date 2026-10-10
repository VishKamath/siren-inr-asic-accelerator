`timescale 1ns/1ps
import inr_pkg::*;

module tb_image_recon_32n;

    localparam int NUM_NEURONS  = 32;
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

    // Memory Arrays
    logic signed [15:0] coords_mem [0:2047];
    logic signed [15:0] l1_w_mem   [0:(NUM_NEURONS*2)-1];
    logic signed [15:0] l1_b_mem   [0:NUM_NEURONS-1];
    logic signed [15:0] l2_w_mem   [0:NUM_NEURONS-1];
    logic signed [15:0] l2_b_mem   [0:0];

    // File Descriptors and Counters
    int raw_file;
    int sharp_file;
    int raw_pixels_received;
    int sharp_pixels_received;

    // -------------------------------------------------------------------------
    // 1. SIREN INR Neural Compute Engine
    // -------------------------------------------------------------------------
    siren_network #(.NUM_NEURONS(NUM_NEURONS)) dut_siren (
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

    // -------------------------------------------------------------------------
    // Clock Generator: 100 MHz (10 ns)
    // -------------------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // -------------------------------------------------------------------------
    // Monitor Process: Capture Raw & Sharpened Output Streams
    // -------------------------------------------------------------------------
    initial begin
        raw_pixels_received   = 0;
        sharp_pixels_received = 0;

        raw_file = $fopen("sim/out_pixels_raw.hex", "w");
        sharp_file = $fopen("sim/out_pixels_sharpened.hex", "w");

        if (!raw_file || !sharp_file) begin
            $display("[ERROR] Could not open output hex files for writing!");
            $finish;
        end

        // Fork parallel collection for both output streams
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

            // Collector 2: Sharpened post-processed stream
            forever @(posedge clk) begin
                if (sharp_pixel_valid) begin
                    $fdisplay(sharp_file, "%h", sharp_pixel_out);
                    sharp_pixels_received++;
                    if (sharp_pixels_received % 128 == 0) begin
                        $display("[SHARPENED] Filtered %0d / %0d pixels...", sharp_pixels_received, TOTAL_PIXELS);
                    end
                end
            end

            // Wait for Sharpening Filter to finish flush and pulse frame_done
            begin
                @(posedge sharp_frame_done);
                $display("\n=======================================================");
                $display("[SUCCESS] Complete Pipeline Finished!");
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

    // -------------------------------------------------------------------------
    // Stimulus Process: Coordinate & Weight Streaming
    // -------------------------------------------------------------------------
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

        for (int i = 0; i < NUM_NEURONS; i++) begin
            l1_bias_in[i] = l1_b_mem[i];
            l2_w_in[i]    = l2_w_mem[i];
        end
        l2_bias_in = l2_b_mem[0];

        #25;
        rst_in = 1'b0; // Active low reset asserted
        #20;
        rst_in = 1'b1; // De-asserted
        @(posedge clk);

        $display("[SIM START] Streaming %0d coordinate pairs into SIREN + Sharpening Pipeline...", TOTAL_PIXELS);

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

            // De-assert and allow compute engine to evaluate coordinate
            @(posedge clk);
            valid_in <= 1'b0;
            clr_acc  <= 1'b0;

            // Wait until this pixel is evaluated before starting the next
            @(posedge pixel_valid_out);
        end

        $display("[SIM INFO] All coordinates fed. Waiting for filter pipeline to flush...");
    end

endmodule
