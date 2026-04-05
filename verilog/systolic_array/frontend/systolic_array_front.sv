module systolic_array_front #(
    parameter ARRAY_SIZE  = 8,
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 32
)(

    input                                       i_clk,
    input                                       i_rst_n,

    input        [DATA_WIDTH*ARRAY_SIZE-1:0]    i_fifo_act_data,
    input        [DATA_WIDTH*ARRAY_SIZE-1:0]    i_fifo_weight_data,
    input                                       i_fifo_info_data,
    input                                       i_fifo_data_available,
    output logic                                o_fifo_rd_en,

    output logic [DATA_WIDTH*ARRAY_SIZE-1:0]     o_act_to_array,
    output logic [DATA_WIDTH*ARRAY_SIZE-1:0]     o_weight_to_array,

    output logic                                o_sa_clear,
    output logic                                o_sa_compute_en,
    output logic                                o_sa_drain,

    input        [PSUM_WIDTH*ARRAY_SIZE-1:0]    i_psum_from_array, // result from the array
    output logic [PSUM_WIDTH*ARRAY_SIZE-1:0]    o_result_out,
    output logic                                o_result_valid
);

    logic [$clog2(ARRAY_SIZE)-1:0] ser_load_idx;
    logic [$clog2(ARRAY_SIZE)-1:0] ser_load_idx_next;

    logic [ARRAY_SIZE-1:0] ser_load_sel;
    logic ser_load;
    logic ser_shift;

    always_comb begin
        for(integer i = 0; i < ARRAY_SIZE ; i = i + 1) begin
            ser_load_sel[i] = (ser_load_idx == i);
        end
    end
    
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] act_rd_data_staged;
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] weight_rd_data_staged;
    logic [DATA_WIDTH-1:0]            act_serial_out  [0:ARRAY_SIZE-1];
    logic [DATA_WIDTH-1:0]            weight_serial_out [0:ARRAY_SIZE-1];

    always_comb begin
        for (integer j = 0; j < ARRAY_SIZE; j = j + 1) begin : PACK_SERIAL
            o_act_to_array[j*DATA_WIDTH +: DATA_WIDTH]    = act_serial_out[j];
            o_weight_to_array[j*DATA_WIDTH +: DATA_WIDTH] = weight_serial_out[j];
        end
    end

    // WE CAN USE THE SERIALIZERS AS SKEW BUFFERS YIPPEEEEEEEEE
    genvar g;
    generate
        for (g = 0; g < ARRAY_SIZE; g = g + 1) begin : SERIALIZERS
            serializer #(.DIM(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH)) u_act_ser (
                .i_clk(i_clk), 
                .i_rst_n(i_rst_n),
                .i_load(ser_load_sel[g] & ser_load), 
                .i_shift(ser_shift),
                .i_par_in(act_rd_data_staged),
                .o_ser_out(act_serial_out[g])
            );
            serializer #(.DIM(ARRAY_SIZE), .DATA_WIDTH(DATA_WIDTH)) u_weight_ser (
                .i_clk(i_clk), 
                .i_rst_n(i_rst_n),
                .i_load(ser_load_sel[g] & ser_load), 
                .i_shift(ser_shift),
                .i_par_in(weight_rd_data_staged),
                .o_ser_out(weight_serial_out[g])
            );
        end
    endgenerate

    logic sa_clear, sa_compute_en, sa_drain;

    localparam PROPAGATE_CYCLES = 3 * ARRAY_SIZE - 1;
    localparam DRAIN_CYCLES = ARRAY_SIZE;

    logic [4:0] propagate_counter;
    logic [4:0] drain_counter;


    assign o_sa_clear = sa_clear;
    assign o_sa_compute_en = sa_compute_en;
    assign o_sa_drain = sa_drain;

    // typedef enum {IDLE, COMPUTE, DATA_STALL, PROPAGATE, DRAIN} ctrl_state_t;
    typedef enum logic [2:0] {IDLE, COMPUTE_IDLE, COMPUTE, COMPUTE_LAST, PROPAGATE, DRAIN} ctrl_state_t;
    ctrl_state_t ctrl_state;

    // top level control fsm
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            ser_load_idx        <= '0;
            ser_load_idx_next   <= '0;
            ser_shift           <= '0;
            ser_load            <= '0;
            o_fifo_rd_en        <= '0;
            sa_clear            <= '1;
            sa_compute_en       <= '0;
            sa_drain            <= '0;
            propagate_counter   <= '0;
            drain_counter       <= '0;
            act_rd_data_staged  <= '0;
            weight_rd_data_staged <= '0;
            o_result_out        <= '0;
            o_result_valid      <= '0;
            ctrl_state          <= IDLE;
        end else begin
            ser_load_idx        <= '0;
            ser_load_idx_next   <= '0;
            ser_shift           <= '0;
            ser_load            <= '0;
            o_fifo_rd_en        <= '0;
            sa_clear            <= '0;
            sa_compute_en       <= '0;
            sa_drain            <= '0;
            propagate_counter   <= '0;
            drain_counter       <= '0;
            act_rd_data_staged  <= '0;
            weight_rd_data_staged <= '0;
            o_result_out        <= '0;
            o_result_valid      <= '0;
            ctrl_state          <= IDLE;
            case(ctrl_state)
                IDLE : begin
                    if(i_fifo_data_available) begin
                        // Start a tile if data is available
                        o_fifo_rd_en <= 1; // set this to start the data stream
                        ctrl_state <= COMPUTE;
                    end else begin
                        ctrl_state <= IDLE;
                    end
                end 

                COMPUTE_IDLE : begin
                    // Make sure data still propagates through SA
                    ser_shift       <= 1;
                    sa_compute_en   <= 1;
                    if(i_fifo_data_available) begin
                        // start another stream if new data has arrived
                        o_fifo_rd_en      <= 1; // set this to start the data stream
                        ctrl_state <= COMPUTE;
                    end else begin
                        ctrl_state <= COMPUTE_IDLE;
                    end
                end

                COMPUTE : begin
                    sa_compute_en   <= 1;
                    ser_shift       <= 1;
                    ser_load        <= 1;
                    o_fifo_rd_en      <= 1;
                    ser_load_idx    <= ser_load_idx_next; // Delay it by a cycle
                    ser_load_idx_next <= ser_load_idx_next + 1;
                    act_rd_data_staged <= i_fifo_act_data;
                    weight_rd_data_staged <= i_fifo_weight_data;
                    ctrl_state <= COMPUTE;
                    if(ser_load_idx_next == ARRAY_SIZE - 2) begin
                        // were on the last piece of data for this 8
                        ctrl_state <= COMPUTE_LAST;
                    end 
                end

                COMPUTE_LAST : begin
                    sa_compute_en   <= 1;
                    ser_shift       <= 1;
                    ser_load        <= 1;
                    o_fifo_rd_en      <= 0; // stop data stream
                    ser_load_idx    <= ser_load_idx_next;
                    ser_load_idx_next <= 0;
                    act_rd_data_staged <= i_fifo_act_data;
                    weight_rd_data_staged <= i_fifo_weight_data;
                    // Check if we should read another 8 data or if we're done
                    if(i_fifo_info_data) begin
                        ctrl_state <= PROPAGATE;
                    end else if(i_fifo_data_available) begin
                        o_fifo_rd_en <= 1; // set this to start the next data stream
                        ctrl_state <= COMPUTE; // do another 8 reads
                    end else begin
                        ctrl_state <= COMPUTE_IDLE;
                    end
                end

                PROPAGATE : begin
                    sa_compute_en   <= 1;
                    ser_shift       <= 1;
                    if(propagate_counter == PROPAGATE_CYCLES) begin
                        sa_drain       <= 1;
                        ctrl_state     <= DRAIN;
                    end else begin
                        propagate_counter <= propagate_counter + 1;
                        ctrl_state <= PROPAGATE;
                    end
                end
                
                DRAIN : begin
                    sa_drain <= 1;
                    if(drain_counter == DRAIN_CYCLES) begin
                        ctrl_state <= IDLE;
                    end else begin 
                        drain_counter  <= drain_counter + 1;
                        o_result_out   <= i_psum_from_array;
                        o_result_valid <= 1;
                        ctrl_state <= DRAIN;
                    end
                end

                default : begin
                    ctrl_state <= IDLE;
                end
            endcase
        end
    end


endmodule