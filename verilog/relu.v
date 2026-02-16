module relu #(
    parameter ARRAY_SIZE = 4,
    parameter PSUM_WIDTH = 32
)(
    input wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] psum_in_vec,
    input wire en, // enable signal to disable the relu
    output wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] relu_out_vec 
);
    // parameter alpha_shift = 5
    genvar i;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : BOUNDARY_ASSIGN
            wire signed [PSUM_WIDTH-1:0] psum_in;
            wire signed [PSUM_WIDTH-1:0] relu_out;
            
            assign psum_in = psum_in_vec[i*PSUM_WIDTH +: PSUM_WIDTH];
            // if we do leaky relu its just not put to 0 instead its just multiplied by a small number
            // assign relu_out = (psum_in[PSUM_WIDTH-1]) ? (psum_in >>>> alpha_shift) : psum_in;
            
            // check the msb since its signed to see if 1 (negative) or 0
            assign relu_out = en ? ((psum_in[PSUM_WIDTH-1]) ? {PSUM_WIDTH{1'b0}} : psum_in) : psum_in;
            
            // Pack output
            assign relu_out_vec[i*PSUM_WIDTH +: PSUM_WIDTH] = relu_out;
        end
    endgenerate


endmodule
