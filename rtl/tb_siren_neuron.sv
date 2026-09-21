`timescale 1ns/1ps
import inr_pkg::*;

module tb_siren_neuron;
    logic clk;
    logic rst_in;
    logic valid_in;
    logic clr_acc;
    logic signed [ACT_WIDTH-1:0] a_in;
    logic signed [ACT_WIDTH-1:0] w_in;
    logic signed [ACT_WIDTH-1:0] bias_in;
    logic valid_out;
    logic signed [ACT_WIDTH-1:0] act_out;
    logic signed [ACT_WIDTH-1:0] cos_out;

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

    always #5 clk = ~clk;

    initial begin 
        $dumpfile("tb_siren_neuron.vcd");
        $dumpvars(0, tb_siren_neuron);
    end

    always @(posedge clk) begin 
        if (rst_in && valid_out) begin 
            $display("Time: %0t | act_out: %f | cos_out: %f", 
                     $time, 
                     (act_out * 1.0) / 4096.0, 
                     (cos_out * 1.0) / 4096.0);
        end
    end

    // Drives one active clock cycle of data
    task drive_sample(
        input logic clear,
        input logic signed [ACT_WIDTH-1:0] a,
        input logic signed [ACT_WIDTH-1:0] w,
        input logic signed [ACT_WIDTH-1:0] b
    );
    begin 
        @(posedge clk);
        valid_in <= 1'b1;
        clr_acc  <= clear;
        a_in     <= a;
        w_in     <= w;
        bias_in  <= b;
    end
    endtask

    // Terminates the active burst
    task finish_drive;
    begin
        @(posedge clk);
        valid_in <= 1'b0;
        clr_acc  <= 1'b0;
    end
    endtask

    initial begin 
        clk      = 0;
        rst_in   = 0;
        valid_in = 0;
        clr_acc  = 0;
        a_in     = '0;
        w_in     = '0;
        bias_in  = '0;
        
        #20; rst_in = 1;
        #20;

        // Test 1: Single sample (Zero check)
        drive_sample(1'b1, 16'h0000, 16'h0800, 16'h0000);
        finish_drive();

        #40;

        // Test 2: Two-cycle accumulation (0.25*0.5 + 0.25*0.5 = 0.25)
        // Cycle 1: load bias + first product
        drive_sample(1'b1, 16'h0400, 16'h0800, 16'h0000); 
        // Cycle 2: accumulate second product
        drive_sample(1'b0, 16'h0400, 16'h0800, 16'h0000); 
        finish_drive();

        #500;
        $finish;
    end

endmodule
