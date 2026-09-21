`timescale 1ns/1ps
import inr_pkg::*;

module cordic_wrapper (
    input  logic                     clk,
    input  logic                     rst_in,
    input  logic                     valid_in,
    input  logic signed [ACT_WIDTH-1:0] phase_in,
    output logic                     valid_out,
    output logic signed [ACT_WIDTH-1:0] sin_out,
    output logic signed [ACT_WIDTH-1:0] cos_out
);

    logic signed [ACT_WIDTH-1:0] x_pipe [0:CORDIC_STAGES];
    logic signed [ACT_WIDTH-1:0] y_pipe [0:CORDIC_STAGES];
    logic signed [ACT_WIDTH-1:0] z_pipe [0:CORDIC_STAGES];
    logic valid_pipe [0:CORDIC_STAGES];

    assign x_pipe[0]     = CORDIC_K;
    assign y_pipe[0]     = '0;
    assign z_pipe[0]     = phase_in;
    assign valid_pipe[0] = valid_in;

    genvar i;
    generate
        for (i = 0; i < CORDIC_STAGES; i++) begin : gen_cordic_stages
            cordic_stage #(
                .DATA_WIDTH(ACT_WIDTH),
                .STAGE_IDX(i),
                .ATAN_VAL(CORDIC_ATAN_LUT[(15-i)*16 +: 16])
            ) u_stage (
                .clk       (clk),
                .rst_n     (rst_in),
                .valid_in  (valid_pipe[i]),
                .x_in      (x_pipe[i]),
                .y_in      (y_pipe[i]),
                .z_in      (z_pipe[i]),
                .valid_out (valid_pipe[i+1]),
                .x_out     (x_pipe[i+1]),
                .y_out     (y_pipe[i+1]),
                .z_out     (z_pipe[i+1])
            );
        end
    endgenerate

    assign valid_out = valid_pipe[CORDIC_STAGES];
    assign cos_out   = x_pipe[CORDIC_STAGES] >>> 2;
    assign sin_out   = y_pipe[CORDIC_STAGES] >>> 2;

endmodule
