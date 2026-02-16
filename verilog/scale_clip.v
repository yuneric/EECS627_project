module scale_clip #(
    parameter DIM = 4,
    parameter IN_WIDTH = 32,
    parameter OUT_WIDTH = 8
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [3:0]              shift_amt,
    input  wire [DIM*IN_WIDTH-1:0] data_in,
    input  wire                    valid_in,
    
    output reg  [DIM*OUT_WIDTH-1:0] data_out,
    output reg                      valid_out
);

    integer i;
    reg signed [IN_WIDTH-1:0]  val;
    reg signed [IN_WIDTH-1:0]  shifted_val;
    
    // Constants for clipping
    localparam MAX_VAL = 127;
    localparam MIN_VAL = -128;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out <= 0;
            valid_out <= 0;
        end else begin
            valid_out <= valid_in;
            
            for (i = 0; i < DIM; i = i + 1) begin
                // Extract
                val = data_in[(i+1)*IN_WIDTH-1 : i*IN_WIDTH];
                
                // Scale
                shifted_val = val >>> shift_amt;

                // Clip
                if (shifted_val > MAX_VAL) 
                    data_out[(i+1)*OUT_WIDTH-1 : i*OUT_WIDTH] <= MAX_VAL;
                else if (shifted_val < MIN_VAL) 
                    data_out[(i+1)*OUT_WIDTH-1 : i*OUT_WIDTH] <= MIN_VAL;
                else 
                    data_out[(i+1)*OUT_WIDTH-1 : i*OUT_WIDTH] <= shifted_val[OUT_WIDTH-1:0];
            end
        end
    end
endmodule