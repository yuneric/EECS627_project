module systolic_array_system #(
    parameter ARRAY_SIZE   = 8,
    parameter DATA_WIDTH   = 8,
    parameter PSUM_WIDTH   = 32,
    parameter OUTPUT_WIDTH = 8,
    parameter SHIFT_WIDTH  = 5,
    parameter FIFO_DEPTH   = 4
)(
    input  wire                                 clk,
    input  wire                                 rst_n,

    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     act_wr_data,
    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     weight_wr_data,
    input  wire                                 data_last,
    input  wire                                 wr_en,
    output wire                                 fifo_full,

    input  wire                                 relu_en,
    input  wire [SHIFT_WIDTH-1:0]               shift_by,
    input  wire                                 maxpool_en,

    output wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   final_out,
    output wire                                 final_valid
);

    wire [DATA_WIDTH*ARRAY_SIZE-1:0] act_to_array;
    wire [DATA_WIDTH*ARRAY_SIZE-1:0] weight_to_array;
    wire                              sa_clear;
    wire                              sa_compute_en;
    wire                              sa_drain;
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]  psum_from_array;
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]  fe_result_out;
    wire                              fe_result_valid;

    wire [ARRAY_SIZE-1:0]             out_valid_vec;  // per-column valid from array

    systolic_array_front #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_frontend (
        .clk(clk),
        .rst_n(rst_n),
        .act_wr_data(act_wr_data),
        .weight_wr_data(weight_wr_data),
        .data_last(data_last),
        .wr_en(wr_en),
        .fifo_full(fifo_full),
        .act_to_array(act_to_array),
        .weight_to_array(weight_to_array),
        .sa_clear(sa_clear),
        .sa_compute_en(sa_compute_en),
        .sa_drain(sa_drain),
        .psum_from_array(psum_from_array),
        .result_out(fe_result_out),
        .result_valid(fe_result_valid)
    );

    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_array (
        .clk(clk),
        .rst_n(rst_n),
        .clear(sa_clear),
        .compute_en(sa_compute_en),
        .drain(sa_drain),
        .act_in_vec(act_to_array),
        .weight_in_vec(weight_to_array),
        .psum_out_vec(psum_from_array),
        .out_valid_vec(out_valid_vec)
    );

    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]  relu_out_vec;
    wire [OUTPUT_WIDTH*ARRAY_SIZE-1:0] scaled_vec;
    reg  [OUTPUT_WIDTH*ARRAY_SIZE-1:0] scaled_vec_reg;
    reg                                scaled_valid_reg;
    wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0] maxpool_out;
    wire                               maxpool_valid;

    relu #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_relu (
        .psum_in_vec(fe_result_out),
        .en(relu_en),
        .relu_out_vec(relu_out_vec)
    );

    scale_clip #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PSUM_WIDTH(PSUM_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SHIFT_WIDTH(SHIFT_WIDTH)
    ) u_scale_clip (
        .shift_by(shift_by),
        .psum_in_vec(relu_out_vec),
        .scaled_vec(scaled_vec)
    );

    // Register scaled output (1 cycle latency, matches golden brick)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scaled_vec_reg   <= 0;
            scaled_valid_reg <= 0;
        end else begin
            scaled_vec_reg   <= scaled_vec;
            scaled_valid_reg <= fe_result_valid;
        end
    end

    maxpooling #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) u_maxpool (
        .clk(clk),
        .rst_n(rst_n),
        .en(maxpool_en),
        .data_in(scaled_vec_reg),
        .valid_in(scaled_valid_reg),
        .data_out(maxpool_out),
        .valid_out(maxpool_valid)
    );

    assign final_out   = maxpool_out;
    assign final_valid = maxpool_valid;

endmodule