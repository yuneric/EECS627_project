
module async_fifo #(
    parameter WIDTH = 64,
    parameter DEPTH = 16,
    parameter PUSH_AE_LVL = 1,
    parameter PUSH_AF_LVL = 1,
    parameter POP_AE_LVL = 7,
    parameter POP_AF_LVL = 7,
    parameter ERR_MODE = 0,
    parameter PUSH_SYNC = 2,
    parameter POP_SYNC = 2,
    parameter RST_MODE = 0
)(
    // Write clock domain
    input              i_wr_clk,
    input              i_wr_rst_n,
    input  [WIDTH-1:0] i_wr_data,
    input              i_wr_en,
    output             o_wr_empty,
    output             o_wr_almost_empty,
    output             o_wr_half_full,
    output             o_wr_almost_full,
    output             o_wr_full,

    // Read clock domain
    input              i_rd_clk,
    input              i_rd_rst_n,
    output [WIDTH-1:0] o_rd_data,
    input              i_rd_en,
    output             o_rd_empty,
    output             o_rd_almost_empty,
    output             o_rd_half_full,
    output             o_rd_almost_full,
    output             o_rd_full
);

   // localparam LVL_W = $clog2(DEPTH) + 1;

    DW_fifo_s2_sf #(
        WIDTH, 
        DEPTH, 
        PUSH_AE_LVL, 
        PUSH_AF_LVL, 
        POP_AE_LVL,
        POP_AF_LVL, 
        ERR_MODE, 
        PUSH_SYNC, 
        POP_SYNC, 
        RST_MODE)
    u_dw_fifo (
        .clk_push(i_wr_clk), 
        .clk_pop(i_rd_clk),
        .rst_n(i_wr_rst_n), 
        .push_req_n(~i_wr_en),
        .pop_req_n(~i_rd_en), 
        .data_in(i_wr_data),
        .push_empty(o_wr_empty), 
        .push_ae(o_wr_almost_empty),
        .push_hf(o_wr_half_full), 
        .push_af(o_wr_almost_full),
        .push_full(o_wr_full), 
        .push_error(),
        .pop_empty(o_rd_empty), 
        .pop_ae(o_rd_almost_empty),
        .pop_hf(o_rd_half_full), 
        .pop_af(o_rd_almost_full),
        .pop_full(o_rd_full), 
        .pop_error(),
        .data_out(o_rd_data) );

endmodule
