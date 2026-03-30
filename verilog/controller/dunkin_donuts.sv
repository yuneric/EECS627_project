`define NUM_ARRAYS 8
`define ARRAY_SIZE 8

module dunkin_donuts #(
    parameter PSUM_WIDTH            = 32,
    parameter SHIFT_WIDTH           = 5,
    parameter INPUT_FIFO_DEPTH      = 16, 
    parameter INPUT_FIFO_AF_LVL     = 5, // needs 4 pushes of headsup
    parameter OUTPUT_FIFO_DEPTH     = 8,
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

    // ACT/OUTPUT SRAM interface
    output                            o_b0_s0_cen   ,
    output                            o_b0_s0_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b0_s0_rdata , 
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
    // Config - Top
    output                           o_top_cdc_req   ,
    input                            i_top_cdc_ack   ,
    output                           o_top_relu_en   ,
    output [4:0]                     o_top_shift_by  ,
    output                           o_top_maxpool_en,

    // Config - Bottom
    output                           o_bottom_cdc_req   ,
    input                            i_bottom_cdc_ack   ,
    output                           o_bottom_relu_en   ,
    output [4:0]                     o_bottom_shift_by  ,
    output                           o_bottom_maxpool_en,

    // Input Fifos - Top (Sliced in half)
    output  logic [NPU_DATA_WIDTH-1:0]             o_top_push_act_data,
    output  logic                                  o_top_push_data_last,
    output  logic [(`NUM_ARRAYS/2)-1:0]            o_top_push_en,
    input   logic                                  i_top_push_fifo_full,

    // Input Fifos - Bottom (Sliced in half)
    output  logic [NPU_DATA_WIDTH-1:0]             o_bottom_push_act_data,
    output  logic                                  o_bottom_push_data_last,
    output  logic [(`NUM_ARRAYS/2)-1:0]            o_bottom_push_en,
    input   logic                                  i_bottom_push_fifo_full,

    // Weight SRAM ports
    output  logic [WT_ADDR_WIDTH-1:0]               o_wt_sram_rd_addr, 
    output  logic                                   o_wt_sram_rd_en, 
    output  logic [WT_ADDR_WIDTH-1:0]               o_wt_mem_wr_addr, 
    output  logic [WORD_SIZE-1:0]                   o_wt_mem_wr_data, 
    output  logic [WT_BANKS-1:0]                    o_wt_mem_wr_en, 

    // Output Fifo - Top (Sliced in half)
    output logic [(`ARRAY_SIZE/2)*OUTPUT_WIDTH-1:0] o_top_pop_data,
    input  logic                                    i_top_pop_en,
    output logic                                    o_top_pop_empty, 
    output logic                                    o_top_rd_almost_empty,
    output logic                                    o_top_rd_full,

    // Output Fifo - Bottom (Sliced in half)
    output logic [(`ARRAY_SIZE/2)*OUTPUT_WIDTH-1:0] o_bottom_pop_data,
    input  logic                                    i_bottom_pop_en,
    output logic                                    o_bottom_pop_empty, 
    output logic                                    o_bottom_rd_almost_empty,
    output logic                                    o_bottom_rd_full
);

    // =========================================================================
    // Internal Signals to connect to Munchkin's unified Systolic Array ports
    // =========================================================================
    logic                                   munchkin_cdc_req;
    logic                                   munchkin_cdc_ack;
    logic                                   munchkin_relu_en;
    logic [4:0]                             munchkin_shift_by;
    logic                                   munchkin_maxpool_en;

    logic [NPU_DATA_WIDTH-1:0]              munchkin_push_act_data;
    logic                                   munchkin_push_data_last;
    logic [`NUM_ARRAYS-1:0]                 munchkin_push_en;
    logic                                   munchkin_push_fifo_full;

    logic [`ARRAY_SIZE*OUTPUT_WIDTH-1:0]    munchkin_pop_data;
    logic                                   munchkin_pop_en;
    logic                                   munchkin_pop_empty;
    logic                                   munchkin_rd_almost_empty;
    logic                                   munchkin_rd_full;


    // =========================================================================
    // Split Logic: Broadcast shared signals, Slice parallel buses
    // =========================================================================
    
    // 1. Config Signals (Broadcast identical control to both halves)
    assign o_top_cdc_req       = munchkin_cdc_req;
    assign o_bottom_cdc_req    = munchkin_cdc_req;

    assign o_top_relu_en       = munchkin_relu_en;
    assign o_bottom_relu_en    = munchkin_relu_en;

    assign o_top_shift_by      = munchkin_shift_by;
    assign o_bottom_shift_by   = munchkin_shift_by;

    assign o_top_maxpool_en    = munchkin_maxpool_en;
    assign o_bottom_maxpool_en = munchkin_maxpool_en;

    // 2. Input Push Data (Broadcast data, but Slice the enables)
    assign o_top_push_act_data     = munchkin_push_act_data;
    assign o_bottom_push_act_data  = munchkin_push_act_data;

    assign o_top_push_data_last    = munchkin_push_data_last;
    assign o_bottom_push_data_last = munchkin_push_data_last;

    // Slice the NUM_ARRAYS bus in half:
    // Top gets upper half [7:4], Bottom gets lower half [3:0]
    assign o_top_push_en           = munchkin_push_en[`NUM_ARRAYS-1 : `NUM_ARRAYS/2];
    assign o_bottom_push_en        = munchkin_push_en[(`NUM_ARRAYS/2)-1 : 0];

    // 3. Output Pop Data (Slice the data buses)
    // Top gets upper half of the bits, Bottom gets lower half
    assign o_top_pop_data          = munchkin_pop_data[`ARRAY_SIZE*OUTPUT_WIDTH-1 : (`ARRAY_SIZE/2)*OUTPUT_WIDTH];
    assign o_bottom_pop_data       = munchkin_pop_data[(`ARRAY_SIZE/2)*OUTPUT_WIDTH-1 : 0];

    // Assuming empty/full status is shared/global based on single bit from munchkin
    assign o_top_pop_empty          = munchkin_pop_empty;
    assign o_bottom_pop_empty       = munchkin_pop_empty;

    assign o_top_rd_almost_empty    = munchkin_rd_almost_empty;
    assign o_bottom_rd_almost_empty = munchkin_rd_almost_empty;

    assign o_top_rd_full            = munchkin_rd_full;
    assign o_bottom_rd_full         = munchkin_rd_full;


    // =========================================================================
    // Combine Logic: Safely merge Top and Bottom inputs going into Munchkin
    // =========================================================================
    
    // Wait for BOTH halves to acknowledge a CDC request
    assign munchkin_cdc_ack = i_top_cdc_ack & i_bottom_cdc_ack;

    // Stall the pipeline if EITHER half is full
    assign munchkin_push_fifo_full = i_top_push_fifo_full | i_bottom_push_fifo_full;

    // Assuming both halves pop together, register a pop if either side asserts it
    assign munchkin_pop_en = i_top_pop_en | i_bottom_pop_en;


    // =========================================================================
    // Munchkin Core Instantiation
    // =========================================================================
    munchkin #(
        .CPU_ADDR_WIDTH     (CPU_ADDR_WIDTH),
        .CPU_DATA_WIDTH     (CPU_DATA_WIDTH),
        .NPU_ACT_ADDR_WIDTH (NPU_ACT_ADDR_WIDTH),
        .NPU_WT_ADDR_WIDTH  (NPU_WT_ADDR_WIDTH),
        .NPU_DATA_WIDTH     (NPU_DATA_WIDTH),
        .DIM_WIDTH          (DIM_WIDTH),
        .MMIO_ADDR          (MMIO_ADDR),
        .MMIO_SIZE          (MMIO_SIZE),
        .ADDR_WIDTH         (ADDR_WIDTH),
        .DATA_WIDTH         (DATA_WIDTH),
        .WT_ADDR_WIDTH      (WT_ADDR_WIDTH),
        .WORD_SIZE          (WORD_SIZE),
        .OUTPUT_WIDTH       (OUTPUT_WIDTH),
        .DIM                (DIM),
        .WT_BANKS           (WT_BANKS)
    ) u_munchkin (
        .i_clk              (i_clk),
        .i_rstn_sync        (i_rstn_sync),
        .i_rstn_async       (i_rstn_async),

        // CPU Trace
        .o_trap             (o_trap),
        .o_trace_valid      (o_trace_valid),
        .o_trace_data       (o_trace_data),

        // AXI Arbiter
        .o_mem_valid        (o_mem_valid),
        .i_mem_ready        (i_mem_ready),
        .o_mem_addr         (o_mem_addr),
        .o_mem_wdata        (o_mem_wdata),
        .o_mem_wstrb        (o_mem_wstrb),
        .i_mem_rdata        (i_mem_rdata),

        // ACT/OUTPUT SRAM 
        .o_b0_s0_cen        (o_b0_s0_cen),
        .o_b0_s0_wen        (o_b0_s0_wen),
        .i_b0_s0_rdata      (i_b0_s0_rdata),
        .o_b0_s0_addr       (o_b0_s0_addr),
        .o_b0_s0_wdata      (o_b0_s0_wdata),

        .o_b0_s1_cen        (o_b0_s1_cen),
        .o_b0_s1_wen        (o_b0_s1_wen),
        .i_b0_s1_rdata      (i_b0_s1_rdata),
        .o_b0_s1_addr       (o_b0_s1_addr),
        .o_b0_s1_wdata      (o_b0_s1_wdata),

        .o_b1_s0_cen        (o_b1_s0_cen),
        .o_b1_s0_wen        (o_b1_s0_wen),
        .i_b1_s0_rdata      (i_b1_s0_rdata),
        .o_b1_s0_addr       (o_b1_s0_addr),
        .o_b1_s0_wdata      (o_b1_s0_wdata),

        .o_b1_s1_cen        (o_b1_s1_cen),
        .o_b1_s1_wen        (o_b1_s1_wen),
        .i_b1_s1_rdata      (i_b1_s1_rdata),
        .o_b1_s1_addr       (o_b1_s1_addr),
        .o_b1_s1_wdata      (o_b1_s1_wdata),

        // Internal Systolic Array Connections
        .o_cdc_req          (munchkin_cdc_req),
        .i_cdc_ack          (munchkin_cdc_ack),
        .o_relu_en          (munchkin_relu_en),
        .o_shift_by         (munchkin_shift_by),
        .o_maxpool_en       (munchkin_maxpool_en),

        .o_push_act_data    (munchkin_push_act_data),
        .o_push_data_last   (munchkin_push_data_last),
        .o_push_en          (munchkin_push_en),
        .i_push_fifo_full   (munchkin_push_fifo_full),

        .o_pop_data         (munchkin_pop_data),
        .i_pop_en           (munchkin_pop_en),
        .o_pop_empty        (munchkin_pop_empty),
        .o_rd_almost_empty  (munchkin_rd_almost_empty),
        .o_rd_full          (munchkin_rd_full),

        // Weight SRAM Ports
        .o_wt_sram_rd_addr  (o_wt_sram_rd_addr),
        .o_wt_sram_rd_en    (o_wt_sram_rd_en),
        .o_wt_mem_wr_addr   (o_wt_mem_wr_addr),
        .o_wt_mem_wr_data   (o_wt_mem_wr_data),
        .o_wt_mem_wr_en     (o_wt_mem_wr_en)
    );

endmodule