`timescale 1ns/1ps

module tb_siren_sharpen;

    // Clock and Reset
    logic clk;
    logic rst_in;

    // DUT Interface
    logic signed [15:0] data_in;
    logic valid_in;
    logic pixel_valid;
    logic signed [15:0] pixel_out;
    logic frame_done;

    // Testbench Memory & Monitoring
    logic signed [15:0] frame_in  [0:31][0:31];
    logic signed [15:0] golden_out[0:31][0:31];
    int out_pixel_count;
    int mismatch_count;

    int cur_y;
    int cur_x;
    logic signed [15:0] expected;

    // Clock Generation: 100 MHz (10ns period)
    always #5 clk = ~clk;

    // DUT Instantiation
    siren_sharpen dut (
        .clk(clk),
        .rst_in(rst_in),
        .data_in(data_in),
        .valid_in(valid_in),
        .pixel_valid(pixel_valid),
        .pixel_out(pixel_out),
        .frame_done(frame_done)
    );

    // Reference Model for Laplacian 5C - (N+S+E+W) with Cardinal Clamping
    function automatic logic signed [15:0] calc_expected(int y, int x);
        int c, n, s, w, e;
        int sum_neighbors;
        int sharp;

        c = int'(frame_in[y][x]);
        n = (y == 0)  ? c : int'(frame_in[y-1][x]);
        s = (y == 31) ? c : int'(frame_in[y+1][x]);
        w = (x == 0)  ? c : int'(frame_in[y][x-1]);
        e = (x == 31) ? c : int'(frame_in[y][x+1]);

        sum_neighbors = n + s + w + e;
        sharp = (5 * c) - sum_neighbors;

        // Saturate to Q4.12 [0.0, 1.0] (0 to 4096)
        if (sharp < 0)
            return 16'sh0000;
        else if (sharp > 4096)
            return 16'sh1000;
        else
            return 16'(sharp);
    endfunction

    // Checker Process
    initial begin
        out_pixel_count = 0;
        mismatch_count  = 0;

        forever begin
            @(posedge clk);
            if (pixel_valid) begin
                cur_y = out_pixel_count / 32;
                cur_x = out_pixel_count % 32;
                expected = golden_out[cur_y][cur_x];

                // Debug print for the first 5 output pixels
                if (out_pixel_count < 5) begin
                    $display("DEBUG [Pixel #%0d @ (%0d,%0d)]: DUT = 0x%04x | Exp = 0x%04x | (C=0x%04x, N=0x%04x, S=0x%04x, W=0x%04x, E=0x%04x)",
                             out_pixel_count, cur_y, cur_x, pixel_out, expected,
                             dut.tap_c, dut.tap_n, dut.tap_s, dut.tap_w, dut.tap_e);
                end

                if (pixel_out !== expected) begin
                    $display("[MISMATCH] Pixel #%0d (%0d,%0d): DUT = 16'h%04x, Expected = 16'h%04x",
                             out_pixel_count, cur_y, cur_x, pixel_out, expected);
                    mismatch_count++;
                end
                out_pixel_count++;
            end
        end
    end

    // Stimulus Process
    initial begin
        clk      = 0;
        rst_in   = 0;
        data_in  = 0;
        valid_in = 0;

        // Pass 1: Populate ALL input frame data first
        for (int r = 0; r < 32; r++) begin
            for (int c = 0; c < 32; c++) begin
                if (r == 16 && c == 16)
                    frame_in[r][c] = 16'sh1000;
                else
                    frame_in[r][c] = 16'(signed'(16'sh0800 + ((r * 32 + c) & 16'h00FF)));
            end
        end

        // Pass 2: Calculate golden model once whole frame is populated
        for (int r = 0; r < 32; r++) begin
            for (int c = 0; c < 32; c++) begin
                golden_out[r][c] = calc_expected(r, c);
            end
        end

        // Reset Pulse
        #25;
        rst_in = 1;
        repeat (2) @(posedge clk);

        $display("--- Starting Frame Stream (1 pixel per 28 cycles) ---");

        // Feed 1024 Pixels with 28-cycle Pacing
        for (int r = 0; r < 32; r++) begin
            for (int c = 0; c < 32; c++) begin
                @(posedge clk);
                data_in  <= frame_in[r][c];
                valid_in <= 1'b1;

                @(posedge clk);
                valid_in <= 1'b0;
                data_in  <= 16'sh0000;

                repeat (27) @(posedge clk);
            end
        end

        $display("--- Input stream completed. Waiting for S_FLUSH & frame_done ---");

        fork
            begin
                @(posedge frame_done);
            end
            begin
                #2000000; // 2 ms watchdog
                $display("[ERROR] Watchdog timeout waiting for frame_done!");
            end
        join_any

        repeat (5) @(posedge clk);

        $display("==================================================");
        $display("Simulation Finished!");
        $display("Total Pixels Received : %0d / 1024", out_pixel_count);
        $display("Total Mismatches      : %0d", mismatch_count);
        if (out_pixel_count == 1024 && mismatch_count == 0)
            $display(">> TEST PASSED <<");
        else
            $display(">> TEST FAILED <<");
        $display("==================================================");

        $finish;
    end

endmodule
