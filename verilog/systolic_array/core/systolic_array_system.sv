module systolic_array_system #(
    parameter ARRAY_SIZE   = 8,
    parameter DATA_WIDTH   = 8,
    parameter PSUM_WIDTH   = 32,
    parameter OUTPUT_WIDTH = 8,
    parameter SHIFT_WIDTH  = 5
)(
    input  wire                                 i_clk,   // compute-side clock (systolic array domain)
    input  wire                                 i_rst_n,

    input  wire  [DATA_WIDTH*ARRAY_SIZE-1:0]    i_fifo_act_data      ,
    input  wire  [DATA_WIDTH*ARRAY_SIZE-1:0]    i_fifo_weight_data   ,
    input  wire                                 i_fifo_info_data     ,
    input  wire                                 i_fifo_data_available,
    output wire                                 o_fifo_rd_en         ,

    input  wire                                 i_relu_en,
    input  wire [SHIFT_WIDTH-1:0]               i_shift_by,
    input  wire                                 i_maxpool_en,

    output wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   o_final_out,
    output wire                                 o_final_valid
);
    wire [DATA_WIDTH*ARRAY_SIZE-1:0]  act_to_array;
    wire [DATA_WIDTH*ARRAY_SIZE-1:0]  weight_to_array;
    wire                              sa_clear;
    wire                              sa_compute_en;
    wire                              sa_drain;
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]  psum_from_array;
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]  fe_result_out;
    wire                              fe_result_valid;

    wire [ARRAY_SIZE-1:0]             out_valid_vec;  // per-column valid from array
    
    `ifdef SYN
    initial begin
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", sa_slice_tb.dut);
    end
    `else
    initial begin
        $display("[%0t] SYN not defined, no SDF annotation", $time);
    end
    `endif

    systolic_array_front #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_frontend (
        .i_clk  (i_clk),
        .i_rst_n(i_rst_n),
        .i_fifo_act_data        (i_fifo_act_data      ),
        .i_fifo_weight_data     (i_fifo_weight_data   ),
        .i_fifo_info_data       (i_fifo_info_data     ),
        .i_fifo_data_available  (i_fifo_data_available),
        .o_fifo_rd_en           (o_fifo_rd_en         ),
        .o_act_to_array         (act_to_array   ),
        .o_weight_to_array      (weight_to_array),
        .o_sa_clear             (sa_clear       ),
        .o_sa_compute_en        (sa_compute_en  ),
        .o_sa_drain             (sa_drain       ),
        .i_psum_from_array      (psum_from_array),
        .o_result_out           (fe_result_out  ),
        .o_result_valid         (fe_result_valid)
    );

    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_array (
        .clk            (i_clk          ),
        .rst_n          (i_rst_n        ),
        .clear          (sa_clear       ),
        .compute_en     (sa_compute_en  ),
        .drain          (sa_drain       ),
        .act_in_vec     (act_to_array   ),
        .weight_in_vec  (weight_to_array),
        .psum_out_vec   (psum_from_array),
        .out_valid_vec  (out_valid_vec  )
    );

    // ReLU (combinational)
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]  relu_out_vec;

    relu #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_relu (
        .psum_in_vec    (fe_result_out),
        .en             (i_relu_en    ),
        .relu_out_vec   (relu_out_vec )
    );

    // after ReLU
    reg [PSUM_WIDTH*ARRAY_SIZE-1:0]   relu_out_reg;
    reg                                valid_reg1;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            relu_out_reg <= 0;
            valid_reg1   <= 0;
        end else begin
            relu_out_reg <= relu_out_vec;
            valid_reg1   <= fe_result_valid;
        end
    end

    // Scale/Clip
    wire [OUTPUT_WIDTH*ARRAY_SIZE-1:0] scaled_vec;

    scale_clip #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PSUM_WIDTH(PSUM_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SHIFT_WIDTH(SHIFT_WIDTH)
    ) u_scale_clip (
        .shift_by   (i_shift_by     ),
        .psum_in_vec(relu_out_reg   ),
        .scaled_vec (scaled_vec     )
    );

    // after Scale/Clip
    reg [OUTPUT_WIDTH*ARRAY_SIZE-1:0]  scaled_vec_reg;
    reg                                valid_reg2;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            scaled_vec_reg <= 0;
            valid_reg2     <= 0;
        end else begin
            scaled_vec_reg <= scaled_vec;
            valid_reg2     <= valid_reg1;
        end
    end

    // Maxpool
    maxpooling #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) u_maxpool (
        .clk        (i_clk          ),
        .rst_n      (i_rst_n        ),
        .en         (i_maxpool_en   ),
        .data_in    (scaled_vec_reg ),
        .valid_in   (valid_reg2     ),
        .data_out   (o_final_out    ),
        .valid_out  (o_final_valid  )
    );


endmodule