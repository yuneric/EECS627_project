`define NUM_ARRAYS 8

module dunkin_donuts #(
    parameter CPU_ADDR_WIDTH        = 32,
    parameter CPU_DATA_WIDTH        = 32,
    parameter NPU_ACT_ADDR_WIDTH    = 12,
    parameter NPU_WT_ADDR_WIDTH     = 11,
    parameter NPU_DATA_WIDTH        = 64,
    parameter DIM_WIDTH             = 10,
    parameter MMIO_ADDR             = 32'h1000_1000,//32'h2000_0000,
    parameter MMIO_SIZE             = 32'h0000_0100
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
    output                      o_mem_valid,
    input                       i_mem_ready,
    output [CPU_ADDR_WIDTH-1:0] o_mem_addr ,
    output [CPU_DATA_WIDTH-1:0] o_mem_wdata,
    output [3:0]                o_mem_wstrb,
    input  [CPU_DATA_WIDTH-1:0] i_mem_rdata,

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

    // ==========================================
    // Systolic array ports (Top)
    // ==========================================
    output [2:0]                     o_top_clk_sel   ,
    output                           o_top_cdc_req   ,
    input  [(`NUM_ARRAYS/2)-1:0]     i_top_cdc_ack   , // FIXED: Now a 4-bit bus
    output                           o_top_relu_en   ,
    output [4:0]                     o_top_shift_by  ,
    output                           o_top_maxpool_en,

    output  logic [NPU_DATA_WIDTH-1:0]              o_top_push_act_data,
    output  logic                                   o_top_push_data_last,
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_top_push_en,
    input   logic [(`NUM_ARRAYS/2)-1:0]             i_top_push_af,

    output  logic [NPU_WT_ADDR_WIDTH-1:0]           o_top_wt_sram_rd_addr, 
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_top_wt_sram_rd_en, 
    output  logic [NPU_WT_ADDR_WIDTH-1:0]           o_top_wt_mem_wr_addr, 
    output  logic [NPU_DATA_WIDTH-1:0]              o_top_wt_mem_wr_data, 
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_top_wt_mem_wr_en, 

    input   logic [NPU_DATA_WIDTH-1:0]              i_top_pop_data,
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_top_pop_en,
    input   logic [(`NUM_ARRAYS/2)-1:0]             i_top_pop_ae,
    input   logic [(`NUM_ARRAYS/2)-1:0]             i_top_pop_full,

    // ==========================================
    // Systolic array ports (Bottom)
    // ==========================================
    output [2:0]                     o_bottom_clk_sel   ,
    output                           o_bottom_cdc_req   ,
    input  [(`NUM_ARRAYS/2)-1:0]     i_bottom_cdc_ack   , // FIXED: Now a 4-bit bus
    output                           o_bottom_relu_en   ,
    output [4:0]                     o_bottom_shift_by  ,
    output                           o_bottom_maxpool_en,

    output  logic [NPU_DATA_WIDTH-1:0]              o_bottom_push_act_data,
    output  logic                                   o_bottom_push_data_last,
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_bottom_push_en,
    input   logic [(`NUM_ARRAYS/2)-1:0]             i_bottom_push_af,

    output  logic [NPU_WT_ADDR_WIDTH-1:0]           o_bottom_wt_sram_rd_addr, 
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_bottom_wt_sram_rd_en, 
    output  logic [NPU_WT_ADDR_WIDTH-1:0]           o_bottom_wt_mem_wr_addr, 
    output  logic [NPU_DATA_WIDTH-1:0]              o_bottom_wt_mem_wr_data, 
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_bottom_wt_mem_wr_en, 

    input   logic [NPU_DATA_WIDTH-1:0]              i_bottom_pop_data,
    output  logic [(`NUM_ARRAYS/2)-1:0]             o_bottom_pop_en,
    input   logic [(`NUM_ARRAYS/2)-1:0]             i_bottom_pop_ae,
    input   logic [(`NUM_ARRAYS/2)-1:0]             i_bottom_pop_full
);

    // =========================================================================
    // Internal Signals to connect to Munchkin's unified ports
    // =========================================================================
    logic [2:0]                             munchkin_clk_sel;
    logic                                   munchkin_cdc_req;
    logic [`NUM_ARRAYS-1:0]                 munchkin_cdc_ack;
    logic                                   munchkin_relu_en;
    logic [4:0]                             munchkin_shift_by;
    logic                                   munchkin_maxpool_en;

    logic [NPU_DATA_WIDTH-1:0]              munchkin_push_act_data;
    logic                                   munchkin_push_data_last;
    logic [`NUM_ARRAYS-1:0]                 munchkin_push_en;
    logic [`NUM_ARRAYS-1:0]                 munchkin_push_af;

    logic [NPU_WT_ADDR_WIDTH-1:0]           munchkin_wt_sram_rd_addr;
    logic [`NUM_ARRAYS-1:0]                 munchkin_wt_sram_rd_en;
    logic [NPU_WT_ADDR_WIDTH-1:0]           munchkin_wt_mem_wr_addr;
    logic [NPU_DATA_WIDTH-1:0]              munchkin_wt_mem_wr_data;
    logic [`NUM_ARRAYS-1:0]                 munchkin_wt_mem_wr_en;

    logic [NPU_DATA_WIDTH-1:0]              munchkin_pop_data;
    logic [`NUM_ARRAYS-1:0]                 munchkin_pop_en;
    logic [`NUM_ARRAYS-1:0]                 munchkin_pop_ae;
    logic [`NUM_ARRAYS-1:0]                 munchkin_pop_full;


    // =========================================================================
    // Split Logic: Broadcast shared signals, Slice parallel buses (Top/Bottom)
    // =========================================================================
    
    // Config Signals
    assign o_top_clk_sel            = munchkin_clk_sel;
    assign o_bottom_clk_sel         = munchkin_clk_sel;
    assign o_top_cdc_req            = munchkin_cdc_req;
    assign o_bottom_cdc_req         = munchkin_cdc_req;
    assign o_top_relu_en            = munchkin_relu_en;
    assign o_bottom_relu_en         = munchkin_relu_en;
    assign o_top_shift_by           = munchkin_shift_by;
    assign o_bottom_shift_by        = munchkin_shift_by;
    assign o_top_maxpool_en         = munchkin_maxpool_en;
    assign o_bottom_maxpool_en      = munchkin_maxpool_en;

    // Input Push Logic
    assign o_top_push_act_data      = munchkin_push_act_data;
    assign o_bottom_push_act_data   = munchkin_push_act_data;
    assign o_top_push_data_last     = munchkin_push_data_last;
    assign o_bottom_push_data_last  = munchkin_push_data_last;

    assign o_top_push_en            = munchkin_push_en[`NUM_ARRAYS-1 : `NUM_ARRAYS/2];
    assign o_bottom_push_en         = munchkin_push_en[(`NUM_ARRAYS/2)-1 : 0];

    // Weight SRAM Logic
    assign o_top_wt_sram_rd_addr    = munchkin_wt_sram_rd_addr;
    assign o_bottom_wt_sram_rd_addr = munchkin_wt_sram_rd_addr;
    assign o_top_wt_mem_wr_addr     = munchkin_wt_mem_wr_addr;
    assign o_bottom_wt_mem_wr_addr  = munchkin_wt_mem_wr_addr;
    assign o_top_wt_mem_wr_data     = munchkin_wt_mem_wr_data;
    assign o_bottom_wt_mem_wr_data  = munchkin_wt_mem_wr_data;

    assign o_top_wt_sram_rd_en      = munchkin_wt_sram_rd_en[`NUM_ARRAYS-1 : `NUM_ARRAYS/2];
    assign o_bottom_wt_sram_rd_en   = munchkin_wt_sram_rd_en[(`NUM_ARRAYS/2)-1 : 0];
    assign o_top_wt_mem_wr_en       = munchkin_wt_mem_wr_en[`NUM_ARRAYS-1 : `NUM_ARRAYS/2];
    assign o_bottom_wt_mem_wr_en    = munchkin_wt_mem_wr_en[(`NUM_ARRAYS/2)-1 : 0];

    // Output Pop Enables (From NPU to FIFOs)
    assign o_top_pop_en             = munchkin_pop_en[`NUM_ARRAYS-1 : `NUM_ARRAYS/2];
    assign o_bottom_pop_en          = munchkin_pop_en[(`NUM_ARRAYS/2)-1 : 0];


    // =========================================================================
    // Combine Logic: Merge Top and Bottom inputs going into Munchkin
    // =========================================================================
    
    // Concatenate flags
    assign munchkin_cdc_ack  = {i_top_cdc_ack, i_bottom_cdc_ack};
    assign munchkin_push_af  = {i_top_push_af, i_bottom_push_af};
    assign munchkin_pop_ae   = {i_top_pop_ae, i_bottom_pop_ae};
    assign munchkin_pop_full = {i_top_pop_full, i_bottom_pop_full};

    //send in correct data.
    // assign munchkin_pop_data = (|o_top_pop_en)    ? i_top_pop_data : 
    //                            (|o_bottom_pop_en) ? i_bottom_pop_data : 
    //                            '0;
    assign munchkin_pop_data = (|munchkin_pop_en[`NUM_ARRAYS-1 : `NUM_ARRAYS/2]) ? i_top_pop_data : i_bottom_pop_data;




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
        .MMIO_SIZE          (MMIO_SIZE)
    ) u_munchkin (
        .i_clk              (i_clk),
        .o_clk_sel          (munchkin_clk_sel),
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

        // Push
        .o_push_act_data    (munchkin_push_act_data),
        .o_push_data_last   (munchkin_push_data_last),
        .o_push_en          (munchkin_push_en),
        .i_push_af          (munchkin_push_af),

        // Weight SRAM
        .o_wt_sram_rd_addr  (munchkin_wt_sram_rd_addr),
        .o_wt_sram_rd_en    (munchkin_wt_sram_rd_en),
        .o_wt_mem_wr_addr   (munchkin_wt_mem_wr_addr),
        .o_wt_mem_wr_data   (munchkin_wt_mem_wr_data),
        .o_wt_mem_wr_en     (munchkin_wt_mem_wr_en),

        // Pop
        .i_pop_data         (munchkin_pop_data),
        .o_pop_en           (munchkin_pop_en),
        .i_pop_ae           (munchkin_pop_ae),
        .i_pop_full         (munchkin_pop_full)
    );

endmodule