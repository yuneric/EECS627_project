module dunkin_donuts#(
    parameter PSUM_WIDTH        = 32;
    parameter SHIFT_WIDTH       = 5;
    parameter INPUT_FIFO_DEPTH  = 16; 
    parameter INPUT_FIFO_AF_LVL = 5; // needs 4 pushes of headsup
    parameter OUTPUT_FIFO_DEPTH = 8;
    parameter CPU_ADDR_WIDTH        = 32,
    parameter CPU_DATA_WIDTH        = 32,
    parameter NPU_ACT_ADDR_WIDTH    = 12,
    parameter NPU_WT_ADDR_WIDTH     = 11,
    parameter NPU_DATA_WIDTH        = 64,
    parameter DIM_WIDTH             = 10,
    parameter MMIO_ADDR             = 32'h2000_0000,
    parameter MMIO_SIZE             = 32'h0000_0100,
    parameter ADDR_WIDTH            = 32,
    parameter DATA_WIDTH            = 32,
    parameter WT_ADDR_WIDTH         = 11,
    parameter WORD_SIZE             = 64,
    parameter OUTPUT_WIDTH          = 64,
    parameter DIM                   = 8,
    parameter WT_BANKS              = 8 
)
(
    input           i_clk       ,
    input           i_rstn_sync ,
    input           i_rstn_async,

    // Cpu trace signals
    output          o_trap       , 
    output          o_trace_valid,
    output [35:0]   o_trace_data ,

    // Axi Arbiter to off chip memory
    output                  o_mem_valid,
    input                   i_mem_ready,
    output [ADDR_WIDTH-1:0] o_mem_addr ,
    output [DATA_WIDTH-1:0] o_mem_wdata,
    output [3:0]            o_mem_wstrb,
    input  [DATA_WIDTH-1:0] i_mem_rdata,

    // ACT/OUTPUT SRAM interface - for the two banks and two ports.
    output                            o_b0_s0_cen   ,
    output                            o_b0_s0_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b0_s0_rdata , //we want this to be input so that this data could be fed into SA slice -> the input fifo.
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b0_s0_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b0_s0_wdata ,

    output                            o_b0_s1_cen   ,
    output                            o_b0_s1_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b0_s1_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b0_s1_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b0_s1_wdata ,

    output                            o_b1_s0_cen   ,
    output                            o_b1_s0_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b1_s0_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b1_s0_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b1_s0_wdata ,

    output                            o_b1_s1_cen   ,
    output                            o_b1_s1_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b1_s1_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b1_s1_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b1_s1_wdata ,

    // Systolic array ports
    //   Top Slices
    //     Config
    //top
    output                           o_top_cdc_req   ,
    input                            i_top_cdc_ack   ,
    output                           o_top_relu_en   ,
    output [4:0]                     o_top_shift_by  ,
    output                           o_top_maxpool_en,

    //bottom
    output                           o_bottom_cdc_req   ,
    input                            i_bottom_cdc_ack   ,
    output                           o_bottom_relu_en   ,
    output [4:0]                     o_bottom_shift_by  ,
    output                           o_bottom_maxpool_en,

    //Input Fifos - top
    output  logic [NPU_DATA_WIDTH-1:0]             o_top_push_act_data,
    output  logic                                  o_top_push_data_last,
    output  logic [`NUM_ARRAYS-1:0]                o_top_push_en,
    input   logic                                  i_top_push_fifo_full,

    //Input Fifos - bottom
    output  logic [NPU_DATA_WIDTH-1:0]             o_bottom_push_act_data,
    output  logic                                  o_bottom_push_data_last,
    output  logic [`NUM_ARRAYS-1:0]                o_bottom_push_en,
    input   logic                                  i_bottom_push_fifo_full,

    //      Weight SRAM ports
    output  logic [WT_ADDR_WIDTH-1:0]               o_wt_sram_rd_addr, //so this is to read from weight sram which we'll get from im2col_gen
    output  logic                                   o_wt_sram_rd_en, //this is to read from weight sram which we'll get from im2col_gen
    output  logic [WT_ADDR_WIDTH-1:0]               o_wt_mem_wr_addr, //this is the weight write address we'll get from mmu - when we want to load weights.
    output  logic [WORD_SIZE-1:0]                   o_wt_mem_wr_data, //this is the data we'll get from the off chip memory and through the mmu - we need the mmu because it parses the words
    output  logic [WT_BANKS-1:0]                    o_wt_mem_wr_en, //this gives us the sram_selection when we load weights
   

    // Local weight SRAM MMU writes
    // input  logic [WT_ADDR_WIDTH-1:0]               i_wt_sram_wr_addr,
    // input  logic                                   i_wt_sram_wr_en,
    // input  logic [DATA_WIDTH*WORD_SIZE-1:0]        i_wt_sram_wr_data,

    // Output Fifo - top
    output logic [`ARRAY_SIZE*OUTPUT_WIDTH-1:0]    o_top_pop_data,
    input  logic                                   i_top_pop_en,
    output logic                                   o_top_pop_empty, 
    output logic                                   o_top_rd_almost_empty,
    output logic                                   o_top_rd_full

    // Output Fifo - bottom
    output logic [`ARRAY_SIZE*OUTPUT_WIDTH-1:0]    o_bottom_pop_data,
    input  logic                                   i_bottom_pop_en,
    output logic                                   o_bottom_pop_empty, 
    output logic                                   o_bottom_rd_almost_empty,
    output logic                                   o_bottom_rd_full

);
endmodule