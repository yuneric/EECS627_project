module sa_sys_power #(
    parameter WORD_SIZE         = 64,
    parameter SHIFT_WIDTH       = 5
)(
    input  wire                                 i_clk,   // compute-side clock (systolic array domain)
    input  wire                                 i_rst_n,

    input  wire  [WORD_SIZE-1:0]                i_fifo_act_data      ,
    input  wire  [WORD_SIZE-1:0]                i_fifo_weight_data   ,
    input  wire                                 i_fifo_info_data     ,
    input  wire                                 i_fifo_data_available,
    output reg                                  o_fifo_rd_en         ,

    input  wire                                 i_relu_en,
    input  wire [SHIFT_WIDTH-1:0]               i_shift_by,
    input  wire                                 i_maxpool_en,

    output reg [WORD_SIZE-1:0]                  o_final_out,
    output reg                                  o_final_valid
);   

    wire fifo_pop_en_lv;
    wire fifo_pop_en_hv;

    wire [WORD_SIZE-1:0] final_out_lv;
    wire [WORD_SIZE-1:0] final_out_hv;
    
    wire final_valid_lv;
    wire final_valid_hv;

    // Want to try and avoid glitches during power up
    // reset should remain asserted until power is good
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            o_fifo_rd_en    <= 0;
            o_final_out     <= 0;
            o_final_valid   <= '0;
        end else begin
            o_fifo_rd_en    <= fifo_pop_en_hv;
            o_final_out     <= final_out_hv;
            o_final_valid   <= final_valid_hv;
        end
    end
    
    systolic_array_system u_sa_sys (
        // Input side
        .i_clk                 (i_clk),
        .i_rst_n               (i_rst_n),
        .i_fifo_act_data       (i_fifo_act_data),
        .i_fifo_weight_data    (i_fifo_weight_data),
        .i_fifo_info_data      (i_fifo_info_data),
        .i_fifo_data_available (i_fifo_data_available),
        .o_fifo_rd_en          (fifo_pop_en_lv),
        .i_relu_en             (i_relu_en),
        .i_maxpool_en          (i_maxpool_en),
        .i_shift_by            (i_shift_by),

        // Output Side
        .o_final_out           (final_out_lv),
        .o_final_valid         (final_valid_lv)
    );

    level_shifter u_fifo_pop_en_lvl (
        .IN(fifo_pop_en_lv),
        .OUT(fifo_pop_en_hv)
    );

    level_shifter u_final_valid_lvl (
        .IN(final_valid_lv),
        .OUT(final_valid_hv)
    );

    genvar i;
    generate
        for(i = 0; i < WORD_SIZE; i += 1) begin : OUT_DATA_LVL_SHIFTERS
            level_shifter u_final_out_lvl (
                .IN(final_out_lv[i]),
                .OUT(final_out_hv[i])
            );
        end
    endgenerate



endmodule