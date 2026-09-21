`timescale 1ns/1ps
import inr_pkg::*;

module phase_folder (
    input  logic                     clk,
    input  logic                     rst_in,
    input  logic                     valid_in,
    input  logic signed [15:0]       angle_in,
    output logic                     valid_out_folded,
    output logic signed [15:0]       phase_out_folded
);

    localparam signed [31:0] CONST_2PI     = 32'sd25736;
    localparam signed [31:0] CONST_PI      = 32'sd12868;
    localparam signed [31:0] CONST_HALF_PI = 32'sd6434;

    logic signed [31:0] angle_32;
    logic signed [31:0] centered;
    logic signed [31:0] folded;

    always @* begin
        angle_32 = 32'(signed'(angle_in));

        // Center from [0, 2*pi) to [-pi, +pi]
        if (angle_32 > CONST_PI) begin
            centered = angle_32 - CONST_2PI;
        end else begin
            centered = angle_32;
        end

        // Fold to [-pi/2, +pi/2]
        if (centered > CONST_HALF_PI) begin
            folded = CONST_PI - centered;
        end else if (centered < -CONST_HALF_PI) begin
            folded = -CONST_PI - centered;
        end else begin
            folded = centered;
        end
    end

    always @(posedge clk or negedge rst_in) begin
        if (!rst_in) begin
            valid_out_folded <= 1'b0;
            phase_out_folded <= 16'sh0;
        end else begin
            valid_out_folded <= valid_in;
            if (valid_in) begin
                phase_out_folded <= folded[15:0];
            end
        end
    end

endmodule
