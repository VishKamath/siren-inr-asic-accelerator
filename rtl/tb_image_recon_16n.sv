`timescale 1ns/1ps
import inr_pkg::*;

module tb_image_recon_16n;

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

    logic               pixel_valid_out;
    logic signed [15:0] pixel_out;

    logic signed [15:0] coords_mem [0:2047];
    logic signed [15:0] l1_w_mem   [0:(NUM_NEURONS*2)-1];
    logic signed [15:0] l1_b_mem   [0:NUM_NEURONS-1];
    logic signed [15:0] l2_w_mem   [0:NUM_NEURONS-1];
    logic signed [15:0] l2_b_mem   [0:0];

    int out_file;
    int pixels_received;

    siren_network #(.NUM_NEURONS(NUM_NEURONS)) dut (
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

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    initial begin
        pixels_received = 0;
        out_file = $fopen("sim/out_pixels.hex", "w");
        if (!out_file) begin
            $display("[ERROR] Could not open sim/out_pixels.hex for writing!");
            $finish;
        end

        forever @(posedge clk) begin
            if (pixel_valid_out) begin
                $fdisplay(out_file, "%h", pixel_out);
                pixels_received = pixels_received + 1;

                if (pixels_received % 128 == 0) begin
                    $display("[SIM INFO] Processed %0d / %0d pixels...", pixels_received, TOTAL_PIXELS);
                end

                if (pixels_received == TOTAL_PIXELS) begin
                    $display("[SUCCESS] All %0d pixels processed and captured.", TOTAL_PIXELS);
                    $fclose(out_file);
                    #20;
                    $finish;
                end
            end
        end
    end

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
        rst_in = 1'b0; 
        #20;
        rst_in = 1'b1; 
        @(posedge clk);

        $display("[SIM START] Streaming %0d coordinate pairs into 32-neuron SIREN...", TOTAL_PIXELS);

        for (int p = 0; p < TOTAL_PIXELS; p++) begin
            @(posedge clk);
            valid_in <= 1'b1;
            clr_acc  <= 1'b1; 
            a_in     <= coords_mem[2*p];
            for (int n = 0; n < NUM_NEURONS; n++) begin
                l1_w_in[n] <= l1_w_mem[2*n];     
            end

            @(posedge clk);
            valid_in <= 1'b1;
            clr_acc  <= 1'b0; 
            a_in     <= coords_mem[2*p + 1];
            for (int n = 0; n < NUM_NEURONS; n++) begin
                l1_w_in[n] <= l1_w_mem[2*n + 1]; 
            end
        end

        @(posedge clk);
        valid_in <= 1'b0;
        clr_acc  <= 1'b0;
        a_in     <= 16'sh0;

        #10000;
        $display("[TIMEOUT] Simulation finished before receiving all pixels.");
        $fclose(out_file);
        $finish;
    end

endmodule
