`timescale 1ns/1ps

module sram_1024x16 (
  input  logic        clk,
  input  logic        cen,    // Chip Enable (Active Low: 0 = Enabled)
  input  logic        wen,    // Write Enable (Active Low: 0 = Write, 1 = Read)
  input  logic [9:0]  addr,   // 1024 depth (10-bit address)
  input  logic [15:0] d_in,   // 16-bit Q4.12 pixel / coordinate data
  output logic [15:0] d_out
);

`ifndef SYNTHESIS
  // Simulation behavioral memory
  logic [15:0] mem [0:1023];

  always_ff @(posedge clk) begin
    if (!cen) begin
      if (!wen) begin
        mem[addr] <= d_in;
        d_out     <= d_in;
      end else begin
        d_out     <= mem[addr];
      end
    end
  end
`else
  // For synthesis, this module is instantiated as a macro blackbox 
  // with timing and power defined in the SRAM .lib/.lef
`endif

endmodule
