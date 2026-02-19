module systolic_array_front #(
    parameter ARRAY_SIZE  = 4,
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 32,
    parameter FIFO_DEPTH  = 4
)(
    input  wire                                 clk,
    input  wire                                 rst_n,

    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     act_wr_data,
    input  wire [DATA_WIDTH*ARRAY_SIZE-1:0]     weight_wr_data,
    input  wire                                 data_last,   // 1 = last row of final tile
    input  wire                                 wr_en,
    output wire                                 fifo_full,

    output wire [DATA_WIDTH*ARRAY_SIZE-1:0]     act_to_array,
    output wire [DATA_WIDTH*ARRAY_SIZE-1:0]     weight_to_array,

    output reg                                  sa_clear,
    output reg                                  sa_compute_en,
    output reg                                  sa_drain,

    input  wire [PSUM_WIDTH*ARRAY_SIZE-1:0]     psum_from_array,
    output wire [PSUM_WIDTH*ARRAY_SIZE-1:0]     result_out,
    output reg                                  result_valid
);

    localparam PROPAGATE_CYCLES = 2 * ARRAY_SIZE - 1;

    localparam SEL_W = $clog2(ARRAY_SIZE);

    localparam [2:0] S_IDLE      = 3'd0;  // Waiting for FIFO data
    localparam [2:0] S_STAGE     = 3'd1;  // Reading DIM rows from FIFOs
    localparam [2:0] S_SERIALIZE = 3'd2;  // Feeding serialized data to skew+array
    localparam [2:0] S_PROPAGATE = 3'd3;  // Waiting for computation to finish
    localparam [2:0] S_DRAIN     = 3'd4;  // Shifting results out of array

    reg [2:0] state, state_next;
    reg [SEL_W:0]             stage_cnt;       // Counts rows staged (0 to DIM-1)
    reg [SEL_W:0]             serial_cnt;      // Counts serialization cycles
    reg [$clog2(3*ARRAY_SIZE):0] prop_cnt;     // Counts propagation wait
    reg [SEL_W:0]             drain_cnt;       // Counts drain cycles

    reg                       flush_pending;   // Set when data_last seen in FIFO
    reg                       first_tile;      // Clear accumulators on first tile

    wire [DATA_WIDTH*ARRAY_SIZE-1:0] act_fifo_rd;
    wire [DATA_WIDTH*ARRAY_SIZE-1:0] weight_fifo_rd;
    wire                              info_fifo_rd;

    wire act_fifo_empty, weight_fifo_empty, info_fifo_empty;
    wire act_fifo_full,  weight_fifo_full;
    reg  fifo_rd_en;

    sync_fifo #(.WIDTH(DATA_WIDTH*ARRAY_SIZE), .DEPTH(FIFO_DEPTH)) u_act_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_data(act_wr_data), .wr_en(wr_en), .full(act_fifo_full),
        .rd_data(act_fifo_rd), .rd_en(fifo_rd_en), .empty(act_fifo_empty)
    );

    sync_fifo #(.WIDTH(DATA_WIDTH*ARRAY_SIZE), .DEPTH(FIFO_DEPTH)) u_weight_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_data(weight_wr_data), .wr_en(wr_en), .full(weight_fifo_full),
        .rd_data(weight_fifo_rd), .rd_en(fifo_rd_en), .empty(weight_fifo_empty)
    );

    sync_fifo #(.WIDTH(1), .DEPTH(FIFO_DEPTH)) u_info_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_data(data_last), .wr_en(wr_en), .full(),
        .rd_data(info_fifo_rd), .rd_en(fifo_rd_en), .empty(info_fifo_empty)
    );

    assign fifo_full = act_fifo_full | weight_fifo_full;

    wire fifos_have_data = !act_fifo_empty & !weight_fifo_empty & !info_fifo_empty;

    // Each of the ARRAY_SIZE rows stores a DIM-wide vector for the serializer
    reg [DATA_WIDTH*ARRAY_SIZE-1:0] act_staged  [0:ARRAY_SIZE-1];
    reg [DATA_WIDTH*ARRAY_SIZE-1:0] weight_staged [0:ARRAY_SIZE-1];

    integer s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (s = 0; s < ARRAY_SIZE; s = s + 1) begin
                act_staged[s]    <= 0;
                weight_staged[s] <= 0;
            end
        end else if (state == S_STAGE && fifo_rd_en) begin
            act_staged[stage_cnt[SEL_W-1:0]]    <= act_fifo_rd;
            weight_staged[stage_cnt[SEL_W-1:0]] <= weight_fifo_rd;
        end
    end

    wire                         ser_load;
    wire                         ser_shift;
    wire [DATA_WIDTH-1:0]        act_serial_out  [0:ARRAY_SIZE-1];
    wire [DATA_WIDTH-1:0]        weight_serial_out [0:ARRAY_SIZE-1];

    // Load at the start of SERIALIZE phase, shift during SERIALIZE
    assign ser_load  = (state == S_SERIALIZE) && (serial_cnt == 0);
    assign ser_shift = (state == S_SERIALIZE) && (serial_cnt != 0);

    genvar g;
    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : SERIALIZERS
            serializer #(.DIM(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH)) u_act_ser (
                .clk(clk), .rst_n(rst_n),
                .load(ser_load), .shift(ser_shift),
                .par_in(act_staged[g]),
                .ser_out(act_serial_out[g])
            );
            serializer #(.DIM(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH)) u_weight_ser (
                .clk(clk), .rst_n(rst_n),
                .load(ser_load), .shift(ser_shift),
                .par_in(weight_staged[g]),
                .ser_out(weight_serial_out[g])
            );
        end
    endgenerate

    // Pack serializer outputs into vectors for skew modules
    wire [DATA_WIDTH*ARRAY_SIZE-1:0] act_serial_vec;
    wire [DATA_WIDTH*ARRAY_SIZE-1:0] weight_serial_vec;

    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : PACK_SERIAL
            assign act_serial_vec[g*DATA_WIDTH +: DATA_WIDTH]    = act_serial_out[g];
            assign weight_serial_vec[g*DATA_WIDTH +: DATA_WIDTH] = weight_serial_out[g];
        end
    endgenerate

    wire clear_skew = (state == S_SERIALIZE && serial_cnt == 0); // Clear at start of each tile

    skew_buffer #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH)) u_act_skew (
        .clk(clk), .rst_n(rst_n),
        .clear(clear_skew),
        .data_in(act_serial_vec),
        .data_out(act_to_array)
    );

    skew_buffer #(.ARRAY_SIZE(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH)) u_weight_skew (
        .clk(clk), .rst_n(rst_n),
        .clear(clear_skew),
        .data_in(weight_serial_vec),
        .data_out(weight_to_array)
    );

    assign result_out = psum_from_array;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            stage_cnt     <= 0;
            serial_cnt    <= 0;
            prop_cnt      <= 0;
            drain_cnt     <= 0;
            flush_pending <= 0;
            first_tile    <= 1;
            fifo_rd_en    <= 0;
            sa_clear      <= 0;
            sa_compute_en <= 0;
            sa_drain      <= 0;
            result_valid  <= 0;
        end else begin
            // Defaults
            sa_clear     <= 0;
            fifo_rd_en   <= 0;
            result_valid <= 0;

            case (state)
                S_IDLE: begin
                    sa_drain      <= 0;
                    sa_compute_en <= 0;
                    if (fifos_have_data && !flush_pending) begin
                        state      <= S_STAGE;
                        stage_cnt  <= 0;
                        fifo_rd_en <= 1;  // Start reading first entry
                    end
                end

                S_STAGE: begin
                    // Read one FIFO entry per cycle into staging register
                    if (stage_cnt == ARRAY_SIZE - 1) begin
                        // Last row staged
                        if (info_fifo_rd)
                            flush_pending <= 1;
                        state      <= S_SERIALIZE;
                        serial_cnt <= 0;
                        fifo_rd_en <= 0;
                    end else begin
                        stage_cnt  <= stage_cnt + 1;
                        // Check if next read will see data_last
                        if (info_fifo_rd)
                            flush_pending <= 1;
                        // Keep reading if more rows needed
                        if (fifos_have_data)
                            fifo_rd_en <= 1;
                        else
                            fifo_rd_en <= 0;
                    end
                end

                S_SERIALIZE: begin
                    sa_compute_en <= 1;

                    // Pulse clear on the first cycle of the first tile
                    if (serial_cnt == 0 && first_tile) begin
                        sa_clear   <= 1;
                        first_tile <= 0;
                    end

                    if (serial_cnt == ARRAY_SIZE) begin
                        // Serialization done
                        state    <= S_PROPAGATE;
                        prop_cnt <= 0;
                    end else begin
                        serial_cnt <= serial_cnt + 1;
                    end
                end

                S_PROPAGATE: begin
                    sa_compute_en <= 1;

                    if (prop_cnt == PROPAGATE_CYCLES - 1) begin
                        sa_compute_en <= 0;
                        if (flush_pending) begin
                            state        <= S_DRAIN;
                            drain_cnt    <= 0;
                            sa_drain     <= 1;
                            result_valid <= 1;
                        end else begin
                            // More tiles to accumulate
                            state <= S_IDLE;
                        end
                    end else begin
                        prop_cnt <= prop_cnt + 1;
                    end
                end

                S_DRAIN: begin
                    sa_drain     <= 1;
                    result_valid <= 1;

                    if (drain_cnt == ARRAY_SIZE - 1) begin
                        sa_drain      <= 0;
                        result_valid  <= 0;
                        flush_pending <= 0;
                        first_tile    <= 1;
                        state         <= S_IDLE;
                    end else begin
                        drain_cnt <= drain_cnt + 1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule