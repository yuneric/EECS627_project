module address_decoder #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter MMIO_ADDR = 32'h2000_0000,
    parameter MMIO_SIZE = 32'h0000_0100
)(
    input                       i_cpu_valid,
    input                       i_cpu_instr,
    input [ADDR_WIDTH-1:0]      i_cpu_addr,
    input [DATA_WIDTH-1:0]      i_cpu_wdata,
    input [3:0]                 i_cpu_wstrb,
    output reg                  o_cpu_ready,
    output reg [DATA_WIDTH-1:0] o_cpu_rdata,

    output reg                  o_mem_valid,
    output reg                  o_mem_instr,
    output reg [ADDR_WIDTH-1:0] o_mem_addr,
    output reg [DATA_WIDTH-1:0] o_mem_wdata,
    output reg [3:0]            o_mem_wstrb,
    input                       i_mem_ready,
    input  [DATA_WIDTH-1:0]     i_mem_rdata,

    output reg                  o_mmio_valid,
    //output                    o_mmio_instr,
    output reg [ADDR_WIDTH-1:0] o_mmio_addr,
    output reg [DATA_WIDTH-1:0] o_mmio_wdata,
    output reg [3:0]            o_mmio_wstrb,
    input                       i_mmio_ready,
    input  [DATA_WIDTH-1:0]     i_mmio_rdata
);

wire to_mmio;

assign to_mmio = ((i_cpu_addr >= MMIO_ADDR) && (i_cpu_addr < MMIO_ADDR + MMIO_SIZE));

always_comb begin
    if(!to_mmio) begin
        o_mem_valid = i_cpu_valid;
        o_mem_instr = i_cpu_instr;
        o_mem_addr  = i_cpu_addr;
        o_mem_wdata = i_cpu_wdata;
        o_mem_wstrb = i_cpu_wstrb;
        
        o_cpu_ready = i_mem_ready;
        o_cpu_rdata = i_mem_rdata;

        o_mmio_valid = '0;
        //o_mmio_instr = 0;
        o_mmio_addr  = '0;
        o_mmio_wdata = '0;
        o_mmio_wstrb = '0;

    end else begin
        o_mem_valid = '0;
        o_mem_instr = i_cpu_instr;
        o_mem_addr  = '0;
        o_mem_wdata = '0;
        o_mem_wstrb = '0;

        o_cpu_ready = i_mmio_ready;
        o_cpu_rdata = i_mmio_rdata;

        o_mmio_valid = i_cpu_valid;
        //o_mmio_instr = i_cpu_instr;
        o_mmio_addr  = i_cpu_addr;
        o_mmio_wdata = i_cpu_wdata;
        o_mmio_wstrb = i_cpu_wstrb;

    end
end

endmodule