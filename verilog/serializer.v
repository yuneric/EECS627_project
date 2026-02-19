module serializer #(
    parameter DIM        = 8,
    parameter DATA_WIDTH = 8
)(
    input  wire                          clk,
    input  wire                          rst_n,
    input  wire                          load,    // Parallel load
    input  wire                          shift,   // Shift out one element
    input  wire [DIM*DATA_WIDTH-1:0]     par_in,  // Parallel input
    output wire signed [DATA_WIDTH-1:0]  ser_out  // Serial output
);

    reg signed [DATA_WIDTH-1:0] shift_reg [0:DIM-1];

    // Output is element 0 (shifts toward index 0)
    assign ser_out = shift_reg[0];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < DIM; k = k + 1)
                shift_reg[k] <= {DATA_WIDTH{1'b0}};
        end else if (load) begin
            for (k = 0; k < DIM; k = k + 1)
                shift_reg[k] <= par_in[k*DATA_WIDTH +: DATA_WIDTH];
        end else if (shift) begin
            for (k = 0; k < DIM-1; k = k + 1)
                shift_reg[k] <= shift_reg[k+1];
            shift_reg[DIM-1] <= {DATA_WIDTH{1'b0}};
        end
    end

endmodule