module scale_clip #(
    parameter ARRAY_SIZE = 4,
    parameter PSUM_WIDTH = 32,
    parameter OUTPUT_WIDTH = 8, //int8
    parameter SHIFT_WIDTH = 5
)(
    input wire [SHIFT_WIDTH-1:0] shift_by,
    input  wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] psum_in_vec,
    output wire signed [OUTPUT_WIDTH*ARRAY_SIZE-1:0] scaled_vec
);

    localparam signed [OUTPUT_WIDTH-1:0] UPPER = 'd127;
    // upper and lower range for a int8 numebr
    localparam signed [OUTPUT_WIDTH-1:0] LOWER = -128;

    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : scale_channel
            wire signed [PSUM_WIDTH-1:0] psum;
            assign psum = psum_in_vec[i*PSUM_WIDTH +: PSUM_WIDTH];

            wire signed [PSUM_WIDTH-1:0] after_shift;
            // 
            assign after_shift = psum >> shift_by;

            wire signed [OUTPUT_WIDTH-1:0] final_shift_check;
            // if higher than upper then use upper and vice vccers
            assign final_shift_check = (after_shift > UPPER) ? UPPER : (after_shift < LOWER) ? LOWER : after_shift[OUTPUT_WIDTH-1:0];
            assign scaled_vec[i*OUTPUT_WIDTH +: OUTPUT_WIDTH] = final_shift_check;
        end
    endgenerate

endmodule
