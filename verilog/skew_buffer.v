module skew_buffer #(
    parameter ARRAY_SIZE = 4,
    parameter DATA_WIDTH = 8
)(
    input  wire                                 clk,
    input  wire                                 rst_n,
    input  wire                                 clear,  // Reset all delay regs

    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     data_in,
    output wire [DATA_WIDTH*ARRAY_SIZE-1:0]     data_out   // Skewed output
);

    genvar i, d;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : SKEW_LANE
            if (i == 0) begin : NO_DELAY
                assign data_out[i*DATA_WIDTH +: DATA_WIDTH] = data_in[i*DATA_WIDTH +: DATA_WIDTH];
            end else begin : HAS_DELA
                reg signed [DATA_WIDTH-1:0] delay_reg [0:i-1];

                // First stage takes array input
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n || clear)
                        delay_reg[0] <= {DATA_WIDTH{1'b0}};
                    else
                        delay_reg[0] <= data_in[i*DATA_WIDTH +: DATA_WIDTH];
                end

                // Subsequent stages form shift chain
                for (d = 1; d < i; d = d + 1) begin : DELAY_STAGE
                    always @(posedge clk or negedge rst_n) begin
                        if (!rst_n || clear)
                            delay_reg[d] <= {DATA_WIDTH{1'b0}};
                        else
                            delay_reg[d] <= delay_reg[d-1];
                    end
                end

                // Output from last delay stage
                assign data_out[i*DATA_WIDTH +: DATA_WIDTH] = delay_reg[i-1];
            end
        end
    endgenerate

endmodule