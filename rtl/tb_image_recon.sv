`timescale 1ns/1ps
import inr_pkg::*;

module tb_image_recon #(
    parameter int IMG_SIZE     = 32,
    parameter int TOTAL_PIXELS = 1024,
    parameter int CLK_PERIOD   = 10
);

    logic clk;
    logic rst_in;
    logic valid_in;
    logic clr_acc;
    logic signed [15:0] a_in;
    logic signed [15:0] w_in;
    logic signed [15:0] bias_in;

    logic [15:0] weight_mem [0:2];
    logic [15:0] coord_mem  [0:(TOTAL_PIXELS*2)-1];

    logic valid_out;
    logic signed [15:0] act_out;
    logic signed [15:0] cos_out;

    siren_neuron dut (
        .clk       (clk),
        .rst_in    (rst_in),
        .valid_in  (valid_in),
        .clr_acc   (clr_acc),
        .a_in      (a_in),
        .w_in      (w_in),
        .bias_in   (bias_in),
        .valid_out (valid_out),
        .act_out   (act_out),
        .cos_out   (cos_out)
    );

    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    integer fd;
    integer out_count = 0;

    initial fd = $fopen("out_pixels.hex", "w");

    always @(posedge clk) begin
        if (rst_in && valid_out) begin
            $fdisplay(fd, "%04h", act_out);
            out_count <= out_count + 1;
        end
    end

    initial begin
        valid_in = 1'b0;
        clr_acc  = 1'b0;
        a_in     = 16'sh0;
        w_in     = 16'sh0;
        bias_in  = 16'sh0;

        $readmemh("weights.hex", weight_mem);
        $readmemh("coords.hex", coord_mem);

        // Active-low reset
        rst_in = 1'b0;
        #(CLK_PERIOD * 4);
        @(negedge clk);
        rst_in = 1'b1;
        #(CLK_PERIOD * 2);

        bias_in = weight_mem[2];

        // Feed each coordinate pair (X then Y)
        for (int p = 0; p < TOTAL_PIXELS; p++) begin
            @(negedge clk);
            valid_in = 1'b1;
            clr_acc  = 1'b1;
            a_in     = coord_mem[2*p];
            w_in     = weight_mem[0];

            @(negedge clk);
            valid_in = 1'b1;
            clr_acc  = 1'b0;
            a_in     = coord_mem[2*p+1];
            w_in     = weight_mem[1];
        end

        @(negedge clk);
        valid_in = 1'b0;
        clr_acc  = 1'b0;

        // Drain until all 1024 pixels are written
        wait (out_count >= TOTAL_PIXELS);
        @(posedge clk);
        $fclose(fd);
        $display("[+] Image reconstruction complete. Output saved to out_pixels.hex");
        $finish;
    end


always @(posedge clk) begin
    if (dut.valid_in || dut.wire_mac || dut.wire_scaler || dut.valid_out) begin
        $display("T=%0t | in_v=%b clr=%b a=%d w=%d | mac_v=%b mac_out=%d | scale_v=%b scale_out=%d | out_v=%b act_out=%h",
                 $time, dut.valid_in, dut.clr_acc, dut.a_in, dut.w_in, 
                 dut.wire_mac, dut.mac_result, 
                 dut.wire_scaler, dut.scaled_result, 
                 dut.valid_out, dut.act_out);
    end
end

endmodule
