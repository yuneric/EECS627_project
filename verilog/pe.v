module pe #(
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   flush,      // 1 = Drain, 0 = Compute
    input  wire [DATA_WIDTH-1:0]  left_in,
    input  wire [DATA_WIDTH-1:0]  top_in,
    
    output reg  [DATA_WIDTH-1:0]  right_out,
    output reg  [ACC_WIDTH-1:0]   bottom_out
);

    reg signed [ACC_WIDTH-1:0] accumulator;
    wire signed [DATA_WIDTH-1:0] s_left_in;
    wire signed [DATA_WIDTH-1:0] s_top_in;

    assign s_left_in = left_in;
    assign s_top_in = top_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator <= 0;
            right_out   <= 0;
            bottom_out  <= 0;
        end else begin
            // Pass activation to the right
            right_out <= left_in;

            if (flush) begin
                // Drain
                bottom_out  <= accumulator;
                accumulator <= 0; 
            end else begin
                bottom_out <= {{ (ACC_WIDTH-DATA_WIDTH){top_in[DATA_WIDTH-1]} }, top_in}; 
                
                accumulator <= accumulator + (s_left_in * s_top_in);
            end
        end
    end
endmodule