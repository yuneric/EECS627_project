module skew_buffer #(
    parameter ARRAY_SIZE = 8,
    parameter DATA_WIDTH = 8
)(
    input  wire                                     clk,
    input  wire                                     rst_n,

    input  wire                                     load_en,
    input  wire [$clog2(ARRAY_SIZE)-1:0]            load_row,   // which row to load
    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]         load_data,  // full row of data

    input  wire                                     shift_en,   // advance one cycle
    input  wire                                     shift_clear,// reset shift counter (before new tile)
    output wire [DATA_WIDTH*ARRAY_SIZE-1:0]         data_out,   // one element per lane
    output wire                                     done        // all lanes finished shifting
);
    reg signed [DATA_WIDTH-1:0] tile_data [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Global shift counter
    localparam SHIFT_TOTAL = 2 * ARRAY_SIZE - 1;
    reg [$clog2(SHIFT_TOTAL):0] shift_cnt;

    integer c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin : RESET_TILE
            integer r_rst, c_rst;
            for (r_rst = 0; r_rst < ARRAY_SIZE; r_rst = r_rst + 1)
                for (c_rst = 0; c_rst < ARRAY_SIZE; c_rst = c_rst + 1)
                    tile_data[r_rst][c_rst] <= {DATA_WIDTH{1'b0}};
        end else if (load_en) begin
            for (c = 0; c < ARRAY_SIZE; c = c + 1)
                tile_data[load_row][c] <= load_data[c*DATA_WIDTH +: DATA_WIDTH];
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            shift_cnt <= 0;
        else if (shift_clear)
            shift_cnt <= 0;
        else if (shift_en && shift_cnt < SHIFT_TOTAL)
            shift_cnt <= shift_cnt + 1;
    end

    genvar lane;
    generate
        for (lane = 0; lane < ARRAY_SIZE; lane = lane + 1) begin : LANE_OUT
            // Per-lane column index
            wire [$clog2(SHIFT_TOTAL):0] col_idx;
            wire in_range;

            assign col_idx  = shift_cnt - lane[($clog2(SHIFT_TOTAL)):0];
            assign in_range = (shift_cnt >= lane) && (col_idx < ARRAY_SIZE);

            // Mux out the correct element (or zero)
            reg signed [DATA_WIDTH-1:0] lane_out;

            // Combinational mux for column selection
            integer k;
            always @(*) begin
                lane_out = {DATA_WIDTH{1'b0}};
                if (in_range) begin
                    for (k = 0; k < ARRAY_SIZE; k = k + 1) begin
                        if (col_idx[($clog2(ARRAY_SIZE)):0] == k[($clog2(ARRAY_SIZE)):0])
                            lane_out = tile_data[lane][k];
                    end
                end
            end

            assign data_out[lane*DATA_WIDTH +: DATA_WIDTH] = lane_out;
        end
    endgenerate

    assign done = (shift_cnt == SHIFT_TOTAL);

endmodule