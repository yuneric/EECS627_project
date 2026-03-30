module systolic_array #(
    parameter ARRAY_SIZE = 8,
    parameter DATA_WIDTH = 8,
    parameter PSUM_WIDTH = 32
)(
    input wire clk,
    input wire rst_n,
    input wire clear,
    input wire compute_en,
    input wire drain,

    input wire signed [DATA_WIDTH*ARRAY_SIZE-1:0] act_in_vec,
    input wire signed [DATA_WIDTH*ARRAY_SIZE-1:0] weight_in_vec,

    output wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] psum_out_vec,
    output wire [ARRAY_SIZE-1:0] out_valid_vec
);
    // nanda
    localparam integer PSUM_COL_W = PSUM_WIDTH * (ARRAY_SIZE + 1);

    // Interconnects
    wire signed [DATA_WIDTH-1:0] act_wires    [0:ARRAY_SIZE-1][0:ARRAY_SIZE];
    wire signed [DATA_WIDTH-1:0] weight_wires [0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    // nanda
    //wire signed [PSUM_WIDTH-1:0] psum_wires   [0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    wire signed [PSUM_COL_W-1:0] psum_col     [0:ARRAY_SIZE-1];
    wire [ARRAY_SIZE*ARRAY_SIZE-1:0] pe_out_valid;

    genvar i, j;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : BOUNDARY_ASSIGN
            // Activations enter from the left at each row
            assign act_wires[i][0] = act_in_vec[i*DATA_WIDTH +: DATA_WIDTH];

            // Weights enter from the top at each column
            assign weight_wires[0][i] = weight_in_vec[i*DATA_WIDTH +: DATA_WIDTH];

            // Boundary: zeros feed into highest-index row's psum_in
            assign psum_col[i][0 +: PSUM_WIDTH] = {PSUM_WIDTH{1'b0}};
            assign psum_out_vec[i*PSUM_WIDTH +: PSUM_WIDTH] = psum_col[i][ARRAY_SIZE*PSUM_WIDTH +: PSUM_WIDTH];

            //assign psum_wires[ARRAY_SIZE][i] = {PSUM_WIDTH{1'b0}};

            // Output: drain results emerge from psum_wires[0] (row 0's psum_out)
            //assign psum_out_vec[i*PSUM_WIDTH +: PSUM_WIDTH] = psum_wires[ARRAY_SIZE][i];
        end

        // Valid signals from bottom row only
        assign out_valid_vec = pe_out_valid[(ARRAY_SIZE-1)*ARRAY_SIZE +: ARRAY_SIZE];

        // Instantiate PE Grid
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : ROW
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : COL
                pe pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),

                    .act_in     (act_wires[i][j]),
                    .weight_in  (weight_wires[i][j]),
                    .psum_in    (psum_col[j][(ARRAY_SIZE-1-i)*PSUM_WIDTH +: PSUM_WIDTH]),

                    .clear      (clear),
                    .compute_en (compute_en),
                    .drain      (drain),

                    .act_out    (act_wires[i][j+1]),
                    .psum_out   (psum_col[j][(ARRAY_SIZE-i)*PSUM_WIDTH +: PSUM_WIDTH]),
                    .weight_out (weight_wires[i+1][j]),

                    .out_valid  (pe_out_valid[i*ARRAY_SIZE+j])
                );
            end
        end
    endgenerate

endmodule