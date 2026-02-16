module maxpooling #(
    parameter ARRAY_SIZE = 8,      
    parameter OUTPUT_WIDTH = 8
)(
    input  wire                                 clk,
    input  wire                                 rst_n,
    input  wire                                 en,         // Enable maxpool
    
    input  wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   data_in,
    input  wire                                 valid_in,
    
    output reg  [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   data_out,
    output reg                                  valid_out
);

    // Golden brick behavior (for ARRAY_SIZE=8):
    // 1. Collect ARRAY_SIZE/2=4 vectors into buffer0
    // 2. Collect ARRAY_SIZE/2=4 vectors into buffer1  
    // 3. Compute ARRAY_SIZE/4=2 output vectors (2x2 spatial max per channel)
    // 4. Stream out the output vectors

    localparam FILL_BUF0  = 2'd0;
    localparam FILL_BUF1  = 2'd1;
    localparam COMPUTE    = 2'd2;
    localparam STREAM_OUT = 2'd3;

    // Line buffers
    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] line_buffer0 [0:(ARRAY_SIZE/2)-1];
    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] line_buffer1 [0:(ARRAY_SIZE/2)-1];
    
    // Output buffer
    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] output_buffer [0:(ARRAY_SIZE/4)-1];

    reg [1:0] state;
    reg [$clog2(ARRAY_SIZE):0] cnt;

    // For compute
    integer i, ch;
    reg signed [OUTPUT_WIDTH-1:0] p0, p1, p2, p3;
    reg signed [OUTPUT_WIDTH-1:0] max01, max23, final_max;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= FILL_BUF0;
            cnt       <= 0;
            valid_out <= 0;
            data_out  <= 0;
        end else begin
            valid_out <= 0;

            if (!en) begin
                if (valid_in) begin
                    data_out  <= data_in;
                    valid_out <= 1;
                end
            end else begin
                case (state)
                    FILL_BUF0: begin
                        if (valid_in) begin
                            line_buffer0[cnt] <= data_in;
                            if (cnt == (ARRAY_SIZE/2) - 1) begin
                                cnt   <= 0;
                                state <= FILL_BUF1;
                            end else begin
                                cnt <= cnt + 1;
                            end
                        end
                    end

                    FILL_BUF1: begin
                        if (valid_in) begin
                            line_buffer1[cnt] <= data_in;
                            if (cnt == (ARRAY_SIZE/2) - 1) begin
                                cnt   <= 0;
                                state <= COMPUTE;
                            end else begin
                                cnt <= cnt + 1;
                            end
                        end
                    end

                    COMPUTE: begin
                        // Compute 2x2 max for each output pixel and channel
                        for (i = 0; i < ARRAY_SIZE/4; i = i + 1) begin
                            for (ch = 0; ch < ARRAY_SIZE; ch = ch + 1) begin
                                p0 = line_buffer0[2*i  ][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                                p1 = line_buffer0[2*i+1][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                                p2 = line_buffer1[2*i  ][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                                p3 = line_buffer1[2*i+1][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];

                                max01 = (p0 > p1) ? p0 : p1;
                                max23 = (p2 > p3) ? p2 : p3;
                                final_max = (max01 > max23) ? max01 : max23;
                                
                                output_buffer[i][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH] <= final_max;
                            end
                        end
                        cnt   <= 0;
                        state <= STREAM_OUT;
                    end

                    STREAM_OUT: begin
                        data_out  <= output_buffer[cnt];
                        valid_out <= 1;
                        
                        if (cnt == (ARRAY_SIZE/4) - 1) begin
                            cnt   <= 0;
                            state <= FILL_BUF0;
                        end else begin
                            cnt <= cnt + 1;
                        end
                    end

                    default: state <= FILL_BUF0;
                endcase
            end
        end
    end

endmodule