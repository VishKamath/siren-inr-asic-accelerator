`timescale 1ns/1ps
import inr_pkg::*;

module tb_cordic;

    logic clk;
    logic rst_in;
    logic valid_in;
    logic signed [ACT_WIDTH-1:0] angle_in;

    logic valid_out;
    logic signed [ACT_WIDTH-1:0] sin_out;
    logic signed [ACT_WIDTH-1:0] cos_out;

    real q_deg [0:63];
    real q_cos [0:63];
    real q_sin [0:63];
    int wr_ptr = 0;
    int rd_ptr = 0;

    siren_act_unit dut (
        .clk       (clk),
        .rst_in    (rst_in),
        .valid_in  (valid_in),
        .angle_in  (angle_in),
        .valid_out (valid_out),
        .sin_out   (sin_out),
        .cos_out   (cos_out)
    );

    always #5 clk = ~clk;

    task drive_angle(input real deg);
        real rad;
        begin
            rad = deg * 3.141592653589793 / 180.0;
            @(posedge clk);
            valid_in <= 1'b1;
            angle_in <= $rtoi((deg / 360.0) * 8192.0);

            q_deg[wr_ptr] = deg;
            q_cos[wr_ptr] = $cos(rad);
            q_sin[wr_ptr] = $sin(rad);
            wr_ptr = wr_ptr + 1;
        end
    endtask

    real real_cos, real_sin;
    real err_cos, err_sin;
    real cur_deg, exp_cos, exp_sin;

    always @(posedge clk) begin
        if (valid_out) begin
            if (rd_ptr < wr_ptr) begin
                cur_deg = q_deg[rd_ptr];
                exp_cos = q_cos[rd_ptr];
                exp_sin = q_sin[rd_ptr];
                rd_ptr  = rd_ptr + 1;

                real_cos = $itor(cos_out) / 4096.0;
                real_sin = $itor(sin_out) / 4096.0;

                err_cos = real_cos - exp_cos;
                if (err_cos < 0) err_cos = -err_cos;

                err_sin = real_sin - exp_sin;
                if (err_sin < 0) err_sin = -err_sin;

                $display("[OUT @ %0t ps] Angle: %6.1f deg | Cos: %7.4f (Exp: %7.4f) | Sin: %7.4f (Exp: %7.4f)",
                         $time, cur_deg, real_cos, exp_cos, real_sin, exp_sin);

                if (err_cos > 0.05 || err_sin > 0.05) begin
                    $display("    --> [WARNING] Discrepancy exceeds tolerance!");
                end else begin
                    $display("    --> [PASS]");
                end
            end
        end
    end

    initial begin
        clk      = 0;
        rst_in   = 0;
        valid_in = 0;
        angle_in = '0;

        #20;
        rst_in = 1;
        #10;

        drive_angle(0.0);
        drive_angle(30.0);
        drive_angle(45.0);
        drive_angle(-45.0);

        drive_angle(390.0);
        drive_angle(765.0);
        drive_angle(-405.0);

        @(posedge clk);
        valid_in <= 1'b0;

        #400;
        $finish;
    end

endmodule
