module systolic_array #(
    parameter DIM = 8,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,
    input wire clear,       // Start new accumulation
    input wire compute_en, // Accumulate this cycle
    input wire drain,      // Final psum ready to capture
    
    input  wire [DIM*DATA_WIDTH-1:0]          left_inputs, 
    input  wire [DIM*DATA_WIDTH-1:0]          top_inputs,
    
    // Outputs
    output wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] psum_out_vec,   // Results at Bottom
    output wire [ARRAY_SIZE-1:0] out_valid_vec   // valid from the pe per column (bottom row)
);

    // Interconnects
    wire signed [DATA_WIDTH-1:0] act_wires [ARRAY_SIZE:0][ARRAY_SIZE:0];
    wire signed [DATA_WIDTH-1:0] weight_wires [ARRAY_SIZE:0][ARRAY_SIZE:0];
    wire signed [PSUM_WIDTH-1:0] psum_wires [ARRAY_SIZE:0][ARRAY_SIZE:0];
    wire [ARRAY_SIZE*ARRAY_SIZE-1:0] pe_out_valid;

    genvar r, c;
    generate
        for (r = 0; r < DIM; r = r + 1) begin : ROWS
            
            // Weights
            assign weight_wires[0][i] = weight_in_vec[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH];
            
            // Top Inputs 
            assign psum_wires[0][i] = {PSUM_WIDTH{1'b0}};
            
            // Assign Bottom Outputs
            assign psum_out_vec[(i+1)*PSUM_WIDTH-1 : i*PSUM_WIDTH] = psum_wires[ARRAY_SIZE][i];
        end

        assign out_valid_vec = pe_out_valid[(ARRAY_SIZE-1)*ARRAY_SIZE +: ARRAY_SIZE];
        
        // Instantiate PE Grid
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : ROW
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : COL
                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    // Inputs
                    .act_in(act_wires[i][j]),           // From Left
                    //.psum_in(psum_wires[i][j]),         // From Top
                    .weight_in(weight_wires[i][j]),     // From Top (for loading)
                    
                    .clear(clear),
                    .compute_en(compute_en),
                    .drain(drain),

                    // Outputs
                    .act_out(act_wires[i][j+1]),        // To Right
                    .psum_out(psum_wires[i+1][j]),      // To Bottom
                    .weight_out(weight_wires[i+1][j]),  // To Bottom (daisy chain loading)

                    .out_valid(pe_out_valid[i*ARRAY_SIZE+j])
                );
            end
        end
    endgenerate

    // Assign bottom wires to module output
    generate
        for (c = 0; c < DIM; c = c + 1) begin : OUTPUT_ASSIGN
            assign bottom_outputs[(c+1)*ACC_WIDTH-1 : c*ACC_WIDTH] = vertical_wires[DIM][c];
        end
    endgenerate

endmodule