module systolic_array #(
    parameter DIM = 8,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH = 32
)(
    input  wire                               clk,
    input  wire                               rst_n,
    input  wire                               flush,
    
    input  wire [DIM*DATA_WIDTH-1:0]          left_inputs, 
    input  wire [DIM*DATA_WIDTH-1:0]          top_inputs,
    
    // Output
    output wire [DIM*ACC_WIDTH-1:0]           bottom_outputs
);

    // Wires to connect PEs
    wire [DATA_WIDTH-1:0] horizontal_wires [0:DIM-1][0:DIM];
    wire [ACC_WIDTH-1:0]  vertical_wires   [0:DIM][0:DIM-1];

    genvar r, c;
    generate
        for (r = 0; r < DIM; r = r + 1) begin : ROWS
            
            // Assign array inputs to the leftmost wires
            assign horizontal_wires[r][0] = left_inputs[(r+1)*DATA_WIDTH-1 : r*DATA_WIDTH];

            for (c = 0; c < DIM; c = c + 1) begin : COLS
                
                // If it's the top row, connect external inputs
                if (r == 0) begin
                    assign vertical_wires[0][c] = {{ (ACC_WIDTH-DATA_WIDTH){top_inputs[(c+1)*DATA_WIDTH-1]} }, top_inputs[(c+1)*DATA_WIDTH-1 : c*DATA_WIDTH]};
                end

                pe #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH(ACC_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst_n(rst_n),
                    .flush(flush),
                    .left_in(horizontal_wires[r][c]),
                    .top_in(vertical_wires[r][c][DATA_WIDTH-1:0]), // Truncate back to 8-bit for calculation
                    .right_out(horizontal_wires[r][c+1]),
                    .bottom_out(vertical_wires[r+1][c])
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