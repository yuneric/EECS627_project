module mem_if #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 64
) (
    input i_clk,
    input [ADDR_WIDTH-1:0] i_mmu_waddr,
    input                  i_mmu_wen,
    input [DATA_WIDTH-1:0] i_mmu_wdata,

    input      [ADDR_WIDTH-1:0] i_mmu_raddr,
    input                       i_mmu_ren,
    output reg [DATA_WIDTH-1:0] o_mmu_rdata,

    input  [ADDR_WIDTH-1:0] i_comp_waddr,
    input                   i_comp_wen,
    input  [DATA_WIDTH-1:0] i_comp_wdata,

    input      [ADDR_WIDTH-1:0] i_comp_raddr,
    input                       i_comp_ren,
    output reg [DATA_WIDTH-1:0] o_comp_rdata,

    input i_bank_sel
);

reg b0_s0_cen;
reg b0_s0_wen;
reg [DATA_WIDTH-1:0] b0_s0_rdata;
reg [ADDR_WIDTH-1:0] b0_s0_addr;
reg [DATA_WIDTH-1:0] b0_s0_wdata;

reg b0_s1_cen;
reg b0_s1_wen;
reg [DATA_WIDTH-1:0] b0_s1_rdata;
reg [ADDR_WIDTH-1:0] b0_s1_addr;
reg [DATA_WIDTH-1:0] b0_s1_wdata;

reg b1_s0_cen;
reg b1_s0_wen;
reg [DATA_WIDTH-1:0] b1_s0_rdata;
reg [ADDR_WIDTH-1:0] b1_s0_addr;
reg [DATA_WIDTH-1:0] b1_s0_wdata;

reg b1_s1_cen;
reg b1_s1_wen;
reg [DATA_WIDTH-1:0] b1_s1_rdata;
reg [ADDR_WIDTH-1:0] b1_s1_addr;
reg [DATA_WIDTH-1:0] b1_s1_wdata;


always @ * begin
    if(i_bank_sel) begin
        b0_s0_cen   = i_mmu_wen;
        b0_s0_wen   = i_mmu_wen;
        b0_s0_addr  = i_mmu_waddr;
        b0_s0_wdata = i_mmu_wdata;
        // b0_s0_rdata unused

        b0_s1_cen   = i_mmu_ren;
        b0_s1_wen   = 1'b1;
        b0_s1_addr  = i_mmu_raddr;
        b0_s1_wdata = {DATA_WIDTH{1'b0}};
        o_mmu_rdata = b0_s1_rdata;

        b1_s0_cen    = i_comp_ren;
        b1_s0_wen    = 1'b1;
        b1_s0_addr   = i_comp_raddr;
        b1_s0_wdata  = {DATA_WIDTH{1'b0}};
        o_comp_rdata = b1_s0_rdata;

        b1_s1_cen    = i_comp_wen;
        b1_s1_wen    = i_comp_wen;
        b1_s1_addr   = i_comp_waddr;
        b1_s1_wdata  = i_comp_wdata;
        // b1_s1_rdata unused

    end else begin
        b1_s0_cen   = i_mmu_wen;
        b1_s0_wen   = i_mmu_wen;
        b1_s0_addr  = i_mmu_waddr;
        b1_s0_wdata = i_mmu_wdata;
        // b1_s0_rdata unused

        b1_s1_cen   = i_mmu_ren;
        b1_s1_wen   = 1'b1;
        b1_s1_addr  = i_mmu_raddr;
        b1_s1_wdata = {DATA_WIDTH{1'b0}};
        o_mmu_rdata = b1_s1_rdata;

        b0_s0_cen    = i_comp_ren;
        b0_s0_wen    = 1'b1;
        b0_s0_addr   = i_comp_raddr;
        b0_s0_wdata  = {DATA_WIDTH{1'b0}};
        o_comp_rdata = b0_s0_rdata;

        b0_s1_cen    = i_comp_wen;
        b0_s1_wen    = i_comp_wen;
        b0_s1_addr   = i_comp_waddr;
        b0_s1_wdata  = i_comp_wdata;
        // b1_s1_rdata unused

    end
end

sp4096x64m8 bank0_sram0 (
                .CLK(i_clk),
                .CEN(b0_s0_cen),
                .WEN(b0_s0_wen),
                .Q(b0_s0_rdata),
                .A(b0_s0_addr),
                .D(b0_s0_wdata)
                );


sp4096x64m8 bank0_sram1 (
                .CLK(i_clk),
                .CEN(b0_s1_cen),
                .WEN(b0_s1_wen),
                .Q(b0_s1_rdata),
                .A(b0_s1_addr),
                .D(b0_s1_wdata)
                );

sp4096x64m8 bank1_sram0 (
                .CLK(i_clk),
                .CEN(b1_s0_cen),
                .WEN(b1_s0_wen),
                .Q(b1_s0_rdata),
                .A(b1_s0_addr),
                .D(b1_s0_wdata)
                );


sp4096x64m8 bank1_sram1 (
                .CLK(i_clk),
                .CEN(b1_s1_cen),
                .WEN(b1_s1_wen),
                .Q(b1_s1_rdata),
                .A(b1_s1_addr),
                .D(b1_s1_wdata)
                );
endmodule
