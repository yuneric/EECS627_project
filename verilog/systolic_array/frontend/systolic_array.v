module systolic_array #(
    parameter ARRAY_SIZE = 4,
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

    // Interconnects
    wire signed [DATA_WIDTH-1:0] act_wires    [0:ARRAY_SIZE-1][0:ARRAY_SIZE];
    wire signed [DATA_WIDTH-1:0] weight_wires [0:ARRAY_SIZE][0:ARRAY_SIZE-1]; 
    wire signed [PSUM_WIDTH-1:0] psum_wires   [0:ARRAY_SIZE][0:ARRAY_SIZE-1]; 
    wire [ARRAY_SIZE*ARRAY_SIZE-1:0] pe_out_valid;

    genvar i, j;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : BOUNDARY_ASSIGN
            // Activations enter from the left at each row
            assign act_wires[i][0] = act_in_vec[i*DATA_WIDTH +: DATA_WIDTH];

            // Weights enter from the top at each column
            assign weight_wires[0][i] = weight_in_vec[i*DATA_WIDTH +: DATA_WIDTH];

            // Top boundary for psum shift
            assign psum_wires[0][i] = {PSUM_WIDTH{1'b0}};

            // Bottom outputs
            assign psum_out_vec[i*PSUM_WIDTH +: PSUM_WIDTH] = psum_wires[ARRAY_SIZE][i];
        end

        // Valid signals from bottom row only
        assign out_valid_vec = pe_out_valid[(ARRAY_SIZE-1)*ARRAY_SIZE +: ARRAY_SIZE];

        // Instantiate PE Grid
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : ROW
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : COL
                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .PSUM_WIDTH(PSUM_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),

                    .act_in     (act_wires[i][j]),
                    .weight_in  (weight_wires[i][j]),
                    .psum_in    (psum_wires[i][j]),       // From row above

                    .clear      (clear),
                    .compute_en (compute_en),
                    .drain      (drain),

                    .act_out    (act_wires[i][j+1]),
                    .psum_out   (psum_wires[i+1][j]),     // To row below
                    .weight_out (weight_wires[i+1][j]),

                    .out_valid  (pe_out_valid[i*ARRAY_SIZE+j])
                );
            end
        end
    endgenerate

endmodule