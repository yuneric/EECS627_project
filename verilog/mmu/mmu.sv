module mmu #( 
    parameter CPU_ADDR_WIDTH = 32, 
    parameter CPU_DATA_WIDTH = 32,
    parameter NPU_ACT_ADDR_WIDTH = 12,
    parameter NPU_WT_ADDR_WIDTH = 11,
    parameter NPU_DATA_WIDTH = 64
) (
    input  i_clk,
    input  i_rst_n,

    input  i_load_weights, //signal to load weights (AXI read) -> write into weight sram
    input  i_load_tile, // reads an activation tile form off chip mem and writes into the host bank sram (coming from the AXI) 
    input  i_store_tile, // writes the finished output activations back to off chip mem (reads it from the host bank sram)

    input  [9:0] i_N, // load weights state only 
    input  [9:0] i_W,
    input  [9:0] i_H, 
    input  [9:0] i_words_per_channel, // how many 64-bit words make up all the channels per pixel
    input  [CPU_ADDR_WIDTH-1:0] i_addr, // base addr in off chip mem
    input  [9:0] i_tile_stride, // row pitch of the full feature map, so skip these many to get the next row

    output logic o_done,

    output logic [NPU_WT_ADDR_WIDTH-1:0] o_wgt_addr, // which address in SRAM to write to
    output logic o_wgt_wen, 
    output logic [NPU_DATA_WIDTH - 1:0] o_wgt_wdata,
    output logic [2:0] o_wgt_sram_sel, // which sram bnk within the SAs to write to

    output logic [NPU_ACT_ADDR_WIDTH - 1:0] o_act_waddr, 
    output logic o_act_wen, 
    output logic [NPU_DATA_WIDTH - 1:0] o_act_wdata,
    output logic [NPU_ACT_ADDR_WIDTH - 1:0] o_act_raddr, 
    output logic o_act_ren,

    input  [NPU_DATA_WIDTH- 1:0] i_act_rdata, 

    //all the npu signals from axi_arbiter
    output logic [CPU_ADDR_WIDTH-1:0] o_npu_araddr, //the address we want to read from the starting address.
    output logic [7:0]                o_npu_arlen, //the total number of bursts number of the 
    output logic [2:0]                o_npu_arsize, //the size of one beat.
    output logic                      o_npu_arvalid, //the npu sends that it is sending a valid address for read
    
    input                             i_npu_arready, //arready is set when arbiter received address
    input  [CPU_DATA_WIDTH-1:0]       i_npu_rdata, //read data.
    input                             i_npu_rlast, //rlast; done reading the bursts. 
    input                             i_npu_rvalid, //the data being sent is valid
    output logic                      o_npu_rready, //is the npu ready to receive data.

    output logic [CPU_ADDR_WIDTH-1:0] o_npu_awaddr,
    output logic [7:0]                o_npu_awlen,
    output logic [2:0]                o_npu_awsize,
    output logic                      o_npu_awvalid,
    input  logic                      i_npu_awready,
    output logic [CPU_DATA_WIDTH-1:0] o_npu_wdata,
    output logic [3:0]                o_npu_wstrb,
    output logic                      o_npu_wlast,
    output logic                      o_npu_wvalid,
    input  logic                      i_npu_wready,
    input  logic                      i_npu_bvalid, //need to use this; says that all the bursts are done writing
    output logic                      o_npu_bready //ready to receive bready
);
    assign o_npu_arsize = 3'b010;
    assign o_npu_wstrb = 4'hF;

    typedef enum logic [2:0] { 
        IDLE,   // wait for signal from the
        SETUP_MUL1,
        SETUP_MUL2,  // added for pipeline the row beats
        SEND_READ_REQ,  // drive AXI AR channel/ wait for arready handshake
        RECEIVE_READ_DATA, // AXI READ: wait for both beats to come back from the axi and then combine them together
        SEND_WRITE_ADDR, // one AXI write burst for the current row
        SEND_WRITE_DATA, //64-bit activation SRAM words into 32-bit AXI write split them
        WAIT_WRITE_RESP // wait for the bvalid handshake
    } state_t;

    state_t state, next_state;

    typedef enum logic [1:0] {
        NONE = 2'b00,
        LOAD_TILE = 2'b01,
        LOAD_WEIGHTS = 2'b10,
        STORE_TILE = 2'b11
    } op_type_t;

    op_type_t op_type; //type of operation

    logic beat_toggle; //beat_toggle keeps track of when 2-32 bit data arrives
    logic [CPU_DATA_WIDTH-1:0] half_word; //half_word received from axi bus
    
    logic [9:0] cfg_N_q;
    logic [9:0] cfg_W_q;
    logic [9:0] cfg_H_q;
    logic [9:0] cfg_words_per_channel_q;
    logic [9:0] cfg_tile_stride_q;

    logic [19:0] hw_q;
    logic [19:0] tile_words_q;
    logic [19:0] tile_stride_words_q;

    logic [19:0] hw_calc;
    logic [19:0] tile_words_calc;
    logic [19:0] tile_stride_words_calc;
    logic [19:0] kernel_words_calc;

    logic [29:0] kernel_words_mul;
    assign kernel_words_mul = hw_q * cfg_words_per_channel_q;
    assign hw_calc                = cfg_H_q * cfg_W_q;
    assign tile_words_calc        = cfg_W_q * cfg_words_per_channel_q;
    assign tile_stride_words_calc = cfg_tile_stride_q * cfg_words_per_channel_q;
    assign kernel_words_calc      = hw_calc * cfg_words_per_channel_q;

    logic [11:0] mem_if_addr;
    logic [10:0] row_counter, h_counter;

    logic [19:0] kernel_words; //64-bit words in one kernel = H * W * words_per_channel
    logic [19:0] kernel_word_count; //64-bit word offset within the active kernel
    logic [9:0] kernel_count; //kernel is currently being written
    logic [2:0] curr_wgt_bank;
    logic [7:0][10:0] wgt_bank_addr_tracker; 

    logic [CPU_ADDR_WIDTH-1:0] current_addr; // byte address of the axi burst 
    logic [CPU_ADDR_WIDTH-1:0] row_stride_bytes; // controller off chip row jump
    logic [9:0] beats_per_burst; //has to be less than 256

    logic [19:0] row_beats_total; // total axi beats needed for the row
    logic [19:0] row_beats_remaining; // axi beats left in the current row
    logic [CPU_ADDR_WIDTH-1:0] row_base_addr; //byte address of the start of the current row

    // ==============================================================================
    // Pipeline Wires for Timing Fix
    // ==============================================================================
    logic [CPU_ADDR_WIDTH-1:0]     next_npu_araddr;
    logic [7:0]                    next_npu_arlen;
    // logic [2:0]                    next_npu_arsize;
    logic                          next_npu_arvalid;
    logic                          next_npu_rready;

    logic [NPU_ACT_ADDR_WIDTH-1:0] next_act_raddr;
    logic                          next_act_ren;

    logic [CPU_ADDR_WIDTH-1:0]     next_npu_awaddr;
    logic [7:0]                    next_npu_awlen;
    logic [2:0]                    next_npu_awsize;
    logic                          next_npu_awvalid;
    logic [CPU_DATA_WIDTH-1:0]     next_npu_wdata;
    // logic [3:0]                    next_npu_wstrb;
    logic                          next_npu_wlast;
    logic                          next_npu_wvalid;
    logic                          next_npu_bready;
    // ==============================================================================

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            state               <= IDLE;
            beat_toggle         <= 0;
            half_word           <= 0;
            mem_if_addr         <= 0;
            h_counter           <= 0;
            row_counter         <= 0;
            current_addr        <= 0;
            op_type             <= NONE;
            row_stride_bytes    <= 0;
            row_beats_total     <= 0;
            row_beats_remaining <= 0;
            row_base_addr       <= 0;
            beats_per_burst     <= 0;
            kernel_words        <= 0;
            kernel_word_count   <= 0;
            kernel_count        <= 0;
            curr_wgt_bank       <= 0;
            wgt_bank_addr_tracker <= '0;

            cfg_N_q             <= '0;
            cfg_W_q             <= '0;
            cfg_H_q             <= '0;
            cfg_words_per_channel_q <= '0;
            cfg_tile_stride_q   <= '0;

            hw_q                <= '0;
            tile_words_q        <= '0;
            tile_stride_words_q <= '0;

        end else begin
            state <= next_state;
            
            case(state)
                IDLE: begin
                    if(i_load_tile || i_load_weights || i_store_tile) begin
                        if(i_load_tile) begin
                            op_type <= LOAD_TILE;
                        end else if (i_store_tile) begin
                            op_type <= STORE_TILE;
                        end else if (i_load_weights) begin
                            op_type <= LOAD_WEIGHTS;
                        end
                        cfg_N_q                 <= i_N;
                        cfg_W_q                 <= i_W;
                        cfg_H_q                 <= i_H;
                        cfg_words_per_channel_q <= i_words_per_channel;
                        cfg_tile_stride_q       <= i_tile_stride;
                        beat_toggle             <= 0;
                        half_word               <= 0;
                        mem_if_addr             <= 0;
                        row_counter             <= 0;
                        current_addr            <= i_addr;
                        row_base_addr           <= i_addr;
                        row_beats_remaining     <= '0;
                        row_beats_total         <= '0;
                        h_counter               <= 0;
                        row_stride_bytes        <= 0;
                        kernel_words            <= 0;
                        kernel_word_count       <= 0;
                        kernel_count            <= 0;
                        curr_wgt_bank           <= 0;
                        wgt_bank_addr_tracker   <= '0;
                        hw_q                    <= '0;
                        tile_words_q            <= '0;
                        tile_stride_words_q     <= '0;
                    end
                end    
                SETUP_MUL2: begin
                    hw_q                <= hw_calc;
                    tile_words_q        <= tile_words_calc;
                    tile_stride_words_q <= tile_stride_words_calc;

                    if(op_type == LOAD_WEIGHTS) begin
                        h_counter           <= cfg_N_q;
                        kernel_words        <= kernel_words_calc;
                        kernel_word_count   <= 0;
                        kernel_count        <= 0;
                        curr_wgt_bank       <= 0;
                        wgt_bank_addr_tracker <= '0;
                        row_stride_bytes    <= ({{12{1'b0}}, kernel_words_calc} << 3);
                        row_beats_remaining <= kernel_words_calc << 1;
                        row_beats_total     <= kernel_words_calc << 1;
                    end else begin
                        h_counter           <= cfg_H_q;
                        row_stride_bytes    <= ({{12{1'b0}}, tile_stride_words_calc} << 3);
                        row_beats_total     <= (tile_words_calc << 1);
                        row_beats_remaining <= (tile_words_calc << 1);
                    end
                end
                SEND_READ_REQ: begin
                    // hold signals steady
                end
                RECEIVE_READ_DATA: begin
                    if (i_npu_rvalid) begin
                        beat_toggle <= ~beat_toggle;

                        if (beat_toggle == 0) begin
                            half_word <= i_npu_rdata; 
                        end else begin
                            mem_if_addr <= mem_if_addr + 1; 
                            if (op_type == LOAD_WEIGHTS) begin 
                                if (kernel_word_count == kernel_words - 1) begin
                                    kernel_word_count <= 0; 
                                    kernel_count <= kernel_count + 1;
                                    if ((kernel_count % 8) == 7) begin 
                                        curr_wgt_bank <= curr_wgt_bank + 1;
                                        wgt_bank_addr_tracker[curr_wgt_bank] <= wgt_bank_addr_tracker[curr_wgt_bank] + 1;
                                    end else begin
                                        wgt_bank_addr_tracker[curr_wgt_bank] <= wgt_bank_addr_tracker[curr_wgt_bank] + 1;
                                    end
                                end else begin
                                    kernel_word_count  <= kernel_word_count + 1;
                                    wgt_bank_addr_tracker[curr_wgt_bank] <= wgt_bank_addr_tracker[curr_wgt_bank] + 1;
                                end
                            end
                        end

                        if (i_npu_rlast) begin 
                            beat_toggle <= 0;
                            if (row_beats_remaining <= 256) begin
                                row_counter        <= row_counter + 1;
                                current_addr       <= row_base_addr + row_stride_bytes;
                                row_base_addr      <= row_base_addr + row_stride_bytes;
                                row_beats_remaining <= row_beats_total;
                            end else begin
                                row_beats_remaining <= row_beats_remaining - 256;
                                current_addr <= current_addr + (256 * 4);
                            end
                        end
                    end
                end
                SEND_WRITE_ADDR: begin
                    if (i_npu_awready) begin
                        if (row_beats_remaining > 256) begin 
                            beats_per_burst <= 10'd256;
                        end else begin
                            beats_per_burst <= row_beats_remaining;
                        end
                        beat_toggle <= 1'b0;
                    end
                end
                SEND_WRITE_DATA: begin
                    //if (i_npu_wready) begin
                    if (i_npu_wready && o_npu_wvalid) begin
                        beats_per_burst <= beats_per_burst - 1;
                        beat_toggle <= ~beat_toggle;
                        if (beat_toggle != 1'b1) begin
                            mem_if_addr <= mem_if_addr + 1; 
                        end
                        if(beats_per_burst == 1) begin
                            beat_toggle <= 1'b0;
                        end
                    end
                end
                WAIT_WRITE_RESP: begin
                    if (i_npu_bvalid) begin
                        if(row_beats_remaining <= 256) begin
                            if (row_counter != h_counter - 1) begin
                                row_counter        <= row_counter + 1;
                                current_addr       <= row_base_addr + row_stride_bytes;
                                row_base_addr      <= row_base_addr + row_stride_bytes;
                                row_beats_remaining <= row_beats_total;
                            end
                        end else begin
                            row_beats_remaining <= row_beats_remaining - 256;
                            current_addr  <= current_addr + (256 * 4);
                        end
                    end
                end
                default: begin
                end
            endcase
        end
    end

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            o_act_wen   <= 0;
            o_act_waddr <= 0;
            o_act_wdata <= 0;
            o_wgt_wen   <= 0;
            o_wgt_addr  <= 0;
            o_wgt_wdata <= 0;
            o_wgt_sram_sel <= 0;
            o_done <= 1'b0;
        end else begin
            o_act_wen   <= 0;
            o_wgt_wen   <= 0;
            o_done <= 0;

            if(state == RECEIVE_READ_DATA && i_npu_rvalid && beat_toggle == 1) begin
                if (op_type == LOAD_TILE) begin
                    o_act_wen   <= 1;
                    o_act_waddr <= mem_if_addr;
                    o_act_wdata <= {i_npu_rdata,half_word};
                end else begin
                    o_wgt_wen      <= 1;
                    o_wgt_addr     <= wgt_bank_addr_tracker[curr_wgt_bank];
                    o_wgt_wdata    <= {i_npu_rdata, half_word};
                    o_wgt_sram_sel <= curr_wgt_bank;
                end
            end
            
            if(state == RECEIVE_READ_DATA && i_npu_rvalid && i_npu_rlast && (row_beats_remaining <=256) && (row_counter == h_counter - 1))begin
                o_done <= 1'b1;
            end
            if(state == WAIT_WRITE_RESP && i_npu_bvalid) begin
                if (row_beats_remaining <= 256) begin
                    if(row_counter == h_counter - 1) begin
                        o_done <= 1'b1;
                    end
                end
            end
        end
    end

    always_comb begin
        next_state = state;
        
        // Default Assignments to pipeline wires
        next_npu_araddr  = '0; 
        next_npu_arlen   = '0;
        // next_npu_arsize  = '0;
        next_npu_arvalid = 1'b0;
        next_npu_rready  = 1'b0;

        next_act_raddr   = '0;
        next_act_ren     = 1'b0;

        next_npu_awaddr  = '0;
        next_npu_awlen   = '0;
        next_npu_awsize  = '0;
        next_npu_awvalid = 1'b0;
        next_npu_wdata   = '0;
        // next_npu_wstrb   = '0;
        next_npu_wlast   = 1'b0;
        next_npu_wvalid  = 1'b0;
        next_npu_bready  = 1'b1;

        case (state)
            IDLE: begin
                if (i_load_tile || i_load_weights || i_store_tile) begin
                    next_state = SETUP_MUL1;
                end 
            end
            SETUP_MUL1: begin
                next_state = SETUP_MUL2;
            end
            SETUP_MUL2: begin
                if(op_type == STORE_TILE) begin
                    next_state = SEND_WRITE_ADDR;
                end else begin
                    next_state = SEND_READ_REQ;
                end
            end
            SEND_READ_REQ : begin
                next_npu_araddr = current_addr; 
                next_npu_arlen = (row_beats_remaining > 256) ? 8'd255 : (row_beats_remaining - 1);
                // next_npu_arsize = 3'b010;
                //next_npu_arvalid = 1'b1;
                //drop immediately to prevent trailing.
                next_npu_arvalid = !i_npu_arready;
                
                // NOTE: Handshake checks i_npu_arready directly here. 
                // Due to 1-cycle pipeline delay, the valid signal will reach the slave one cycle late.
                if(i_npu_arready) begin
                    next_state = RECEIVE_READ_DATA; 
                end
            end
            RECEIVE_READ_DATA: begin
                next_npu_rready = 1; 
                if (i_npu_rvalid && i_npu_rlast) begin
                    if (row_beats_remaining <= 256) begin
                        if (row_counter == h_counter - 1) begin
                            next_state = IDLE;
                        end else begin
                            next_state = SEND_READ_REQ;
                        end
                    end else begin
                        next_state = SEND_READ_REQ;
                    end
                end
            end
            SEND_WRITE_ADDR: begin
                next_npu_awaddr  = current_addr;
                next_npu_awlen  = (row_beats_remaining > 256) ? 8'd255 : (row_beats_remaining - 1);
                next_npu_awsize  = 3'b010;
                // next_npu_awvalid = 1'b1; 

                //drop immediately on handshake. 
                next_npu_awvalid = !i_npu_awready;

                //next_act_ren enabled so when moves to SEND_WRITE_DATA its been one cycle.
                next_act_ren     = 1'b1;
                next_act_raddr   = mem_if_addr;
                
                if (i_npu_awready) begin
                    next_state = SEND_WRITE_DATA;
                end
            end
            SEND_WRITE_DATA: begin
                next_act_ren   = 1'b1;
                next_act_raddr = mem_if_addr;

                //Drop valid immediately on handshake 
                //next_npu_wvalid = !i_npu_wready;
                next_npu_wvalid = 1'b1;
                // next_npu_wstrb  = 4'hF; 

                //if (beat_toggle == 1'b0) begin
                if ((o_npu_wvalid && i_npu_wready) ? ~beat_toggle : beat_toggle) begin
                    // next_npu_wdata = i_act_rdata[31:0];
                    next_npu_wdata = i_act_rdata[63:32];
                end else begin
                    //next_npu_wdata = i_act_rdata[63:32];
                    next_npu_wdata = i_act_rdata[31:0];
                end

                next_npu_wlast = (beats_per_burst == 1);

                if (i_npu_wready) begin
                    if (beats_per_burst == 1) begin
                        next_state = WAIT_WRITE_RESP;
                    end
                end
            end
            WAIT_WRITE_RESP: begin
                if (i_npu_bvalid) begin
                    if (row_beats_remaining <= 256) begin
                        if (row_counter == h_counter - 1) begin
                            next_state = IDLE;
                        end else begin
                            next_state = SEND_WRITE_ADDR;
                        end
                    end else begin
                        next_state = SEND_WRITE_ADDR;
                    end
                end
            end
        endcase
    end

    // ==============================================================================
    // Output Pipeline Register
    // ==============================================================================
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_npu_araddr  <= '0;
            o_npu_arlen   <= '0;
            // o_npu_arsize  <= '0;
            o_npu_arvalid <= 1'b0;
            o_npu_rready  <= 1'b0;

            o_act_raddr   <= '0;
            o_act_ren     <= 1'b0;

            o_npu_awaddr  <= '0;
            o_npu_awlen   <= '0;
            o_npu_awsize  <= '0;
            o_npu_awvalid <= 1'b0;
            o_npu_wdata   <= '0;
            // o_npu_wstrb   <= '0;
            o_npu_wlast   <= 1'b0;
            o_npu_wvalid  <= 1'b0;
            o_npu_bready  <= 1'b1;
        end else begin
            o_npu_araddr  <= next_npu_araddr;
            o_npu_arlen   <= next_npu_arlen;
            // o_npu_arsize  <= next_npu_arsize;
            o_npu_arvalid <= next_npu_arvalid;
            o_npu_rready  <= next_npu_rready;

            o_act_raddr   <= next_act_raddr;
            o_act_ren     <= next_act_ren;

            o_npu_awaddr  <= next_npu_awaddr;
            o_npu_awlen   <= next_npu_awlen;
            o_npu_awsize  <= next_npu_awsize;
            o_npu_awvalid <= next_npu_awvalid;
            o_npu_wdata   <= next_npu_wdata;
            // o_npu_wstrb   <= next_npu_wstrb;
            o_npu_wlast   <= next_npu_wlast;
            o_npu_wvalid  <= next_npu_wvalid;
            o_npu_bready  <= next_npu_bready;
        end
    end

endmodule
