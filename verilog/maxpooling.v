module maxpooling #(
    parameter DIM = 4,
    parameter WIDTH = 8
)(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   enable,
    
    input  wire [DIM*WIDTH-1:0]   data_in,
    input  wire                   valid_in,
    
    output reg  [(DIM/2)*WIDTH-1:0] data_out, // Output is half width
    output reg                    valid_out
);

    // Line Buffer to store the first row of the 2x2 block
    reg [DIM*WIDTH-1:0] line_buffer;
    reg                 row_toggle; // 0 = First row, 1 = Second row
    
    integer i;
    reg signed [WIDTH-1:0] p1, p2, p3, p4;
    reg signed [WIDTH-1:0] max_row1, max_row2, final_max;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_toggle <= 0;
            valid_out  <= 0;
            data_out   <= 0;
        end else begin
            // Default
            valid_out <= 0;

            if (valid_in) begin
                if (!enable) begin
                    data_out  <= data_in[(DIM/2)*WIDTH-1:0]; 
                    valid_out <= 1;
                end 
                else begin
                    if (row_toggle == 0) begin
                        // First row of 2x2 block
                        line_buffer <= data_in;
                        row_toggle  <= 1;
                    end else begin
                        // Second row of 2x2 block
                        // Loop to create DIM/2 outputs
                        for (i = 0; i < DIM/2; i = i + 1) begin
                            // Row 0 (Buffer): 2*i, 2*i+1
                            // Row 1 (Input):  2*i, 2*i+1
                            
                            p1 = line_buffer[(2*i+1)*WIDTH-1 : (2*i)*WIDTH];
                            p2 = line_buffer[(2*i+2)*WIDTH-1 : (2*i+1)*WIDTH];
                            p3 = data_in[(2*i+1)*WIDTH-1 : (2*i)*WIDTH];
                            p4 = data_in[(2*i+2)*WIDTH-1 : (2*i+1)*WIDTH];

                            // Comparisons
                            max_row1 = (p1 > p2) ? p1 : p2;
                            max_row2 = (p3 > p4) ? p3 : p4;
                            final_max = (max_row1 > max_row2) ? max_row1 : max_row2;

                            data_out[(i+1)*WIDTH-1 : i*WIDTH] <= final_max;
                        end
                        
                        valid_out <= 1;
                        row_toggle <= 0; // Reset for next block
                    end
                end
            end
        end
    end

endmodule