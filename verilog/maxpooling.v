module maxpooling #(
    parameter ARRAY_SIZE    = 8,
    parameter OUTPUT_WIDTH  = 8
)(
    input  wire                                 clk,
    input  wire                                 rst_n,
    input  wire                                 en,         // Enable maxpool

    input  wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   data_in,
    input  wire                                 valid_in,

    output reg  [ARRAY_SIZE*OUTPUT_WIDTH-1:0]   data_out,
    output reg                                  valid_out
);
    localparam HALF = ARRAY_SIZE / 2;   // Rows per line buffer
    localparam QRTR = ARRAY_SIZE / 4;   // Output rows per maxpool

    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] line_buffer0 [0:HALF-1];
    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] line_buffer1 [0:HALF-1];

    reg [ARRAY_SIZE*OUTPUT_WIDTH-1:0] output_buffer [0:QRTR-1];

    reg                          fill_line_buf;   
    reg                          done_fill;       
    reg                          stream_output;   

    reg [$clog2(ARRAY_SIZE):0]   fill_pixel;      // Index within current line buffer
    reg [$clog2(ARRAY_SIZE):0]   stream_pixel;    // Index within output buffer

    integer i, ch;
    reg signed [OUTPUT_WIDTH-1:0] p0, p1, p2, p3;
    reg signed [OUTPUT_WIDTH-1:0] max01, max23, final_max;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_line_buf   <= 0;
            done_fill       <= 0;
            stream_output   <= 0;
            fill_pixel      <= 0;
            stream_pixel    <= 0;
            valid_out       <= 0;
            data_out        <= 0;
        end else begin
            valid_out <= 0;

            if (!en) begin
                if (valid_in) begin
                    data_out  <= data_in;
                    valid_out <= 1;
                end
            end else begin

                if (stream_output) begin
                    data_out     <= output_buffer[stream_pixel];
                    valid_out    <= 1;

                    if (stream_pixel == QRTR - 1) begin
                        stream_pixel  <= 0;
                        stream_output <= 0;
                    end else begin
                        stream_pixel  <= stream_pixel + 1;
                    end
                end

                if (done_fill && !stream_output) begin
                    for (i = 0; i < QRTR; i = i + 1) begin
                        for (ch = 0; ch < ARRAY_SIZE; ch = ch + 1) begin
                            p0 = line_buffer0[2*i  ][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                            p1 = line_buffer0[2*i+1][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                            p2 = line_buffer1[2*i  ][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                            p3 = line_buffer1[2*i+1][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH];

                            max01     = (p0 > p1) ? p0 : p1;
                            max23     = (p2 > p3) ? p2 : p3;
                            final_max = (max01 > max23) ? max01 : max23;

                            output_buffer[i][ch*OUTPUT_WIDTH +: OUTPUT_WIDTH] <= final_max;
                        end
                    end

                    // Start streaming next cycle
                    stream_output <= 1;
                    stream_pixel  <= 0;
                    done_fill     <= 0;

                    // Accept first new data into buf0 immediately
                    if (valid_in) begin
                        line_buffer0[0] <= data_in;
                        fill_pixel      <= 1;
                        fill_line_buf   <= 0;
                    end else begin
                        fill_pixel      <= 0;
                        fill_line_buf   <= 0;
                    end

                end else if (!done_fill) begin
                    if (valid_in) begin
                        if (!fill_line_buf) begin
                            // Filling buffer 0
                            line_buffer0[fill_pixel] <= data_in;
                            if (fill_pixel == HALF - 1) begin
                                fill_pixel    <= 0;
                                fill_line_buf <= 1;
                            end else begin
                                fill_pixel    <= fill_pixel + 1;
                            end
                        end else begin
                            // Filling buffer 1
                            line_buffer1[fill_pixel] <= data_in;
                            if (fill_pixel == HALF - 1) begin
                                fill_pixel    <= 0;
                                fill_line_buf <= 0;
                                done_fill     <= 1;
                            end else begin
                                fill_pixel    <= fill_pixel + 1;
                            end
                        end
                    end
                end

            end
        end
    end

endmodule