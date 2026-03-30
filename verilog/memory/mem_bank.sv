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

    logic                  s0_cen  ; 
    logic                  s0_wen  ;
    logic [ADDR_WIDTH-1:0] s0_addr ;
    logic [DATA_WIDTH-1:0] s0_wdata;

    logic                  s1_cen  ; 
    logic                  s1_wen  ;
    logic [ADDR_WIDTH-1:0] s1_addr ;
    logic [DATA_WIDTH-1:0] s1_wdata;

    assign #1.5 s0_cen   = i_s0_cen  ; 
    assign #1.5 s0_wen   = i_s0_wen  ;
    assign #1.5 s0_addr  = i_s0_addr ;
    assign #1.5 s0_wdata = i_s0_wdata;

    assign #1.5 s1_cen   = i_s1_cen  ; 
    assign #1.5 s1_wen   = i_s1_wen  ;
    assign #1.5 s1_addr  = i_s1_addr ;
    assign #1.5 s1_wdata = i_s1_wdata;

sp4096x64m8 sram0 (
                .CLK(i_clk),
                .CEN(s0_cen),
                .WEN(s0_wen),
                .Q(o_s0_rdata),
                .A(s0_addr),
                .D(s0_wdata)
                );


sp4096x64m8 sram1 (
                .CLK(i_clk),
                .CEN(s1_cen),
                .WEN(s1_wen),
                .Q(o_s1_rdata),
                .A(s1_addr),
                .D(s1_wdata)
                );
endmodule
