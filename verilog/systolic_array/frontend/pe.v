module pe #(
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 32
)(
    input wire                              clk,
    input wire                              rst_n,

    input wire signed [DATA_WIDTH-1:0]      act_in,
    input wire signed [DATA_WIDTH-1:0]      weight_in,
    input wire signed [PSUM_WIDTH-1:0]      psum_in,    // From PE above (for drain shift)

    // Accumulator control
    input  wire  clear,
    input  wire  compute_en,
    input  wire  drain,       // Shift psum downward

    output wire signed [DATA_WIDTH-1:0]     weight_out,
    output wire signed [DATA_WIDTH-1:0]     act_out,
    output wire signed [PSUM_WIDTH-1:0]     psum_out,
    output wire                             out_valid
);

    wire signed [2*DATA_WIDTH-1:0] mac_result;

    reg signed [PSUM_WIDTH-1:0]  psum_reg;
    reg signed [DATA_WIDTH-1:0]  weight_reg;
    reg signed [DATA_WIDTH-1:0]  act_reg;

    assign mac_result = act_reg * weight_reg;
    assign out_valid  = drain;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            psum_reg   <= {PSUM_WIDTH{1'b0}};
            weight_reg <= {DATA_WIDTH{1'b0}};
            act_reg    <= {DATA_WIDTH{1'b0}};
        end else begin
            weight_reg <= weight_in;
            act_reg    <= act_in;

            if (clear)
                psum_reg <= {PSUM_WIDTH{1'b0}};
            else if (drain)
                psum_reg <= psum_in;
            else if (compute_en)
                psum_reg <= psum_reg + mac_result;
        end
    end

    assign psum_out   = psum_reg;
    assign act_out    = act_reg;
    assign weight_out = weight_reg;

endmodule