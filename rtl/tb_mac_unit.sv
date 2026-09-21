`timescale 1ns/1ps

module tb_mac_unit;

    // Clock & Reset
    logic clk;
    logic rst_in;

    // DUT Inputs
    logic valid_in;
    logic clr_acc;
    logic signed [15:0] a_in;
    logic signed [15:0] w_in;
    logic signed [15:0] bias_in;

    // DUT Outputs
    logic valid_out;
    logic signed [15:0] acc_out;

    // Helper function: convert Q4.12 fixed-point integer to real for display
    function automatic real q4_12_to_real(input logic signed [15:0] val);
        return real'(val) / 4096.0;
    endfunction

    // Instantiate DUT
    mac_unit dut (
        .clk       (clk),
        .rst_in    (rst_in),
        .valid_in  (valid_in),
        .clr_acc   (clr_acc),
        .a_in      (a_in),
        .w_in      (w_in),
        .bias_in   (bias_in),
        .valid_out (valid_out),
        .acc_out   (acc_out)
    );

    // 100 MHz Clock (10ns period)
    always #5 clk = ~clk;

    // Monitor DUT outputs whenever valid_out is high
    always @(posedge clk) begin
        if (rst_in && valid_out) begin
            $display("[T=%0t ns] [OUT] acc_out = 0x%04h | Dec = %0d | Float = %0.4f", 
                     $time, acc_out, acc_out, q4_12_to_real(acc_out));
        end
    end

    // Task to drive one cycle of inputs
    task automatic drive_mac(
        input logic signed [15:0] a,
        input logic signed [15:0] w,
        input logic signed [15:0] b,
        input logic clr,
        input string desc
    );
        @(posedge clk);
        valid_in <= 1'b1;
        clr_acc  <= clr;
        a_in     <= a;
        w_in     <= w;
        bias_in  <= b;
        $display("\n--- %s ---", desc);
        $display("[T=%0t ns] [IN]  a=%0.4f (0x%04h), w=%0.4f (0x%04h), b=%0.4f (0x%04h), clr=%0b",
                 $time, q4_12_to_real(a), a, q4_12_to_real(w), w, q4_12_to_real(b), b, clr);
    endtask

    // Task for idle cycle
    task automatic drive_idle();
        @(posedge clk);
        valid_in <= 1'b0;
        clr_acc  <= 1'b0;
        a_in     <= 16'sh0;
        w_in     <= 16'sh0;
        bias_in  <= 16'sh0;
    endtask

    // Stimulus sequence
    initial begin
        // GTKWave trace generation
        $dumpfile("tb_mac_unit.vcd");
        $dumpvars(0, tb_mac_unit);

        // Initial state
        clk      = 0;
        rst_in   = 0;
        valid_in = 0;
        clr_acc  = 0;
        a_in     = 16'sh0;
        w_in     = 16'sh0;
        bias_in  = 16'sh0;

        // Reset phase
        #25;
        rst_in = 1;
        #10;

        // Test 1: First MAC cycle (a = 0.5, w = 2.0, b = 1.0, clr = 1)
        // Product = 1.0, Total = 1.0 + 1.0 = 2.0 (0x2000)
        drive_mac(16'sh0800, 16'sh2000, 16'sh1000, 1'b1, "Test 1: Fresh Init + Bias (0.5 * 2.0 + 1.0 = 2.0)");

        // Test 2: Accumulate (a = 0.25, w = 2.0, clr = 0)
        // Product = 0.5, Total = 2.0 + 0.5 = 2.5 (0x2800)
        drive_mac(16'sh0400, 16'sh2000, 16'sh0000, 1'b0, "Test 2: Accumulate (prev 2.0 + 0.25 * 2.0 = 2.5)");

        // Test 3: Negative multiplication (a = 1.0, w = -1.5, clr = 0)
        // Product = -1.5, Total = 2.5 - 1.5 = 1.0 (0x1000)
        drive_mac(16'sh1000, 16'shE800, 16'sh0000, 1'b0, "Test 3: Signed Multiply (prev 2.5 + 1.0 * -1.5 = 1.0)");

        // Test 4: Positive saturation clamp (a = 4.0, w = 2.0, clr = 0)
        // Product = +8.0, Total = 1.0 + 8.0 = 9.0 -> Clamps to +7.9997 (0x7FFF)
        drive_mac(16'sh4000, 16'sh2000, 16'sh0000, 1'b0, "Test 4: Pos Saturation (prev 1.0 + 4.0 * 2.0 = +9.0 -> Clamps to 7.9997)");

        // Test 5: Negative saturation clamp (a = -3.0, w = 2.0, b = -4.0, clr = 1)
        // Product = -6.0, Total = -6.0 + (-4.0) = -10.0 -> Clamps to -8.0000 (0x8000)
        drive_mac(16'shD000, 16'sh2000, 16'shC000, 1'b1, "Test 5: Neg Saturation (-3.0 * 2.0 + -4.0 = -10.0 -> Clamps to -8.0)");

        // Test 6: Pipe flush & Idle check
        drive_idle();
        @(posedge clk);
        drive_idle();

        #30;
        $display("\n==========================================");
        $display("   SIMULATION FINISHED SUCCESSFULLY");
        $display("==========================================\n");
        $finish;
    end

endmodule
