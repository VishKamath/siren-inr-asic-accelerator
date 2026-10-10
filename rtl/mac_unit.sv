`timescale 1ns/1ps
import inr_pkg::*;

module mac_unit (
    input  logic                      clk,
    input  logic                      rst_in,
    input  logic                      valid_in,
    input  logic                      clr_acc,
    input  logic signed [15:0]        a_in,
    input  logic signed [15:0]        w_in,
    input  logic signed [15:0]        bias_in,
    output logic                      valid_out,
    output logic                      ovf_flag,
    output logic signed [15:0]        acc_out
);

    logic signed [31:0] mult_raw;
    logic signed [31:0] mult_q;
    logic signed [32:0] sum_stage;
    logic signed [32:0] current_acc;

    always_comb begin
        mult_raw    = 32'(signed'(a_in)) * 32'(signed'(w_in));
        mult_q      = (mult_raw + 32'sh0000_0800) >>> 12; // Midpoint rounding
        
        // If clr_acc is 1 OR if multipliers are zeroed (folded engine mode), take bias_in directly
        if (clr_acc || (a_in == 16'sh0 && w_in == 16'sh0)) begin
            current_acc = 33'(signed'(bias_in));
        end else begin
            current_acc = 33'(signed'(acc_out));
        end
        
        sum_stage = current_acc + 33'(signed'(mult_q));
    end

    always_ff @(posedge clk or negedge rst_in) begin
        if (!rst_in) begin
            valid_out <= 1'b0;
            acc_out   <= 16'sh0;
            ovf_flag  <= 1'b0;
        end else begin
            valid_out <= valid_in && !clr_acc;

            if (valid_in) begin
                if (sum_stage > 33'sd32767) begin
                    ovf_flag <= 1'b1;
                    acc_out  <= 16'sh7FFF;
                end else if (sum_stage < -33'sd32768) begin
                    ovf_flag <= 1'b1;
                    acc_out  <= 16'sh8000;
                end else begin
                    ovf_flag <= 1'b0;
                    acc_out  <= sum_stage[15:0];
                end
            end
        end
    end

endmodule
