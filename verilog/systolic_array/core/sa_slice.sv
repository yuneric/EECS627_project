module sa_slice #(
    parameter PSUM_WIDTH        = 32,
    parameter SHIFT_WIDTH       = 5,
    parameter WT_ADDR_WIDTH     = 11,
    parameter WORD_SIZE         = 64,
    parameter INPUT_FIFO_DEPTH  = 16,
    parameter INPUT_FIFO_AF_LVL = 1,
    parameter OUTPUT_FIFO_DEPTH = 8 
)(
    input  logic                     i_clk_sys,   // system-side clock (FIFO write / controller domain)
//    input  logic                     i_clk_sa,    // systolic array-side clock (FIFO read / frontend / backend)
    input  logic [2:0]               i_clk_sel, 
    input  logic                     i_rst_n,

    // Backend control (all of these signals need proper cdc)
    input  logic                     i_cdc_req, 
    output logic                     o_cdc_ack,
    input  logic                     i_relu_en,
    input  logic [SHIFT_WIDTH-1:0]   i_shift_by,
    input  logic                     i_maxpool_en,

    // Input Fifo
    input  logic [WORD_SIZE-1:0]     i_push_act_data,
    input  logic                     i_push_data_last,
    input  logic                     i_push_en,
    output logic                     o_push_af,

    // Local weight SRAM ports
    input  logic [WT_ADDR_WIDTH-1:0] i_wt_sram_rd_addr,
    input  logic                     i_wt_sram_rd_en,

    // Local weight SRAM MMU writes
    input  logic [WT_ADDR_WIDTH-1:0] i_wt_sram_wr_addr,
    input  logic                     i_wt_sram_wr_en,
    input  logic [WORD_SIZE-1:0]     i_wt_sram_wr_data,

    // Output Fifo
    output logic [WORD_SIZE-1:0]     o_pop_data,
    input  logic                     i_pop_en,
    output logic                     o_pop_empty, 
    output logic                     o_pop_ae,
    output logic                     o_pop_full

);

    // Clock generator for this slice
    wire clk_sa;

    clk_gen u_clk_gen (
        .rstn_i     (i_rst_n),
        .bypass_i   (1'b0),
        .clk_i      (i_clk_sys),
        .osc_sel_i  (i_clk_sel),
        .div_sel_i  (4'b0000),
        .clk_o      (clk_sa),
        .slow_clk_o ()
    );

    logic [WORD_SIZE-1:0] act_fifo_rdata;
    logic [WORD_SIZE-1:0] weight_fifo_rdata;
    logic                 info_fifo_rdata;
    
    // bank mux between reading weights for compute and programming weights for MMU
    wire                        weight_sram_cen_n, weight_sram_wen_n;
    wire [WT_ADDR_WIDTH-1:0]    weight_sram_addr;
    wire [WORD_SIZE-1:0]        weight_sram_rdata;
    wire [WORD_SIZE-1:0]        weight_sram_wrdata;

    //assign weight_sram_wr_en = i_wt_sram_wr_en;
    //assign weight_sram_rd_en = i_wt_sram_rd_en;
    // Add some sim delay so the sram stops whining about violations
    assign #1.5 weight_sram_cen_n   = ~(i_wt_sram_rd_en | i_wt_sram_wr_en);
    assign #1.5 weight_sram_wen_n   = ~i_wt_sram_wr_en;
    assign #1.5 weight_sram_addr    = i_wt_sram_wr_en ? i_wt_sram_wr_addr : i_wt_sram_rd_addr;
    assign #1.5 weight_sram_wrdata  = i_wt_sram_wr_data;

    sp2048x64m8 u_wt_sram (
        .Q   (weight_sram_rdata),
        .CLK (i_clk_sys),
        .CEN (weight_sram_cen_n),
        .WEN (weight_sram_wen_n),
        .A   (weight_sram_addr),
        .D   (weight_sram_wrdata)
    );

    //assign wt_rd_data = weight_sram_rdata;

    // logic [DATA_WIDTH * ARRAY_SIZE-1:0] sa_weight_wr_data = weight_sram_rdata[DATA_WIDTH * ARRAY_SIZE-1:0];
    // logic sa_wr_en = i_stream_wr_en & ~wt_wr_en;


    // stage the weights and activations for removing timing violations
    logic [WORD_SIZE-1:0] staged_act_data;
    logic [WORD_SIZE-1:0] staged_weight_data;
    logic                 staged_info_data;
    logic                 staged_push_en;
    logic                 staged_wt_sram_rd_en;

    always_ff @(posedge i_clk_sys or negedge i_rst_n) begin
        if(!i_rst_n) begin
            staged_act_data <= '0;
            staged_info_data <= 1'b0;
            staged_push_en <= 1'b0;
            staged_wt_sram_rd_en <= 1'b0;
            staged_weight_data <= '0;
        end else begin
            staged_act_data <= i_push_act_data;
            staged_info_data <= i_push_data_last;
            staged_push_en <= i_push_en;
            staged_wt_sram_rd_en <= i_wt_sram_rd_en;
            // If not rd_en we want to be able to write 0's to the systolic array
            staged_weight_data <=  staged_wt_sram_rd_en ? weight_sram_rdata : '0;
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
    localparam int INPUT_FIFO_W = 2 * WORD_SIZE + 1;
    logic [INPUT_FIFO_W-1:0] input_fifo_wdata;
    logic [INPUT_FIFO_W-1:0] input_fifo_rdata;
    logic                    input_fifo_empty;
    logic                    input_fifo_af;

    // assign all_three_fifo_available = !act_fifo_empty && !weight_fifo_empty && !info_fifo_empty;
    assign all_three_fifo_available = !input_fifo_empty;
    // assign o_push_fifo_full = act_fifo_full | weight_fifo_full | info_fifo_full;
    assign o_push_af = input_fifo_af;
    assign input_fifo_wdata = {staged_info_data, staged_weight_data, staged_act_data};
    assign {info_fifo_rdata, weight_fifo_rdata, act_fifo_rdata} = input_fifo_rdata;

    // INPUT FIFOS

    async_fifo #(
        .WIDTH(INPUT_FIFO_W),
        .DEPTH(INPUT_FIFO_DEPTH),
        .PUSH_AE_LVL(1),
        .PUSH_AF_LVL(INPUT_FIFO_AF_LVL),
        .POP_AE_LVL(7),
        .POP_AF_LVL(7),
        .ERR_MODE(0),
        .PUSH_SYNC(2),
        .POP_SYNC(2),
        .RST_MODE(0)
    ) u_weight_act_info_fifo (
        .i_rst_n       (i_rst_n),

        .i_wr_clk         (i_clk_sys),
        //.i_wr_data        (i_push_act_data),
        .i_wr_data        (input_fifo_wdata),
        .i_wr_en          (staged_push_en),
        .o_wr_empty       (),
        .o_wr_almost_empty(),
        .o_wr_half_full   (),
        .o_wr_almost_full (input_fifo_af),
        .o_wr_full        (),

        .i_rd_clk         (clk_sa),
        .o_rd_data        (input_fifo_rdata),
        .i_rd_en          (fifo_pop_en),
        .o_rd_empty       (),
        .o_rd_almost_empty(input_fifo_empty),
        .o_rd_half_full   (),
        .o_rd_almost_full (),
        .o_rd_full        ()
    );

    // Perform the cdc crossing for the maxpool, relu, and shift amt
    logic internal_relu_en;
    logic internal_maxpool_en;
    logic [SHIFT_WIDTH-1:0] internal_shift_by;
    logic cdc_req1, cdc_req2;
    logic cdc_ack1, cdc_ack2;
    
    always_ff @(posedge clk_sa) begin
        // Syncronization of REQ
        cdc_req2 <= cdc_req1;
        cdc_req1 <= i_cdc_req;

        // Perform feedback
        cdc_ack1 <= 0;
        if(cdc_req2) begin
            cdc_ack1 <= 1;
        end

        // Generate a load enable signal
        if(cdc_req2 & !cdc_ack1) begin
            internal_relu_en <= i_relu_en;
            internal_maxpool_en <= i_maxpool_en;
            internal_shift_by <= i_shift_by;
        end
    end

    always_ff @(posedge i_clk_sys) begin
        // Syncronization of ACK
        cdc_ack2  <= cdc_ack1;
        o_cdc_ack <= cdc_ack2;
    end

    // SA TO OUTPUT BUFFER
    logic [WORD_SIZE-1:0] final_out;
    logic                 final_valid;

    // SYSTOLIC ARRAY
    // systolic_array_system #(
    //     .ARRAY_SIZE   (8),
    //     .DATA_WIDTH   (WORD_SIZE/8),
    //     .PSUM_WIDTH   (PSUM_WIDTH),
    //     .OUTPUT_WIDTH (WORD_SIZE/8),
    //     .SHIFT_WIDTH  (SHIFT_WIDTH)
    // ) u_sa (
    //     // Input side
    //     .i_clk                 (i_clk_sa),
    //     .i_rst_n               (i_rst_n),
    //     .i_fifo_act_data       (act_fifo_rdata),
    //     .i_fifo_weight_data    (weight_fifo_rdata),
    //     .i_fifo_info_data      (info_fifo_rdata),
    //     .i_fifo_data_available (all_three_fifo_available),
    //     .o_fifo_rd_en          (fifo_pop_en),
    //     .i_relu_en             (internal_relu_en),
    //     .i_maxpool_en          (internal_maxpool_en),
    //     .i_shift_by            (internal_shift_by),

    //     // Output Side
    //     .o_final_out           (final_out),
    //     .o_final_valid         (final_valid)
    // );

    sa_sys_power u_sa_sys_power (
        // Input side
        .i_clk                 (clk_sa),
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

    logic [WORD_SIZE-1:0]     pop_data;
    logic                     pop_empty;
    logic                     pop_ae;
    logic                     pop_full;
    // OUTPUT FIFO
    async_fifo #(
        .WIDTH(WORD_SIZE),
        .DEPTH(OUTPUT_FIFO_DEPTH),
        .PUSH_AE_LVL(1),
        .PUSH_AF_LVL(1),
        .POP_AE_LVL(1),
        .POP_AF_LVL(1),
        .ERR_MODE(0),
        .PUSH_SYNC(2),
        .POP_SYNC(2),
        .RST_MODE(0)
    ) u_output_fifo (
        .i_rst_n          (i_rst_n),

        .i_wr_clk         (clk_sa),
        .i_wr_data        (final_out),
        .i_wr_en          (final_valid),
        .o_wr_empty       (),
        .o_wr_almost_empty(),
        .o_wr_half_full   (),
        .o_wr_almost_full (),
        .o_wr_full        (),

        .i_rd_clk         (i_clk_sys),
        .o_rd_data        (pop_data),
        .i_rd_en          (i_pop_en),
        .o_rd_empty       (pop_empty),
        .o_rd_almost_empty(pop_ae),
        .o_rd_half_full   (),
        .o_rd_almost_full (),
        .o_rd_full        (pop_full)
    );

    always_ff @(posedge i_clk_sys) begin
        o_pop_data  <= pop_data;
        o_pop_empty <= pop_empty;
        o_pop_ae    <= pop_ae;
        o_pop_full  <= pop_full;
    end

    

endmodule
