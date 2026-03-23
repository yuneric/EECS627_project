module mem_bank #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 64
) (
    input i_clk,

    input                   i_s0_cen  , 
    input                   i_s0_wen  ,
    output [DATA_WIDTH-1:0] o_s0_rdata,
    input  [ADDR_WIDTH-1:0] i_s0_addr ,
    input  [DATA_WIDTH-1:0] i_s0_wdata,

    input                   i_s1_cen  , 
    input                   i_s1_wen  ,
    output [DATA_WIDTH-1:0] o_s1_rdata,
    input  [ADDR_WIDTH-1:0] i_s1_addr ,
    input  [DATA_WIDTH-1:0] i_s1_wdata

);


sp4096x64m8 sram0 (
                .CLK(i_clk),
                .CEN(i_s0_cen),
                .WEN(i_s0_wen),
                .Q(o_s0_rdata),
                .A(i_s0_addr),
                .D(i_s0_wdata)
                );


sp4096x64m8 sram1 (
                .CLK(i_clk),
                .CEN(i_s1_cen),
                .WEN(i_s1_wen),
                .Q(o_s1_rdata),
                .A(i_s1_addr),
                .D(i_s1_wdata)
                );
endmodule
