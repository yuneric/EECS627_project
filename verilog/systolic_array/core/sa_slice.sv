module sa_slice #(
    parameter ARRAY_SIZE    = 8,
    parameter DATA_WIDTH    = 8,
    parameter WORD_SIZE     = 8,
    parameter PSUM_WIDTH    = 32,
    parameter OUTPUT_WIDTH  = 8,
    parameter SHIFT_WIDTH   = 5,
    parameter FIFO_DEPTH    = 16,
    parameter WT_ADDR_WIDTH  = 11
)(
    input  logic                                   i_clk_sys,   // system-side clock (FIFO write / controller domain)
    input  logic                                   i_clk_sa,    // systolic array-side clock (FIFO read / frontend / backend)
    input  logic                                   i_rst_n,

    // Backend control (all of these signals need proper cdc)
    input   logic                                 i_cdc_req, 
    output  logic                                 o_cdc_ack,
    input   logic                                 i_relu_en,
    input   logic [SHIFT_WIDTH-1:0]               i_shift_by,
    input   logic                                 i_maxpool_en,

    // Input Fifo
    input  logic [DATA_WIDTH*ARRAY_SIZE-1:0]       i_push_act_data,
    input  logic                                   i_push_data_last,
    input  logic                                   i_push_en,
    output logic                                   o_push_fifo_full,

    // Local weight SRAM ports
    input  logic [WT_ADDR_WIDTH-1:0]               i_wt_sram_rd_addr,
    input  logic                                   i_wt_sram_rd_en,

    // Local weight SRAM MMU writes
    input  logic [WT_ADDR_WIDTH-1:0]               i_wt_sram_wr_addr,
    input  logic                                   i_wt_sram_wr_en,
    input  logic [DATA_WIDTH*WORD_SIZE-1:0]        i_wt_sram_wr_data,

    // Output Fifo
    output logic [ARRAY_SIZE*OUTPUT_WIDTH-1:0]     o_pop_data,
    input  logic                                   i_pop_en,
    output logic                                   o_pop_empty
);
    logic weight_sram_cen_n;
    logic weight_sram_wen_n;

    logic [DATA_WIDTH*ARRAY_SIZE-1:0] act_fifo_rdata;
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] weight_fifo_rdata;
    logic                             info_fifo_rdata;
    
    // bank mux between reading weights for compute and programming weights for MMU
    logic [WT_ADDR_WIDTH-1:0]        weight_sram_addr;
    logic [DATA_WIDTH*WORD_SIZE-1:0] weight_sram_rdata;

    //assign weight_sram_wr_en = i_wt_sram_wr_en;
    //assign weight_sram_rd_en = i_wt_sram_rd_en;
    assign weight_sram_cen_n = ~(i_wt_sram_rd_en | i_wt_sram_wr_en);
    assign weight_sram_wen_n = ~i_wt_sram_wr_en;
    assign weight_sram_addr  = i_wt_sram_wr_en ? i_wt_sram_wr_addr : i_wt_sram_rd_addr;

    sp2048x64m8 u_wt_sram (
        .Q   (weight_sram_rdata),
        .CLK (i_clk_sys),
        .CEN (weight_sram_cen_n),
        .WEN (weight_sram_wen_n),
        .A   (weight_sram_addr),
        .D   (i_wt_sram_wr_data)
    );

    //assign wt_rd_data = weight_sram_rdata;

    // logic [DATA_WIDTH * ARRAY_SIZE-1:0] sa_weight_wr_data = weight_sram_rdata[DATA_WIDTH * ARRAY_SIZE-1:0];
    // logic sa_wr_en = i_stream_wr_en & ~wt_wr_en;


    // stage the weights and activations for removing timing violations
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] staged_act_data;
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] staged_weight_data;
    logic                             staged_info_data;
    logic                             staged_push_en;

    always_ff @(posedge i_clk_sys or negedge i_rst_n) begin
        if(!i_rst_n) begin
            staged_act_data <= '0;
            staged_weight_data <= '0;
            staged_info_data <= 1'b0;
            staged_push_en <= 1'b0;
        end else begin
            staged_act_data <= i_push_act_data;
            staged_weight_data <= weight_sram_rdata;
            staged_info_data <= i_push_data_last;
            staged_push_en <= i_push_en;
        end
    end


    // INPUT BUFFER TO SA
    // logic act_fifo_empty; 
    // logic weight_fifo_empty; 
    // logic info_fifo_empty;
    // logic act_fifo_full;  
    // logic weight_fifo_full;  
    // logic info_fifo_full;
    logic fifo_pop_en;
    logic all_three_fifo_available;

    // act_width + weight_width + 1 (for info width)
    localparam int INPUT_FIFO_W = 2 * DATA_WIDTH * ARRAY_SIZE + 1;
    logic [INPUT_FIFO_W-1:0] input_fifo_wdata;
    logic [INPUT_FIFO_W-1:0] input_fifo_rdata;
    logic                    input_fifo_empty;
    logic                    input_fifo_full;

    // assign all_three_fifo_available = !act_fifo_empty && !weight_fifo_empty && !info_fifo_empty;
    assign all_three_fifo_available = !input_fifo_empty;
    // assign o_push_fifo_full = act_fifo_full | weight_fifo_full | info_fifo_full;
    assign o_push_fifo_full = input_fifo_full;
    assign input_fifo_wdata = {staged_info_data, staged_weight_data, staged_act_data};
    assign {info_fifo_rdata, weight_fifo_rdata, act_fifo_rdata} = input_fifo_rdata;

    // INPUT FIFOS
    // async_fifo #(
    //     .WIDTH(DATA_WIDTH * ARRAY_SIZE),
    //     .DEPTH(FIFO_DEPTH)
    // ) u_act_fifo (
    //     .i_wr_clk         (i_clk_sys),
    //     .i_wr_rst_n       (i_rst_n),
    //     //.i_wr_data        (i_push_act_data),
    //     .i_wr_data        (staged_act_data),
    //     .i_wr_en          (staged_push_en),
    //     .o_wr_empty       (),
    //     .o_wr_almost_empty(),
    //     .o_wr_half_full   (),
    //     .o_wr_almost_full (act_fifo_full),
    //     .o_wr_full        (),

    //     .i_rd_clk         (i_clk_sa),
    //     .i_rd_rst_n       (i_rst_n),
    //     .o_rd_data        (act_fifo_rdata),
    //     .i_rd_en          (fifo_pop_en),
    //     .o_rd_empty       (),
    //     .o_rd_almost_empty(act_fifo_empty),
    //     .o_rd_half_full   (),
    //     .o_rd_almost_full (),
    //     .o_rd_full        ()
    // );

    async_fifo #(
        .WIDTH(INPUT_FIFO_W),
        .DEPTH(FIFO_DEPTH)
    ) u_weight_act_info_fifo (
        .i_wr_clk         (i_clk_sys),
        .i_wr_rst_n       (i_rst_n),
        //.i_wr_data        (i_push_act_data),
        .i_wr_data        (input_fifo_wdata),
        .i_wr_en          (staged_push_en),
        .o_wr_empty       (),
        .o_wr_almost_empty(),
        .o_wr_half_full   (),
        .o_wr_almost_full (input_fifo_full),
        .o_wr_full        (),

        .i_rd_clk         (i_clk_sa),
        .i_rd_rst_n       (i_rst_n),
        .o_rd_data        (input_fifo_rdata),
        .i_rd_en          (fifo_pop_en),
        .o_rd_empty       (),
        .o_rd_almost_empty(input_fifo_empty),
        .o_rd_half_full   (),
        .o_rd_almost_full (),
        .o_rd_full        ()
    );

    // async_fifo #(
    //     .WIDTH(DATA_WIDTH * ARRAY_SIZE),
    //     .DEPTH(FIFO_DEPTH)
    // ) u_weight_fifo (
    //     .i_wr_clk         (i_clk_sys),
    //     .i_wr_rst_n       (i_rst_n),
    //     //.i_wr_data        (weight_sram_rdata),
    //     .i_wr_data        (staged_weight_data),
    //     .i_wr_en          (staged_push_en),
    //     .o_wr_empty       (),
    //     .o_wr_almost_empty(),
    //     .o_wr_half_full   (),
    //     .o_wr_almost_full (weight_fifo_full),
    //     .o_wr_full        (),

    //     .i_rd_clk         (i_clk_sa),
    //     .i_rd_rst_n       (i_rst_n),
    //     .o_rd_data        (weight_fifo_rdata),
    //     .i_rd_en          (fifo_pop_en),
    //     .o_rd_empty       (),
    //     .o_rd_almost_empty(weight_fifo_empty),
    //     .o_rd_half_full   (),
    //     .o_rd_almost_full (),
    //     .o_rd_full        ()
    // );

    // async_fifo #(
    //     .WIDTH(1),
    //     .DEPTH(FIFO_DEPTH)
    // ) u_info_fifo (
    //     .i_wr_clk         (i_clk_sys),
    //     .i_wr_rst_n       (i_rst_n),
    //     //.i_wr_data        (i_push_data_last),
    //     .i_wr_data        (staged_info_data),
    //     .i_wr_en          (staged_push_en),
    //     .o_wr_empty       (),
    //     .o_wr_almost_empty(),
    //     .o_wr_half_full   (),
    //     .o_wr_almost_full (info_fifo_full),
    //     .o_wr_full        (),

    //     .i_rd_clk         (i_clk_sa),
    //     .i_rd_rst_n       (i_rst_n),
    //     .o_rd_data        (info_fifo_rdata),
    //     .i_rd_en          (fifo_pop_en),
    //     .o_rd_empty       (),
    //     .o_rd_almost_empty(info_fifo_empty),
    //     .o_rd_half_full   (),
    //     .o_rd_almost_full (),
    //     .o_rd_full        ()
    // );

    // Perform the cdc crossing for the maxpool, relu, and shift amt
    logic internal_relu_en;
    logic internal_maxpool_en;
    logic [SHIFT_WIDTH-1:0] internal_shift_by;
    logic cdc_req1, cdc_req2;
    logic cdc_ack1, cdc_ack2;
    
    always_ff @(posedge i_clk_sa) begin
        // Syncronization of REQ
        cdc_req2 <= cdc_req1;
        cdc_req1 <= i_cdc_req;

        // Perform Handshake
        cdc_ack1 <= 0;
        if(cdc_req2) begin
            cdc_ack1 <= 1;
            internal_relu_en <= i_relu_en;
            internal_maxpool_en <= i_maxpool_en;
            internal_shift_by <= i_shift_by;
        end
    end

    always_ff @(posedge i_clk_sys) begin
        // Syncronization of ACK
        o_cdc_ack <= cdc_ack2;
        cdc_ack2 <= cdc_ack1;
    end

    // SA TO OUTPUT BUFFER
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] final_out;
    logic                             final_valid;

    // SYSTOLIC ARRAY
    systolic_array_system #(
        .ARRAY_SIZE   (ARRAY_SIZE),
        .DATA_WIDTH   (DATA_WIDTH),
        .PSUM_WIDTH   (PSUM_WIDTH),
        .OUTPUT_WIDTH (OUTPUT_WIDTH),
        .SHIFT_WIDTH  (SHIFT_WIDTH)
    ) u_sa (
        // Input side
        .i_clk                 (i_clk_sa),
        .i_rst_n               (i_rst_n),
        .i_fifo_act_data       (act_fifo_rdata),
        .i_fifo_weight_data    (weight_fifo_rdata),
        .i_fifo_info_data      (info_fifo_rdata),
        .i_fifo_data_available (all_three_fifo_available),
        .o_fifo_rd_en          (fifo_pop_en),
        .i_relu_en             (internal_relu_en),
        .i_maxpool_en          (internal_maxpool_en),
        .i_shift_by            (internal_shift_by),

        // Output Side
        .o_final_out           (final_out),
        .o_final_valid         (final_valid)
    );

    // OUTPUT FIFO
    async_fifo #(
        .WIDTH(DATA_WIDTH * ARRAY_SIZE),
        .DEPTH(FIFO_DEPTH)
    ) u_output_fifo (
        .i_wr_clk         (i_clk_sa),
        .i_wr_rst_n       (i_rst_n),
        .i_wr_data        (final_out),
        .i_wr_en          (final_valid),
        .o_wr_empty       (),
        .o_wr_almost_empty(),
        .o_wr_half_full   (),
        .o_wr_almost_full (),
        .o_wr_full        (),

        .i_rd_clk         (i_clk_sys),
        .i_rd_rst_n       (i_rst_n),
        .o_rd_data        (o_pop_data),
        .i_rd_en          (i_pop_en),
        .o_rd_empty       (o_pop_empty),
        .o_rd_almost_empty(),
        .o_rd_half_full   (),
        .o_rd_almost_full (),
        .o_rd_full        ()
    );

    

endmodule
