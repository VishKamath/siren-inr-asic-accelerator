`timescale 1ns/1ps
import inr_pkg::*;

module siren_scaler (
    input  logic                        clk,
    input  logic                        rst_in,
    input  logic                        valid_in,
    input  logic signed [15:0]          data_in,
    output logic                        valid_out,
    output logic signed [ACT_WIDTH-1:0] data_out
);

    localparam signed [31:0] CONST_PI  = 32'sd12868; // pi * 4096
    localparam signed [31:0] CONST_2PI = 32'sd25736; // 2 * pi * 4096

    logic signed [31:0] ext_data;
    logic signed [31:0] scaled_angle;
    logic signed [31:0] mod_angle;
    logic signed [31:0] centered_angle;

    always_comb begin
        ext_data     = 32'(signed'(data_in));
        scaled_angle = ext_data * 32'sd30;
        
        // Modulo 2*pi
        mod_angle = scaled_angle % CONST_2PI;
        
        // Wrap to [-pi, +pi] to match phase_folder/CORDIC expectations
        if (mod_angle > CONST_PI) begin
            centered_angle = mod_angle - CONST_2PI;
        end else if (mod_angle < -CONST_PI) begin
            centered_angle = mod_angle + CONST_2PI;
        end else begin
            centered_angle = mod_angle;
        end
    end

    always_ff @(posedge clk or negedge rst_in) begin
        if (!rst_in) begin
            valid_out <= 1'b0;
            data_out  <= 16'sh0;
        end else begin
            valid_out <= valid_in;
            if (valid_in) begin
                data_out <= centered_angle[15:0];
            end
        end
    end

endmodule
