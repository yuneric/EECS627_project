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
    output  logic [CPU_ADDR_WIDTH-1:0] o_npu_araddr, //the address we want to read from the starting address.
    output  logic [7:0]            o_npu_arlen, //the total number of bursts number of the 
    output  logic [2:0]            o_npu_arsize, //the size of one beat.
    output  logic                  o_npu_arvalid, //the npu sends that it is sending a valid address for read
    
    input                           i_npu_arready, //arready is set when arbiter received address
    input  [CPU_DATA_WIDTH-1:0]         i_npu_rdata, //read data.
    input                           i_npu_rlast, //rlast; done reading the bursts. 
    input                           i_npu_rvalid, //the data being sent is valid
    output  logic                   o_npu_rready, //is the npu ready to receive data.

    output logic [CPU_ADDR_WIDTH-1:0] o_npu_awaddr,
    output logic [7:0]            o_npu_awlen,
    output logic [2:0]            o_npu_awsize,
    output logic                  o_npu_awvalid,
    input  logic                  i_npu_awready,
    output logic [CPU_DATA_WIDTH-1:0] o_npu_wdata,
    output logic [3:0]            o_npu_wstrb,
    output logic                  o_npu_wlast,
    output logic                  o_npu_wvalid,
    input  logic                  i_npu_wready,
    input  logic                  i_npu_bvalid, //need to use this; says that all the bursts are done writing
    output logic                  o_npu_bready //ready to receive bready
);

    // when bank_sel = 1 in the mem_if then it does read from Bank 0 and reads output from the b0_s1?
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
    // logic [19:0] mem_if_addr; //why is mem_if_addr this big? should only be 12 bits
    logic [9:0] cfg_N_q;
    logic [9:0] cfg_W_q;
    logic [9:0] cfg_H_q;
    logic [9:0] cfg_words_per_channel_q;
    logic [9:0] cfg_tile_stride_q;

    logic [19:0] hw_q;
    logic [19:0] tile_words_q;
    logic [19:0] tile_stride_words_q;


    logic [29:0] kernel_words_mul;
    assign kernel_words_mul = hw_q * cfg_words_per_channel_q;

    logic [11:0] mem_if_addr;
    logic [10:0] row_counter, h_counter;

    logic [19:0] kernel_words; //64-bit words in one kernel = H * W * words_per_channel
    logic [19:0] kernel_word_count; //64-bit word offset within the active kernel
    logic [9:0] kernel_count; //kernel is currently being written
    logic [2:0] curr_wgt_bank;
    logic [10:0] curr_wgt_bank_addr;

    //fix need to keep_track of addresses
    logic [7:0][10:0] wgt_bank_addr_tracker; 


    //logic [9:0] tile_stride;
    //TODO: might not need this everywhere
    logic [CPU_ADDR_WIDTH-1:0] current_addr; // byte address of the axi burst 

    //also row_stride_bytes
    logic [CPU_ADDR_WIDTH-1:0] row_stride_bytes; // controller off chip row jump
    logic [9:0] beats_per_burst; //has to be less than 256


    //TODO: need to think about the sizes of this bus - what is the max we'll get?
    logic [19:0] row_beats_total; // total axi beats needed for the row
    logic [19:0] row_beats_remaining; // axi beats left in the current row
    logic [CPU_ADDR_WIDTH-1:0] row_base_addr; //byte address of the start of the current row

    //UPDATE: ADDED NPU bvalid BECAUSE WE DONT WANT TO ISSUE NEXT WRITE UNTIL BVALID SHOWS UP
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            state               <= IDLE;
            beat_toggle         <= 0;
            half_word           <= 0;
            mem_if_addr           <= 0;
            h_counter           <= 0;
            row_counter         <= 0;
            current_addr        <= 0;
            op_type             <= NONE;
            //tile_stride         <= 0;
            //beats_per_burst     <= 0;
            row_stride_bytes    <= 0;
            row_beats_total     <= 0;
            row_beats_remaining <= 0;
            row_base_addr       <= 0;
            beats_per_burst     <= 0;
            kernel_words       <= 0;
            kernel_word_count  <= 0;
            kernel_count       <= 0;
            curr_wgt_bank      <= 0;
            // curr_wgt_bank_addr <= 0;
            wgt_bank_addr_tracker <= '0;

            cfg_N_q             <= '0;
            cfg_W_q             <= '0;
            cfg_H_q             <= '0;
            cfg_words_per_channel_q <= '0;
            cfg_tile_stride_q <= '0;

            hw_q <= '0;
            tile_words_q <= '0;
            tile_stride_words_q <= '0;

        end else begin
            state <= next_state;
            
            // o_done <= 0;
                case(state)
                IDLE: begin
                    //step 1: we set up the op_type
                    if(i_load_tile || i_load_weights || i_store_tile) begin
                        if(i_load_tile) begin
                            // pulsed once in the controller
                            op_type <= LOAD_TILE;
                        end else if (i_store_tile) begin
                            op_type <= STORE_TILE;
                        end else if (i_load_weights) begin
                            op_type <= LOAD_WEIGHTS;
                        end
                        cfg_N_q             <= i_N;
                        cfg_W_q             <= i_W;
                        cfg_H_q             <= i_H;
                        cfg_words_per_channel_q <= i_words_per_channel;
                        cfg_tile_stride_q <= i_tile_stride;
                        //beat toggle keeps track of whether we're loading high or low bit
                        beat_toggle  <= 0;
                        //latch in the low 32 bits.
                        half_word    <= 0;
                        //mem_if_addr- we'll need this for loading tiles
                        mem_if_addr    <= 0;
                        row_counter  <= 0;
                        //tile_stride <= i_tile_stride;
                        // each pixel has 16 channels 
                        // pack 8 channels into one 64-bit word uno, so one pixel needs 16/8 = N words (64 bit long) --> i_words_per_channel
                        // after each row burst is done, we will advance by 
                        // tile_stride * i_words_per_channel * (NPU_DATA_WIDTH / 8) bytes for the tiles
                        current_addr <= i_addr;
                        row_base_addr <= i_addr;
                        // //the total number of beats in a row.
                        // row_beats_total <= i_W * i_words_per_channel * 2;
                        // //how many of the beats are remaining per row
                        row_beats_remaining <= '0;
                        row_beats_total <= '0;
                        h_counter <= 0;
                        row_stride_bytes <= 0;
                        //row base addr. what's the difference between row_base_addr and current_addr -> NOTE: come back to this later.
                        
                        kernel_words <= 0;
                        kernel_word_count <= 0;
                        kernel_count <= 0;
                        curr_wgt_bank <= 0;
                        wgt_bank_addr_tracker <= '0;

                        hw_q <= '0;
                        tile_words_q <= '0;
                        tile_stride_words_q <= '0;
                    end
                end    
                SETUP_MUL1: begin
                    hw_q                <= cfg_H_q * cfg_W_q;
                    tile_words_q        <= cfg_W_q * cfg_words_per_channel_q;
                    tile_stride_words_q <= cfg_tile_stride_q * cfg_words_per_channel_q;

                end
                SETUP_MUL2: begin
                    if(op_type == LOAD_WEIGHTS) begin
                        h_counter           <= cfg_N_q;
                        kernel_words        <= kernel_words_mul[19:0];
                        kernel_word_count   <= 0;
                        kernel_count        <= 0;
                        curr_wgt_bank       <= 0;
                        wgt_bank_addr_tracker <= '0;

                        row_stride_bytes <= ({{(12){1'b0}}, kernel_words_mul[19:0]} << 3);
                        row_beats_remaining <= kernel_words_mul[19:0] << 1;
                        row_beats_total <= kernel_words_mul[19:0] << 1;
                    end else begin
                        h_counter <= cfg_H_q;
                        row_stride_bytes    <= ({{(12){1'b0}}, tile_stride_words_q} << 3);
                        row_beats_total     <= (tile_words_q << 1);
                        row_beats_remaining <= (tile_words_q << 1);

                    end

                end
                SEND_READ_REQ: begin
                    // read request
                    // hold signals steady until i_npu_arready is high
                end

                //COLLECT BEATS is just when you read from off chip memory -> you do this for load weights and load tile
                RECEIVE_READ_DATA: begin
                    if (i_npu_rvalid) begin

                        //beat_toggle - we're writing values.
                        beat_toggle <= ~beat_toggle;

                        //if lower 32 bits then store in a half_word
                        if (beat_toggle == 0) begin
                            half_word <= i_npu_rdata; //hold the low 32 bits
                        
                        //else we're processing the high 32-bits, so we want to increment out mem_if_addr by 1 for load tile operation so we could sent to the correct address next time.
                        end else begin
                            mem_if_addr <= mem_if_addr + 1; // second beat completes so move to the next address
                            //if we're loading weights
                            if (op_type == LOAD_WEIGHTS) begin // switch to the next bank only after every 8 kernels
                                //if all the words in a kernel have been processed
                                if (kernel_word_count == kernel_words - 1) begin
                                    //reset the counter
                                    kernel_word_count <= 0; // the last 64-bit word of the current kernel.
                                    //increment the kernel counter because we've just finished processing an entire kernel
                                    kernel_count <= kernel_count + 1;
                                    //if kernel_count is at 7 -> so 0 to 7 have been filled
                                    if ((kernel_count % 8) == 7) begin // Switch bank after every 8 kernels

                                        //increment curr_wgt_bank by 1 -> should be set to 0.
                                        curr_wgt_bank      <= curr_wgt_bank + 1;

                                        //don't reset the curr_wgt_bank_addr instead you have to just switch to looking at a different bank but still need to increment
                                        //why is current bank_addr set to 0.
                                        //curr_wgt_bank_addr <= 0;
                                        //the change will show up a cycle later.
                                        wgt_bank_addr_tracker[curr_wgt_bank] <= wgt_bank_addr_tracker[curr_wgt_bank] + 1;
                                    end 
                                    else begin
                                        //same bank and advance to the next kernel slot
                                        //curr_wgt_bank_addr <= curr_wgt_bank_addr + 1;
                                        wgt_bank_addr_tracker[curr_wgt_bank] <= wgt_bank_addr_tracker[curr_wgt_bank] + 1;
                                    end
                                end else begin
                                    //advance both the kernel-local word count and the bank-local address within the same banmk
                                    //one more pixel in kernel has been processed so increment the kernel word counter
                                    kernel_word_count  <= kernel_word_count + 1;
                                    //curr_wgt_bank_addr <= curr_wgt_bank_addr + 1;
                                    wgt_bank_addr_tracker[curr_wgt_bank] <= wgt_bank_addr_tracker[curr_wgt_bank] + 1;
                                end
                            end
                        end

                        //if we get the last beat
                        if (i_npu_rlast) begin // axi burst finished
                            //reset beat_toggle
                            beat_toggle <= 0;

                            //if the beats remaining are less than 256
                            if (row_beats_remaining <= 256) begin
                                //so here we're doing both by row -> this is not efficient for streaming weights so come back to this.
                                row_counter        <= row_counter + 1;
                                //move to next address -> which is row_base_raddr + the number of stides we read.
                                current_addr   <= row_base_addr + row_stride_bytes;
                                //incrementing the row_base_addr -> incrementing row_base_addr + update it to be the same as current.
                                row_base_addr      <= row_base_addr + row_stride_bytes;
                                //I think this is the reset  logic -> so it sets it up for the next read because we're receiving the last beat.
                                row_beats_remaining <= row_beats_total;
                            //else we have 256 length beats
                            end else begin
                                row_beats_remaining <= row_beats_remaining - 256;
                                //current_addr <= current_addr + (256 * (CPU_DATA_WIDTH / 8));
                                current_addr <= current_addr + (256 * 4);
                            end
                        end
                    end
                end

                //okay this is send write addr logic
                //this logic is not consistent with read request logic.
                SEND_WRITE_ADDR: begin

                    //if npu is awready, then ready to receivee values
                    if (i_npu_awready) begin
                        if (row_beats_remaining > 256) begin 
                            beats_per_burst <= 10'd256;
                        end else begin
                            beats_per_burst <= row_beats_remaining;
                        end
                    
                        //reset beat_toggle
                        beat_toggle <= 1'b0;
                    end
                end

                SEND_WRITE_DATA: begin
                    if (i_npu_wready) begin
                        //keep track of beats per burst - this enables us to signal the wlast
                        beats_per_burst <= beats_per_burst - 1;
                        //toggle the beats to keep track of whether we're sending the lower 32 bits or upper 32 bits
                        beat_toggle <= ~beat_toggle;
                        //if we're dealing with the upper 32 bits, then increment the mem_if address to the next.
                        if(beat_toggle == 1'b1) begin
                            mem_if_addr <= mem_if_addr + 1; // both half_wrod sent
                        end
                        //if we're at the last beat
                        if(beats_per_burst  == 1) begin
                            //reset beat_toggle
                            beat_toggle <= 1'b0;
                        end
                    end
                end
                
                WAIT_WRITE_RESP: begin
                    if (i_npu_bvalid) begin
                        //if there are less than 256 beats remaining
                        if(row_beats_remaining <= 256) begin
                            //burst finished the current row
                            //check if more rows left then jump to the next off-chip row base
                            //if we are not at the height we want to be, we need to issue more burst requests
                            if (row_counter != h_counter - 1) begin
                                //we increment row counter
                                row_counter        <= row_counter + 1;
                                //this follow the read logic with resetting current_addr, row_base_addr
                                //this is reset logic cause we're done with the burst and the row so that's why this works.
                                current_addr   <= row_base_addr + row_stride_bytes;
                                row_base_addr      <= row_base_addr + row_stride_bytes;
                                row_beats_remaining <= row_beats_total;
                            end
                        end else begin
                            //we still have 256 beats amount or more to issue
                            row_beats_remaining <= row_beats_remaining - 256;
                            //current_addr  <= current_addr + (256 * (CPU_DATA_WIDTH / 8));
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

            // o_done <= 0;
            if(state == RECEIVE_READ_DATA && i_npu_rvalid && beat_toggle == 1) begin
                if (op_type == LOAD_TILE) begin
                    o_act_wen   <= 1;
                    o_act_waddr <= mem_if_addr; //act_sram address 
                    o_act_wdata <= {i_npu_rdata,half_word};
                end else begin
                    o_wgt_wen      <= 1;
                    o_wgt_addr     <= wgt_bank_addr_tracker[curr_wgt_bank]; //curr_wgt_bank_addr;
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
        // o_act_wen   = 0;
        // o_act_waddr = 0;
        // o_act_wdata = 0;
        // o_wgt_wen   = 0;
        // o_wgt_addr  = 0;
        // o_wgt_wdata = 0;
        // o_wgt_sram_sel = 0;
        // o_done  = 0;
        o_npu_araddr = 0; // the addr for this burst
        o_npu_arlen = 0;
        o_npu_arsize = '0;
        o_npu_arvalid = 0;
        o_npu_rready = 0;

        o_act_raddr   = 0;
        o_act_ren     = 0;

        o_npu_awaddr  = 0;
        o_npu_awlen   = 0;
        o_npu_awsize  = 0;
        o_npu_awvalid = 0;
        o_npu_wdata   = 0;
        o_npu_wstrb   = 0;
        o_npu_wlast   = 0;
        o_npu_wvalid  = 0;
        o_npu_bready  = 1;

        //next state logic
        case (state)

            //in the idle state
            IDLE: begin
                //if load tile or load weights we want to send read requests from off chip memory
                if (i_load_tile || i_load_weights || i_store_tile) begin
                    next_state = SETUP_MUL1;
                end 
                // keep waiting until controller give you a signal
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
                o_npu_araddr = current_addr; // the addr for this burst
                //o_npu_arlen = beats_per_burst - 1; // number of beats in one burst
                 o_npu_arlen = (row_beats_remaining > 256) ? 8'd255 : (row_beats_remaining - 1);
                // o_npu_arsize = $clog2(CPU_DATA_WIDTH/8);
                //always going to be 32-bit sized beats
                o_npu_arsize = 3'b010;
                o_npu_arvalid = 1'b1;
                if(i_npu_arready) begin
                    next_state = RECEIVE_READ_DATA; 
                end
            end

            RECEIVE_READ_DATA: begin
                //signaling that we're ready to receive data
                o_npu_rready = 1; 
                //the the data is valid and its the last, then check if we're at our last burst and if we're at our last burst we check the counter to see if we still have rows to process.
                if (i_npu_rvalid && i_npu_rlast) begin
                    if (row_beats_remaining <= 256) begin
                        if (row_counter == h_counter - 1) begin

                            //if we're done go to idle
                            next_state = IDLE;

                            //signal done
                            // o_done     = 1;
                        //else stay in read request
                        end else begin
                            next_state = SEND_READ_REQ;
                        end
                    //if there's more than 256 beats stay in the send read request,
                    end else begin
                        next_state = SEND_READ_REQ;
                    end
                end
            end
            SEND_WRITE_ADDR: begin
                // send write address for store tile
                //write addr is set to current addr.               
                o_npu_awaddr  = current_addr;

                //if the beats remaining are greater than 256, then 255 beats
                o_npu_awlen  = (row_beats_remaining > 256) ? 8'd255 : (row_beats_remaining - 1);
                o_npu_awsize  = 3'b010;
                o_npu_awvalid = 1'b1; // handshake happens when o_npu_awready is high and o_npu_awvalid is high

                //fetch the first SRAM word while we wait for the address handshake
                o_act_ren     = 1'b1;
                o_act_raddr   = mem_if_addr;
                //dvance to data phase once the interconnect accepts the address
                if (i_npu_awready) begin
                    next_state = SEND_WRITE_DATA;
                end
            end
            SEND_WRITE_DATA: begin
                // reading the activation SRAM so the current word is always
                // present on i_act_rdata
                o_act_ren   = 1'b1;
                o_act_raddr = mem_if_addr;

                o_npu_wvalid = 1'b1;
                o_npu_wstrb  = 4'hF; // all bytes valid

                //which set of 32 bits to send
                if (beat_toggle == 1'b0) begin
                    o_npu_wdata = i_act_rdata[31:0];
                end else begin
                    o_npu_wdata = i_act_rdata[63:32];
                end

                //set that we're writing the last beat
                o_npu_wlast = (beats_per_burst == 1);

                //if slave is receiving values
                if (i_npu_wready) begin
                    if (beats_per_burst == 1) begin
                        // burst is complete, wait for bvalid
                        next_state = WAIT_WRITE_RESP;
                    end
                end
            end
            
            WAIT_WRITE_RESP: begin
                if (i_npu_bvalid) begin
                    // burst is complete
                    if (row_beats_remaining <= 256) begin
                        // row is finished
                        if (row_counter == h_counter - 1) begin
                            next_state = IDLE;
                            //o_done     = 1;
                        end else begin
                            // more rows to fetch issue the next rows's write addr
                            next_state = SEND_WRITE_ADDR;
                        end
                    end else begin
                        // row needs another burst 
                        next_state = SEND_WRITE_ADDR;
                    end
                end
            end
        endcase
    end
endmodule
