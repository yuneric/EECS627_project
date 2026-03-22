
module async_fifo #(
    parameter WIDTH = 64,
    parameter DEPTH = 4
)(
    // Write clock domain
    input  wire             wr_clk,
    input  wire             wr_rst_n,
    input  wire [WIDTH-1:0] wr_data,
    input  wire             wr_en,
    output wire             almost_full,
    output wire             full,

    // Read clock domain
    input  wire             rd_clk,
    input  wire             rd_rst_n,
    output wire [WIDTH-1:0] rd_data,
    input  wire             rd_en,
    output wire             empty
);

    localparam LVL_W = $clog2(DEPTH) + 1;

    DW_fifo_2c_df #(
        .width      (WIDTH),
        .ram_depth  (DEPTH),
        .clk_ratio(0), // could be any clock domain
        .verif_en(0)
    ) u_dw_fifo (
        // Source domain (write side)
        .clk_s          (wr_clk),
        .rst_s_n        (wr_rst_n),
        .init_s_n       (wr_rst_n),
        .clr_s          (1'b0),
        .ae_level_s     ({LVL_W{1'b0}}),
        .af_level_s     ({{(LVL_W-1){1'b0}}, 1'b1 }),
        .push_s_n       (~wr_en),
        .data_s         (wr_data),

        .clr_sync_s     (),
        .clr_in_prog_s  (),
        .clr_cmplt_s    (),
        .fifo_word_cnt_s(),
        .word_cnt_s     (),
        .fifo_empty_s   (),
        .empty_s        (),
        .almost_empty_s (),
        .half_full_s    (),
        .almost_full_s  (almost_full),
        .full_s         (full),
        .error_s        (),

        //  domain (read side)
        .clk_d          (rd_clk),
        .rst_d_n        (rd_rst_n),
        .init_d_n       (rd_rst_n),
        .clr_d          (1'b0),
        .ae_level_d     ({LVL_W{1'b0}}),
        .af_level_d     ({LVL_W{1'b0}}),
        .pop_d_n        (~rd_en), 

        .clr_sync_d     (),
        .clr_in_prog_d  (),
        .clr_cmplt_d    (),
        .data_d         (rd_data),
        .word_cnt_d     (),
        .empty_d        (empty),
        .almost_empty_d (),
        .half_full_d    (),
        .almost_full_d  (),
        .full_d         (),
        .error_d        (),

        .test           (1'b0)
    );

endmodule
