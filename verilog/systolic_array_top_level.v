module systolic_array_top_level #(
    parameter ARRAY_SIZE  = 8,
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 32,
    parameter OUTPUT_WIDTH = 8,
    parameter SHIFT_WIDTH = 5
)(
    input  wire                                 clk,
    input  wire                                 rst_n,
    
    // Systolic Array Control
    input  wire                                 clear,
    input  wire                                 compute_en,
    input  wire                                 drain,
    
    // Systolic Array Inputs
    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     act_in_vec,
    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     weight_in_vec,
    
    // Backend Control
    input  wire                                 relu_en,
    input  wire [SHIFT_WIDTH-1:0]               shift_by,
    input  wire                                 maxpool_en,
    
    // Final Output
    output wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   final_out,
    output wire                                 final_valid
);  
    // Systolic array outputs
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]   psum_out_vec;
    wire [ARRAY_SIZE-1:0]              out_valid_vec;
    wire                               sa_valid;  // OR of all valid signals
    
    // ReLU outputs
    wire [PSUM_WIDTH*ARRAY_SIZE-1:0]   relu_out_vec;
    
    // Scale/Clip outputs  
    wire [OUTPUT_WIDTH*ARRAY_SIZE-1:0] scaled_vec;
    
    // Registered scale output (to add 1 cycle latency like golden brick)
    reg  [OUTPUT_WIDTH*ARRAY_SIZE-1:0]  scaled_vec_reg;
    reg                                 scaled_valid_reg;
    
    // Maxpool outputs
    wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0] maxpool_out;
    wire                               maxpool_valid;

    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_systolic_array (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .compute_en(compute_en),
        .drain(drain),
        .act_in_vec(act_in_vec),
        .weight_in_vec(weight_in_vec),
        .psum_out_vec(psum_out_vec),
        .out_valid_vec(out_valid_vec)
    );
    
    // Valid when any PE is outputting
    assign sa_valid = |out_valid_vec;

    relu #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_relu (
        .psum_in_vec(psum_out_vec),
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
    
    // Register the scale output to add 1 cycle latency (matches golden brick)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scaled_vec_reg  <= 0;
            scaled_valid_reg <= 0;
        end else begin
            scaled_vec_reg  <= scaled_vec;
            scaled_valid_reg <= sa_valid;
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