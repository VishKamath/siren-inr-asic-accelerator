`timescale 1ns/1ps
import inr_pkg::*;

module siren_network #(
    parameter int NUM_NEURONS = 32
)(
    input  logic                     clk,
    input  logic                     rst_in,
    input  logic                     valid_in,
    input  logic                     clr_acc,
    input  logic signed [15:0]       a_in,
    input  logic signed [15:0]       l1_w_in    [0:NUM_NEURONS-1],
    input  logic signed [15:0]       l1_bias_in [0:NUM_NEURONS-1],
    input  logic signed [15:0]       l2_w_in    [0:NUM_NEURONS-1],
    input  logic signed [15:0]       l2_bias_in,

    output logic                     pixel_valid_out,
    output logic signed [15:0]       pixel_out
);

    logic [NUM_NEURONS-1:0]        neuron_valid;
    logic signed [15:0]            neuron_sin   [0:NUM_NEURONS-1];
    logic signed [15:0]            neuron_cos   [0:NUM_NEURONS-1];
    logic signed [31:0]            out_value    [0:NUM_NEURONS-1];
    logic signed [31:0]            final_value  [0:NUM_NEURONS-1];
    logic signed [36:0]            sum_l2;

    genvar i;
    generate
        for (i = 0; i < NUM_NEURONS; i = i + 1) begin : gen_neurons
            siren_neuron u_neuron (
                .clk       (clk),
                .rst_in    (rst_in),
                .valid_in  (valid_in),
                .clr_acc   (clr_acc),
                .a_in      (a_in),          
                .w_in      (l1_w_in[i]),   
                .bias_in   (l1_bias_in[i]), 
                .valid_out (neuron_valid[i]),
                .act_out   (neuron_sin[i]), 
                .cos_out   (neuron_cos[i])  
            );
        end
    endgenerate

    always_comb begin 
        sum_l2 = 37'(signed'(l2_bias_in));
        for (int k = 0; k < NUM_NEURONS; k = k + 1) begin 
            out_value[k]   = 32'(signed'(neuron_sin[k])) * 32'(signed'(l2_w_in[k]));
            final_value[k] = out_value[k] >>> 12;
            sum_l2        += 37'(signed'(final_value[k]));
        end
    end

    always_ff @(posedge clk or negedge rst_in) begin 
        if (!rst_in) begin 
            pixel_valid_out <= 1'b0;
            pixel_out       <= 16'sh0;
        end else begin 
            pixel_valid_out <= neuron_valid[0];
            if (neuron_valid[0]) begin 
                if (sum_l2 > 37'sd32767) begin
                    pixel_out <= 16'sh7FFF;
                end else if (sum_l2 < -37'sd32768) begin
                    pixel_out <= 16'sh8000;
                end else begin
                    pixel_out <= sum_l2[15:0];
                end
            end
        end
    end

endmodule
