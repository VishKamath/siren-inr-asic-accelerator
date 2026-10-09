`timescale 1ns/1ps
import inr_pkg::*;

module cordic_stage
#(
  parameter int DATA_WIDTH = 16,
  parameter int STAGE_IDX  = 0,
  parameter signed [15:0] ATAN_VAL = 16'sh0000
)
(
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      valid_in,
  input  logic signed [DATA_WIDTH-1:0] x_in,
  input  logic signed [DATA_WIDTH-1:0] y_in,
  input  logic signed [DATA_WIDTH-1:0] z_in,

  output logic                      valid_out,
  output logic signed [DATA_WIDTH-1:0] x_out,
  output logic signed [DATA_WIDTH-1:0] y_out,
  output logic signed [DATA_WIDTH-1:0] z_out
);

  logic signed [DATA_WIDTH-1:0] x_shift;
  logic signed [DATA_WIDTH-1:0] y_shift;
  logic signed [DATA_WIDTH-1:0] x_next;
  logic signed [DATA_WIDTH-1:0] y_next;
  logic signed [DATA_WIDTH-1:0] z_next;

  always_comb begin
    x_shift = x_in >>> STAGE_IDX;
    y_shift = y_in >>> STAGE_IDX;

    if (z_in >= 0) begin
      x_next = x_in - y_shift;
      y_next = y_in + x_shift;
      z_next = z_in - ATAN_VAL;
    end else begin
      x_next = x_in + y_shift;
      y_next = y_in - x_shift;
      z_next = z_in + ATAN_VAL;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_out <= 1'b0;
      x_out     <= '0;
      y_out     <= '0;
      z_out     <= '0;
    end else begin
      valid_out <= valid_in;
      if (valid_in) begin
        x_out <= x_next;
        y_out <= y_next;
        z_out <= z_next;
      end else begin
        x_out <= '0;
        y_out <= '0;
        z_out <= '0;
      end
    end
  end

endmodule
