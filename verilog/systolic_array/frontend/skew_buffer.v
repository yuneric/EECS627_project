module skew_buffer #(
    parameter ARRAY_SIZE = 4,
    parameter DATA_WIDTH = 8
)(
    input                                   i_clk,
    input                                   i_rst_n,
    input                                   i_clear,  // Reset all delay regs

    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     i_data_in,
    output wire [DATA_WIDTH*ARRAY_SIZE-1:0]     o_data_out   // Skewed output
);

    genvar i, d;
    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : SKEW_LANE
            if (i == 0) begin : NO_DELAY
                assign o_data_out[i*DATA_WIDTH +: DATA_WIDTH] = i_data_in[i*DATA_WIDTH +: DATA_WIDTH];
            end else begin : HAS_DELAY
                reg signed [DATA_WIDTH-1:0] delay_reg [0:i-1];

                // First stage takes array input
                always @(posedge i_clk or negedge i_rst_n) begin
                    if (~i_rst_n)
                        delay_reg[0] <= {DATA_WIDTH{1'b0}};
                    else begin
                        if (i_clear)
                            delay_reg[0] <= {DATA_WIDTH{1'b0}};
                        else
                            delay_reg[0] <= i_data_in[i*DATA_WIDTH +: DATA_WIDTH];
                    end
                end

                // Subsequent stages form shift chain
                for (d = 1; d < i; d = d + 1) begin : DELAY_STAGE
                    always @(posedge i_clk or negedge i_rst_n) begin
                        if (~i_rst_n)
                            delay_reg[d] <= {DATA_WIDTH{1'b0}};
                        else begin
                            if (i_clear)
                                delay_reg[d] <= {DATA_WIDTH{1'b0}};
                            else
                                delay_reg[d] <= delay_reg[d-1];
                        end
                    end
                end

                // Output from last delay stage
                assign o_data_out[i*DATA_WIDTH +: DATA_WIDTH] = delay_reg[i-1];
            end
        end
    endgenerate

endmodule