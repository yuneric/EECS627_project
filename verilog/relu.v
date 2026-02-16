module relu #(
    parameter DIM = 4,
    parameter BIT_WIDTH = 32
)(
    input  wire                     enable,
    input  wire [DIM*BIT_WIDTH-1:0] data_in,
    output reg  [DIM*BIT_WIDTH-1:0] data_out
);
    integer i;
    reg signed [BIT_WIDTH-1:0] val;

    always @(*) begin
        for (i = 0; i < DIM; i = i + 1) begin
            val = data_in[(i+1)*BIT_WIDTH-1 : i*BIT_WIDTH];
            if (enable && val < 0) begin
                data_out[(i+1)*BIT_WIDTH-1 : i*BIT_WIDTH] = 0;
            end else begin
                data_out[(i+1)*BIT_WIDTH-1 : i*BIT_WIDTH] = val;
            end
        end
    end
endmodule