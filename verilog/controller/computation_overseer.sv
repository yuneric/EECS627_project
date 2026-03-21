module computation_overseer #(
    parameter DIM                = 8,
    parameter NUM_ARRAYS         = 8,
    parameter DIM_WIDTH          = 10,
    parameter MEM_IF_ADDR_WIDTH  = 12,
    parameter WT_ADDR_WIDTH      = 11,
    parameter WORD_SIZE          = 64,
    parameter SHIFT_WIDTH   = 5
)(
    input  wire                                  i_clk, 
    input  wire                                  i_rst_n,

    //signals from/to the controller
    input logic                  i_comp_compute_start    , //signal from controller to start comp
    input logic [1:0]            i_comp_stride           , //the stride the filter moves from one patch to another
    input logic [1:0]            i_comp_padding          , //the padding comes from controller (tells how much padding is used - set by the user)
    input logic                  i_comp_maxpool_en       , //whether we want maxpooling enabled from the controller
    input logic                  i_comp_relu_en          , //whether we want relu enabled from the controller
    input logic [SHIFT_WIDTH-1:0] i_comp_scale_amt       , //the scale amount we'd need
    input logic [DIM_WIDTH-1:0]  i_comp_Hi               , //input height from controller
    input logic [DIM_WIDTH-1:0]  i_comp_Wi               , //input width from controller
    input logic [DIM_WIDTH-1:0]  i_comp_Hf               , //filter height
    input logic [DIM_WIDTH-1:0]  i_comp_Wf               , //filter width
    input logic [DIM_WIDTH-1:0]  i_comp_Ho               , //output height
    input logic [DIM_WIDTH-1:0]  i_comp_Wo               , //output width
    input logic [DIM_WIDTH-1:0]  i_comp_words_per_channel, //the number of words taken up for all the channels of a single pixel
    input logic [DIM_WIDTH-1:0]  i_comp_num_kernels      , //the number of kernels - from user via mmio
    output                       o_comp_done             , //sending the controller that the computation is done - handshake that helps trigger next set of data/signals

    //we have to send rd_addr and rd_en to mem_if and activation data is sent to the systolic array units
    output  [MEM_IF_ADDR_WIDTH-1:0] o_comp_waddr, //write the drain data to mem_if
    input   o_comp_wen, //write enable
    input  [WORD_SIZE-1:0] o_comp_wdata, //the 64-bit data written from the drain
    input  [MEM_IF_ADDR_WIDTH-1:0] o_comp_raddr, //sending read addr to read activation data
    input  o_comp_ren, //sending read enable

    //SA slice is one slice
    //SIGNALS TO AND FROM sa slice
    //cdc handshake
    output  logic                                 o_cdc_req, 
    input   logic                                 i_cdc_ack,
    output  logic                                 o_relu_en,
    output  logic [SHIFT_WIDTH-1:0]               o_shift_by,
    output  logic                                 o_maxpool_en,

    // Input Fifo
    output  logic [DIM-1:0] o_push_data_last,
    output  logic [DIM-1:0] o_push_en,
    input logic [DIM-1:0] i_push_fifo_full, //we need to get stuff from of our slices

    // Local weight SRAM ports - should get wt_sram_rd addr and en from im2col
    //weight addr rd addr and sram rd en
    output  logic [WT_ADDR_WIDTH-1:0] o_wt_sram_rd_addr,
    output  logic  o_wt_sram_rd_en,

    //notes need to pop_en to enable drain
    //pop_data is the data sent from 
    // Output Fifo
    output logic [WORD_SIZE-1:0] o_pop_data,
    output logic o_pop_en,
    input logic  [DIM-1:0] i_pop_empty

    // misc -we're gonna still use this for now
    output wire [NUM_ARRAYS-1:0] o_array_active,


    //from sa_slice - async fifos - need to edit in systolic array slice
    input logic i_almost_empty, //2 (max_pool enabled)
    input logic i_rd_full, //8 have all data.
    input logic i_rd_empty, //async 


);


    // FSM
    // localparam [3:0]
    //     IDLE       = 0, CONFIG     = 1, ST_SETUP  = 2, KG_SETUP  = 3,
    //     FEED_ADDR  = 4, FEED_WRITE = 5, DRAIN     = 6, OUTPUT_WB = 7,
    //     KG_NEXT    = 8, ST_NEXT    = 9;
    localparam [2:0] IDLE = 0, SETUP = 1, TILE_SETUP = 2, COMPUTE = 3, WAIT_FOR_DRAIN = 4, DRAIN = 5;

    //state logic
    logic [2:0] state, next_state;

    // Latched in i_start inputs
    logic [DIM_WIDTH-1:0] d_comp_Ho, d_comp_Wo, d_comp_num_kernels;
    logic [DIM_WIDTH-1:0] num_tiles_in_width, num_tiles_in_height, num_kernel_groups, num_kernels_per_group;

    //number of kernels processed will help us figure out which systolic arrays are active
    logic [DIM_WIDTH-1:0] kernels_processed, kernels_remaining; //keep track of how many kernels we've processed


    //tbd if we need this 
    logic [(DIM_WIDTH*2)-1:0] num_tiles;
    logic  d_comp_relu_en, d_comp_maxpool_en;
    logic  [SHIFT_WIDTH-1:0] d_comp_scale_amt;


    //tracker variables - the curr_tile_x, curr_tile_y, 
    logic [DIM_WIDTH-1:0] curr_tile_x, curr_tile_y, curr_kernel_group;


    // x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
    // y_bound = min(Ho - top_left_output_pixel_y - 1, 1)
    //2x4 so have to get the boundary indices
    // logic [1:0]                 x_bound; 
    // logic                       y_bound; 

    //im2col - start that goes into im2colgen
    logic im2col_gen_inputs_valid;

    assign im2col_gen_inputs_valid = (state == COMPUTE);



    // Indicates the active arrays 
    logic [NUM_ARRAYS-1:0] active;
    assign o_array_active = active;

    //next step is figuring out what setting logic does.
    // array_enable = [0] * num_arrays
    //     for array in range(num_arrays):
    //         if(kernels_processed < Co):
    //             array_enable[array] = 1
    //             kernels_processed += dim

    //ok, so from my understanding basically 1 -> 1m2 col is 64 kernels processed at once. 
    //we want to set it up in 

    //when send advance, you allow next weight address to be calculated.


    wire fifo_stall = |(i_sa_fifo_full & active);

    reg                    p_act_valid;
    reg [NUM_ARRAYS-1:0]  p_kern_valid;
    reg                    p_last;

    reg [DATA_WIDTH-1:0]   obuf [0:NUM_ARRAYS-1][0:DIM-1];
    reg [3:0]              cap_cnt [0:NUM_ARRAYS-1];
    reg [NUM_ARRAYS-1:0]   cap_done;
    reg [3:0]              wb_pix, wb_arr;

    //why no assign statements here
    wire [DIM_FIELD_WIDTH-1:0] co_remaining = d_comp_num_kernels - curr_kernel_group * NUM_ARRAYS;
    wire [3:0] n_active_m1 = (co_remaining >= NUM_ARRAYS) ? (NUM_ARRAYS - 1) : co_remaining[3:0] - 1;

    wire ic_start, ic_advance;
    wire [ACT_ADDR_WIDTH-1:0] ic_act_addr;
    wire                      ic_act_valid;
    wire [WT_ADDR_WIDTH-1:0]  ic_wt_addr;
    wire                      ic_wt_valid;
    wire                      ic_data_last, ic_addr_valid, ic_busy, ic_done;

    wire [WT_ADDR_WIDTH-1:0] ksz = i_cfg_Hf * i_comp_Wf * i_cfg_words_ci;
    reg  [WT_ADDR_WIDTH-1:0] kg_wt_off;

    im2col_gen u_im2col(
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),i_cfg_padding
        .i_cfg_tile_H(i_comp_Hi), 
        .i_cfg_tile_W(i_comp_Wi),
        .i_cfg_Hf(i_comp_Hf),
        .i_cfg_Wf(i_comp_Wf),
        .i_cfg_stride(i_comp_stride),
        .i_cfg_padding(i_comp_padding),
        .i_cfg_words_ci(i_comp_words_per_channel),
        .i_cfg_num_kernels_per_group(i_comp_num_kernels),
        .i_cfg_sub_tile_x(curr_tile_x),
        .i_cfg_sub_tile_y(curr_tile_y),
        // .i_cfg_x_bound(x_bound),
        // .i_cfg_y_bound(y_bound),
        .i_start(im2col_gen_inputs_valid), //start.
        // .i_advance(ic_advance),
        .o_act_addr(ic_act_addr),
        .o_act_valid(ic_act_valid),
        .o_wt_addr(ic_wt_addr),
        .o_wt_valid(ic_wt_valid),
        .o_data_last(ic_data_last),
        .o_addr_valid(ic_addr_valid),
        // .o_busy(ic_busy), 
        .o_done(ic_done)
    );

    assign ic_start   = (state == KG_SETUP);
    assign ic_advance = (state == FEED_WRITE) && !fifo_stall;

    //start with next state and go from there
    // always @(*) begin
    //     next_state = state;
    //     case (state)
    //         IDLE:       if (i_start) nxt = CONFIG;
    //         CONFIG:     nxt = ST_SETUP;
    //         ST_SETUP:   nxt = KG_SETUP;
    //         KG_SETUP:   nxt = FEED_ADDR;
    //         FEED_ADDR:  if (ic_addr_valid) nxt = FEED_WRITE;
    //         FEED_WRITE: begin
    //             if (fifo_stall)        nxt = FEED_WRITE;
    //             else if (p_last)       nxt = DRAIN;
    //             else                   nxt = FEED_ADDR;
    //         end
    //         DRAIN:      if ((i_sa_flush_done & active) == active) nxt = OUTPUT_WB;
    //         OUTPUT_WB:  if (wb_pix == DIM-1 && wb_arr == n_active_m1) nxt = KG_NEXT;
    //         KG_NEXT:    nxt = (curr_kernel_group == num_kg - 1) ? ST_NEXT : KG_SETUP;
    //         ST_NEXT: begin
    //             if (curr_tile_x == num_tiles_in_width - 1 && curr_tile_y == num_tiles_in_height - 1) nxt = IDLE;
    //             else nxt = ST_SETUP;
    //         end
    //         default:    nxt = IDLE;
    //     endcase
    // end

    //so there is moving to next kernel
    //there is moving to next tile -> both x and y

    //want to assign these to tge latched in values from the idle state
    assign o_relu_en = d_comp_relu_en;
    assign o_shift_by = d_comp_scale_amt;
    assign o_maxpool_en = d_comp_maxpool_en;

    //set the request
    assign o_cdc_req = (state == SETUP);

    //when in compute, my understanding is you set im2col_advanc
    //next_state logic.
    always @(*) begin
        next_state = state;
        case (state)
            IDLE:
                if(i_comp_compute_start) begin
                   next_state = SETUP;
                end
            SETUP:
                //you basically latch in the signals here 
                if(i_cdc_ack) begin
                    next_state = COMPUTE;
                end
            TILE_SETUP:
                //if we're done go to IDLE, else go to COMPUTE
                if(kernels_processed == d_comp_num_kernels) begin
                    next_state = IDLE;
                end else begin
                    next_state = COMPUTE;
                end
            COMPUTE:
                //if busy and not
                //if done then move to wait for drain
                if(ic_done) begin
                    next_state = WAIT_FOR_DRAIN;
                end
            //have this state because our fifo's are async
            WAIT_FOR_DRAIN:
                //if not empty - we move to drain
                // if(~(&i_pop_empty)) begin
                //     next_state = DRAIN;
                // end
                //now waiting for all the output data to arrive before we move to the drain state
                if((d_comp_maxpool_en && i_almost_empty) || i_rd_full) begin
                    next_state = DRAIN;
                end
            DRAIN:
                //if we've emp
                //if all the slice's asyncs are empty
                // if(&i_pop_empty) begin
                //     next_state = TILE_SETUP;
                // end
                if(i_rd_empty) begin
                    next_state = TILE_SETUP;
                end
        endcase
    end

    always @(posedge i_clk or negedge i_rst_n)
        if (!i_rst_n) state <= IDLE;
        else        state <= next_state;

    // Latch in inputs upon a i_start
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            d_comp_Ho<= 0; 
            d_comp_Wo<= 0;
            d_comp_num_kernels <= 0;
            num_tiles_in_width <= 0;
            num_tiles_in_height <= 0;
            num_kg <= 0;
            d_comp_relu_en <= 0;
            d_comp_maxpool_en <= 0;
        //latched in for setup
        end else if (state == IDLE && i_comp_compute_start) begin
            d_comp_Ho   <= i_comp_Ho;
            d_comp_Wo   <= i_comp_Wo;
            d_comp_num_kernels    <= i_comp_num_kernels;
            d_comp_relu_en  <= i_comp_relu_en;
            d_comp_maxpool_en <= i_comp_maxpool_en;
            // tiles_in_width = math.ceil(Wo/4) # how many tiles are in the output width-wise
            num_tiles_in_width <= (i_comp_Wo + 3) >> 2;
            // tiles_in_height = math.ceil(Ho/2) # how many tiles are in the output height-wise
            num_tiles_in_height <= (i_comp_Ho + 1) >> 1;
            // kernel_groups = math.ceil(Co/(dim*num_arrays)) # how many kernel groups we have to iterate through
            //we have 8 (2x4) outputs at a time and we have 8 arrays, so the number of groups outside this.
            num_kernel_groups  <= (i_comp_num_kernels / 64);

            d_comp_scale_amt <= i_comp_scale_amt;

            //we want to reset kernel's processed because we haven't use it yet. 
            kernels_processed <= '0;

            //want to reset these signals as well:
            curr_tile_x <= '0;
            curr_tile_y <= '0;
            curr_kernel_group <= '0;

            //kernels per group;
            //if there is 64 or less, then you just have 1 num_kernel_groups
            //you will set the rest in tile setup
            if(i_comp_num_kernels <= 64) begin
                num_kernels_per_group <= i_comp_num_kernels;
                active[0] <= (i_comp_num_kernels > 0);  // Array 0 handles kernels 1-8
                active[1] <= (i_comp_num_kernels > 8);  // Array 1 handles kernels 9-16
                active[2] <= (i_comp_num_kernels > 16); // Array 2 handles kernels 17-24
                active[3] <= (i_comp_num_kernels > 24); // Array 3 handles kernels 25-32
                active[4] <= (i_comp_num_kernels > 32); // Array 4 handles kernels 33-40
                active[5] <= (i_comp_num_kernels > 40); // Array 5 handles kernels 41-48
                active[6] <= (i_comp_num_kernels > 48); // Array 6 handles kernels 49-56
                active[7] <= (i_comp_num_kernels > 56); // Array 7 handles kernels 57-64
            end else begin
                num_kernels_per_group <= 64;
                active <= '1;
            end
        end else if (state == TILE_SETUP) begin
            //need to update kernels_processed -> should be adding num_kernels_per_group
            kernels_processed <= kernels_processed + num_kernels_per_group;

            //INCREMENT kernel group
            curr_kernel_group <= curr_kernel_group + 1; 
            
            //set num_kernels_per_group if you still need go to a new group.
            if((d_comp_num_kernels - (kernels_processed + num_kernels_per_group)) <= 64) begin
                num_kernels_per_group <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group));
                num_kernels_per_group <= i_comp_num_kernels;
                active[0] <= (i_comp_num_kernels > 0);  // Array 0 handles kernels 1-8
                active[1] <= (i_comp_num_kernels > 8);  // Array 1 handles kernels 9-16
                active[2] <= (i_comp_num_kernels > 16); // Array 2 handles kernels 17-24
                active[3] <= (i_comp_num_kernels > 24); // Array 3 handles kernels 25-32
                active[4] <= (i_comp_num_kernels > 32); // Array 4 handles kernels 33-40
                active[5] <= (i_comp_num_kernels > 40); // Array 5 handles kernels 41-48
                active[6] <= (i_comp_num_kernels > 48); // Array 6 handles kernels 49-56
                active[7] <= (i_comp_num_kernels > 56); // Array 7 handles kernels 57-64
            end else begin
                num_kernels_per_group <= 64;
                active <= '1;
            end

            //need to set up curr_tile_y
            //curr_tile_x
            if (curr_tile_x < num_tiles_in_width - 1)
                curr_tile_x <= curr_tile_x + 1;
                else begin
                    curr_tile_x <= 0;
                    curr_tile_y <= curr_tile_y + 1;
                end

        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            curr_tile_x <= 0; curr_tile_y <= 0; curr_kernel_group <= 0;
        end else case (state)
            CONFIG:   begin curr_tile_x <= 0; curr_tile_y <= 0; curr_kernel_group <= 0; end
            ST_SETUP: curr_kernel_group <= 0;
            KG_SETUP: kg_wt_off <= curr_kernel_group * ksz;
            ST_NEXT: begin
                if (curr_tile_x < num_tiles_in_width - 1)
                    curr_tile_x <= curr_tile_x + 1;
                else begin
                    curr_tile_x <= 0;
                    curr_tile_y <= curr_tile_y + 1;
                end
            end
            KG_NEXT: curr_kernel_group <= curr_kernel_group + 1;
            default: ;
        endcase
    end

    // x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
    // y_bound = min(Ho - top_left_output_pixel_y - 1, 1)
    always @(posedge i_clk) begin
        if (state == CONFIG || state == ST_SETUP) begin
            x_bound <= ((d_comp_Wo- {curr_tile_x, 2'b00}) > 4) ? 2'd3
                     : d_comp_Wo- {curr_tile_x, 2'b00} - 1;
            y_bound <= ((d_comp_Ho- {curr_tile_y, 1'b0}) >= 2) ? 1'b1 : 1'b0;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n)
            active <= 0;
        else if (state == KG_SETUP) begin
            if (co_remaining >= NUM_ARRAYS) active <= {NUM_ARRAYS{1'b1}};
            else                            active <= (1 << co_remaining) - 1;
        end
    end

    integer ai;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            o_act_rd_addr <= 0; o_act_rd_en <= 0;
            o_wt_rd_addr <= 0; o_wt_rd_en <= 0;
            p_act_valid <= 0; p_kern_valid <= 0; p_last <= 0;
        end else if (state == FEED_ADDR && ic_addr_valid) begin
            o_act_rd_addr <= ic_act_valid ? ic_act_addr : {ACT_ADDR_WIDTH{1'b0}};
            o_act_rd_en   <= 1;

            for (ai = 0; ai < NUM_ARRAYS; ai = ai + 1) begin
                o_wt_rd_addr[ai*WT_ADDR_WIDTH +: WT_ADDR_WIDTH]
                    <= (active[ai] && ic_wt_valid)
                       ? (ic_wt_addr + kg_wt_off + ai[WT_ADDR_WIDTH-1:0] * ksz)
                       : {WT_ADDR_WIDTH{1'b0}};
                o_wt_rd_en[ai] <= active[ai];
            end

            p_act_valid  <= ic_act_valid;
            p_kern_valid <= active & {NUM_ARRAYS{ic_wt_valid}};
            p_last       <= ic_data_last;
        end else begin
            o_act_rd_en <= 0;
            o_wt_rd_en  <= 0;
        end
    end

    integer fi;
    always @(*) begin
        o_sa_wr_en = 0; o_sa_wr_act_data = 0;
        o_sa_wr_wt_data = 0; o_sa_wr_data_last = 0;

        if (state == FEED_WRITE && !fifo_stall) begin
            o_sa_wr_act_data = p_act_valid ? i_act_rd_data : {DATA_WIDTH{1'b0}};
            for (fi = 0; fi < NUM_ARRAYS; fi = fi + 1) begin
                if (active[fi]) begin
                    o_sa_wr_en[fi] = 1;
                    o_sa_wr_wt_data[fi*DATA_WIDTH +: DATA_WIDTH]
                        = p_kern_valid[fi] ? i_wt_rd_data[fi*DATA_WIDTH +: DATA_WIDTH]
                                           : {DATA_WIDTH{1'b0}};
                    o_sa_wr_data_last[fi] = p_last;
                end
            end
        end
    end

    integer ci, di;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            cap_done <= 0;
            for (ci = 0; ci < NUM_ARRAYS; ci = ci + 1) cap_cnt[ci] <= 0;
        end else if (state == KG_SETUP) begin
            cap_done <= 0;
            for (di = 0; di < NUM_ARRAYS; di = di + 1) cap_cnt[di] <= 0;
        end else if (state == DRAIN || state == OUTPUT_WB) begin
            for (ci = 0; ci < NUM_ARRAYS; ci = ci + 1) begin
                if (i_sa_valid_out[ci] && active[ci] && !cap_done[ci]) begin
                    obuf[ci][DIM - 1 - cap_cnt[ci]] <= i_sa_data_out[ci*DATA_WIDTH +: DATA_WIDTH];
                    if (cap_cnt[ci] == DIM - 1) cap_done[ci] <= 1;
                    cap_cnt[ci] <= cap_cnt[ci] + 1;
                end
            end
        end
    end

    wire [1:0]                 wb_px = wb_pix[1:0];
    wire                       wb_py = wb_pix[2];
    wire [DIM_FIELD_WIDTH+1:0] abs_x = {curr_tile_x, 2'b00} + {{DIM_FIELD_WIDTH{1'b0}}, wb_px};
    wire [DIM_FIELD_WIDTH:0]   abs_y = {curr_tile_y, 1'b0}   + {{DIM_FIELD_WIDTH{1'b0}}, wb_py};

    wire [OUT_ADDR_WIDTH-1:0] wb_addr =
        (abs_y * d_comp_Wo+ abs_x) * d_comp_num_kernels + curr_kernel_group * NUM_ARRAYS + wb_arr;

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            wb_pix <= 0; wb_arr <= 0;
        end else if (state == KG_SETUP) begin
            wb_pix <= 0; wb_arr <= 0;
        end else if (state == OUTPUT_WB) begin
            if (wb_arr == n_active_m1) begin
                wb_arr <= 0;
                wb_pix <= wb_pix + 1;
            end else
                wb_arr <= wb_arr + 1;
        end
    end

    always @(*) begin
        o_out_wr_en = 0; o_out_wr_addr = 0; o_out_wr_data = 0;
        if (state == OUTPUT_WB && wb_px <= x_bound && wb_py <= y_bound) begin
            o_out_wr_en   = 1;
            o_out_wr_addr = wb_addr;
            o_out_wr_data = obuf[wb_arr][wb_pix];
        end
    end

    assign o_busy = (state != IDLE);
    assign o_done = (state == ST_NEXT) && (curr_tile_x == num_tiles_in_width-1) && (curr_tile_y == num_tiles_in_height-1);

endmodule