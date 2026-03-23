module mem_if #(
    parameter ADDR_WIDTH = 12,
    parameter DATA_WIDTH = 64
) (
    input  [ADDR_WIDTH-1:0] i_mmu_waddr,
    input                   i_mmu_wen  ,
    input  [DATA_WIDTH-1:0] i_mmu_wdata,

    input        [ADDR_WIDTH-1:0] i_mmu_raddr,
    input                         i_mmu_ren  ,
    output logic [DATA_WIDTH-1:0] o_mmu_rdata,

    input  [ADDR_WIDTH-1:0] i_comp_waddr,
    input                   i_comp_wen  ,
    input  [DATA_WIDTH-1:0] i_comp_wdata,

    input        [ADDR_WIDTH-1:0] i_comp_raddr,
    input                         i_comp_ren  ,
    output logic [DATA_WIDTH-1:0] o_comp_rdata,

    output logic                  o_b0_s0_cen   ,
    output logic                  o_b0_s0_wen   ,
    input  logic [DATA_WIDTH-1:0] i_b0_s0_rdata ,
    output logic [ADDR_WIDTH-1:0] o_b0_s0_addr  ,
    output logic [DATA_WIDTH-1:0] o_b0_s0_wdata ,

    output logic                  o_b0_s1_cen   ,
    output logic                  o_b0_s1_wen   ,
    input  logic [DATA_WIDTH-1:0] i_b0_s1_rdata ,
    output logic [ADDR_WIDTH-1:0] o_b0_s1_addr  ,
    output logic [DATA_WIDTH-1:0] o_b0_s1_wdata ,

    output logic                  o_b1_s0_cen   ,
    output logic                  o_b1_s0_wen   ,
    input  logic [DATA_WIDTH-1:0] i_b1_s0_rdata ,
    output logic [ADDR_WIDTH-1:0] o_b1_s0_addr  ,
    output logic [DATA_WIDTH-1:0] o_b1_s0_wdata ,

    output logic                  o_b1_s1_cen   ,
    output logic                  o_b1_s1_wen   ,
    input  logic [DATA_WIDTH-1:0] i_b1_s1_rdata ,
    output logic [ADDR_WIDTH-1:0] o_b1_s1_addr  ,
    output logic [DATA_WIDTH-1:0] o_b1_s1_wdata ,
    
    input i_bank_sel
);

always @ * begin
    if(i_bank_sel) begin
        o_b0_s0_cen   = i_mmu_wen;
        o_b0_s0_wen   = i_mmu_wen;
        o_b0_s0_addr  = i_mmu_waddr;
        o_b0_s0_wdata = i_mmu_wdata;
        // i_b0_s0_rdata unused

        o_b0_s1_cen   = i_mmu_ren;
        o_b0_s1_wen   = 1'b1;
        o_b0_s1_addr  = i_mmu_raddr;
        o_b0_s1_wdata = {DATA_WIDTH{1'b0}};
        o_mmu_rdata = i_b0_s1_rdata;

        o_b1_s0_cen    = i_comp_ren;
        o_b1_s0_wen    = 1'b1;
        o_b1_s0_addr   = i_comp_raddr;
        o_b1_s0_wdata  = {DATA_WIDTH{1'b0}};
        o_comp_rdata   = i_b1_s0_rdata;

        o_b1_s1_cen    = i_comp_wen;
        o_b1_s1_wen    = i_comp_wen;
        o_b1_s1_addr   = i_comp_waddr;
        o_b1_s1_wdata  = i_comp_wdata;
        // i_b1_s1_rdata unused

    end else begin
        o_b1_s0_cen   = i_mmu_wen;
        o_b1_s0_wen   = i_mmu_wen;
        o_b1_s0_addr  = i_mmu_waddr;
        o_b1_s0_wdata = i_mmu_wdata;
        // i_b1_s0_rdata unused

        o_b1_s1_cen   = i_mmu_ren;
        o_b1_s1_wen   = 1'b1;
        o_b1_s1_addr  = i_mmu_raddr;
        o_b1_s1_wdata = {DATA_WIDTH{1'b0}};
        o_mmu_rdata   = i_b1_s1_rdata;

        o_b0_s0_cen    = i_comp_ren;
        o_b0_s0_wen    = 1'b1;
        o_b0_s0_addr   = i_comp_raddr;
        o_b0_s0_wdata  = {DATA_WIDTH{1'b0}};
        o_comp_rdata   = i_b0_s0_rdata;

        o_b0_s1_cen    = i_comp_wen;
        o_b0_s1_wen    = i_comp_wen;
        o_b0_s1_addr   = i_comp_waddr;
        o_b0_s1_wdata  = i_comp_wdata;
        // i_b1_s1_rdata unused

    end
end

endmodule
