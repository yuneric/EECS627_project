module serializer #(
    parameter DIM        = 8,
    parameter DATA_WIDTH = 8
)(
    input  wire                          i_clk,
    input  wire                          i_rst_n,
    input  wire                          i_load,    // Parallel load
    input  wire                          i_shift,   // Shift out one element
    input  wire [DIM*DATA_WIDTH-1:0]     i_par_in,  // Parallel input
    output reg signed [DATA_WIDTH-1:0]   o_ser_out  // Serial output
);

    reg signed [DATA_WIDTH-1:0] shift_reg [0:DIM-1];

    // Output is element 0 (shifts toward index 0)

    integer k;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            for (k = 0; k < DIM; k = k + 1)
                shift_reg[k] <= {DATA_WIDTH{1'b0}};
            o_ser_out <= '0;
        end else begin
            if (i_load) begin
                for (k = 0; k < DIM; k = k + 1)
                    shift_reg[k] <= i_par_in[k*DATA_WIDTH +: DATA_WIDTH];
            end else if (i_shift) begin
                for (k = 0; k < DIM-1; k = k + 1)
                    shift_reg[k] <= shift_reg[k+1];
                shift_reg[DIM-1] <= {DATA_WIDTH{1'b0}};
            end
            o_ser_out <= i_shift ? shift_reg[0] : '0;
        end
    end

endmodule