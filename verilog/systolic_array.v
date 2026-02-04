module systolic_array #(
    parameter ARRAY_SIZE = 4,   // 4x4 Array
    parameter DATA_WIDTH = 8,
    parameter PSUM_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,
    input wire weight_load,     // Global weight load enable
    
    // Inputs vectors (Arrays of wires)
    input wire signed [DATA_WIDTH*ARRAY_SIZE-1:0] act_in_vec,      // Activations from Left
    input wire signed [DATA_WIDTH*ARRAY_SIZE-1:0] weight_in_vec,   // Weights from Top
    
    // Outputs
    output wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] psum_out_vec    // Results at Bottom
);

    // Internal Wires for Interconnects
    // Indices: [Row][Col]
    wire signed [DATA_WIDTH-1:0] act_wires [ARRAY_SIZE:0][ARRAY_SIZE:0];
    wire signed [DATA_WIDTH-1:0] weight_wires [ARRAY_SIZE:0][ARRAY_SIZE:0];
    wire signed [PSUM_WIDTH-1:0] psum_wires [ARRAY_SIZE:0][ARRAY_SIZE:0];

    genvar i, j;
    generate
        // 1. Assign Top/Left Boundary Inputs
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : BOUNDARY_ASSIGN
            // Left Inputs (Activations)
            assign act_wires[i][0] = act_in_vec[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH];
            
            // Top Inputs (Weights)
            assign weight_wires[0][i] = weight_in_vec[(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH];
            
            // Top Inputs (Partial Sums - usually 0 at the top)
            assign psum_wires[0][i] = {PSUM_WIDTH{1'b0}};
            
            // Assign Bottom Outputs to Module Output
            assign psum_out_vec[(i+1)*PSUM_WIDTH-1 : i*PSUM_WIDTH] = psum_wires[ARRAY_SIZE][i];
        end

        // 2. Instantiate PE Grid
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : ROW
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : COL
                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .PSUM_WIDTH(PSUM_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .weight_load(weight_load),
                    
                    // Inputs
                    .act_in(act_wires[i][j]),           // From Left
                    .psum_in(psum_wires[i][j]),         // From Top
                    .weight_in(weight_wires[i][j]),     // From Top (for loading)
                    
                    // Outputs
                    .act_out(act_wires[i][j+1]),        // To Right
                    .psum_out(psum_wires[i+1][j]),      // To Bottom
                    .weight_out(weight_wires[i+1][j])   // To Bottom (daisy chain loading)
                );
            end
        end
    endgenerate

endmodule