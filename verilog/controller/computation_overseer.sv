module computation_overseer #(
    parameter DIM                = 8,
    parameter NUM_ARRAYS         = 8,
    parameter DIM_WIDTH          = 10,
    parameter MEM_IF_ADDR_WIDTH  = 12,
    parameter WT_ADDR_WIDTH      = 11,
    parameter WORD_SIZE          = 64,
    parameter SHIFT_WIDTH        = 5
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
    output   o_comp_wen, //write enable
    output  [WORD_SIZE-1:0] o_comp_wdata, //the 64-bit data written from the drain

    //to read mem_if
    //comes from im2col_gen
    output  [MEM_IF_ADDR_WIDTH-1:0] o_comp_raddr, //sending read addr to read activation data
    output  o_comp_ren, //sending read enable

    //SA slice is one slice
    //SIGNALS TO AND FROM sa slice
    //cdc handshake
    output  logic                                 o_cdc_req, 
    input   logic                                 i_cdc_ack,
    output  logic                                 o_relu_en,
    output  logic [SHIFT_WIDTH-1:0]               o_shift_by,
    output  logic                                 o_maxpool_en,

    // Input Fifo
    //TODO: need to ask about these signals -> probably have to interface with im2col_gen don't worry about this.
    output  logic [DIM-1:0] o_push_data_last,
    output  logic [DIM-1:0] o_push_en,
    input logic [DIM-1:0] i_push_fifo_full, //we need to get stuff from of our slices

    // Local weight SRAM ports - should get wt_sram_rd addr and en from im2col
    //weight addr rd addr and sram rd en
    //comes from im2col_gen
    //this is fine because all 8 will need to read from this
    output  logic [WT_ADDR_WIDTH-1:0] o_wt_sram_rd_addr,
    output  logic  o_wt_sram_rd_en,

    //notes need to pop_en to enable drain
    //pop_data is the data sent from 
    // Output Fifo
    //TODO: discuss but i'm assuming there's going to be some sort of muxing logic that only sends one set of 64 bits.
    input logic [WORD_SIZE-1:0] i_pop_data,
    output logic [DIM-1:0] o_pop_en,
    input logic  [DIM-1:0] i_pop_empty, 

    // misc -we're gonna still use this for now
    output wire [NUM_ARRAYS-1:0] o_array_active,


    //from sa_slice - async fifos - need to edit in systolic array slice
    input logic [DIM-1:0] i_almost_empty, //2 (max_pool enabled)
    input logic [DIM-1:0] i_rd_full, //8 have all data.
    input logic [DIM-1:0] i_rd_empty //async 

);


    localparam [2:0] IDLE = 0, SETUP = 1, TILE_SETUP = 2, COMPUTE = 3, WAIT_FOR_DRAIN = 4, DRAIN = 5;

    //state logic
    logic [2:0] state, next_state;

    //drain logic write address.
    logic [MEM_IF_ADDR_WIDTH-1:0] curr_drain_waddr;
    logic drain_wen; //write enable
    logic  [WORD_SIZE-1:0] drain_wdata; //the 64-bit data written from the drain
    
    //Add pipelining registers to handle 1-cycle FIFO read latency!
    logic drain_wen_q;
    logic [MEM_IF_ADDR_WIDTH-1:0] curr_drain_waddr_q;

    //account for 1 cycle of latency
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            drain_wen_q <= '0;
            curr_drain_waddr_q <= '0;
            drain_wdata <= '0;
        end else begin
            drain_wen_q <= drain_wen;
            curr_drain_waddr_q <= curr_drain_waddr;
            if (drain_wen_q) begin
                drain_wdata <= i_pop_data;
            end
        end
    end

    //assign the drain write info to the output port using the DELAYED signals. 
    assign o_comp_waddr = curr_drain_waddr_q; 
    assign o_comp_wen = drain_wen_q;         
    assign o_comp_wdata = drain_wdata;

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
    logic [1:0]                 x_bound; 
    logic                       y_bound;
    logic [DIM_WIDTH-1:0]       potential_x_bound, potential_y_bound;

    //im2col - start that goes into im2colgen
    logic im2col_gen_inputs_valid;

    assign im2col_gen_inputs_valid = (state == COMPUTE);



    // Indicates the active arrays 
    logic [NUM_ARRAYS-1:0] active;
    assign o_array_active = active;

    //handshake signal to let you know that you've gone through all the kernel groups
    assign o_comp_done = ((curr_tile_x == num_tiles_in_width - 1) && 
                    (curr_tile_y == num_tiles_in_height - 1) && 
                    ((kernels_processed + num_kernels_per_group) >= d_comp_num_kernels)); 

    //next step is figuring out what setting logic does.
    // array_enable = [0] * num_arrays
    //     for array in range(num_arrays):
    //         if(kernels_processed < Co):
    //             array_enable[array] = 1
    //             kernels_processed += dim

    //ok, so from my understanding basically 1 -> 1m2 col is 64 kernels processed at once. 
    //we want to set it up in 

    //when send advance, you allow next weight address to be calculated.


    wire ic_start, ic_advance;
    wire [MEM_IF_ADDR_WIDTH-1:0] ic_act_addr;
    wire                      ic_act_valid;
    wire [WT_ADDR_WIDTH-1:0]  ic_wt_addr;
    wire                      ic_wt_valid;
    wire                      ic_data_last, ic_addr_valid, ic_busy, ic_done;



   
   
    
    input                          i_fifo_full,

    output reg [MEM_IF_ADDR_WIDTH-1:0] o_act_addr,           // activation SRAM read address
    output reg                         o_act_valid,          // address is in-bounds (else zero-pad)
    output reg [WT_ADDR_WIDTH-1:0]     o_wt_addr,            // weight SRAM read address
    output reg [NUM_ARRAYS-1:0]        o_wt_valid,           // kernel index valid (else zero-pad)
    output reg                         o_push_en,            // push data into the fifo + read sram signal

    output reg                        o_im2col_done         // goes high on the cycle after data_last asserts


    im2col_gen u_im2col(
        .i_clk(i_clk),
        .i_rst_n(i_rst_n),
        .i_cfg_tile_H(i_comp_Hi), 
        .i_cfg_tile_W(i_comp_Wi),
        .i_cfg_Hf(i_comp_Hf),
        .i_cfg_Wf(i_comp_Wf),
        .i_cfg_stride(i_comp_stride),
        .i_cfg_padding(i_comp_padding),
        .i_cfg_words_ci(i_comp_words_per_channel),
        .i_cfg_curr_kernel_group(curr_kernel_group),
        .i_cfg_num_kernels_per_group(num_kernels_per_group),
        .i_cfg_sub_tile_x(curr_tile_x),
        .i_cfg_sub_tile_y(curr_tile_y),
        .i_cfg_x_bound(x_bound),
        .i_cfg_y_bound(y_bound),
        .i_im2col_start(im2col_gen_inputs_valid), //start.
        .i_fifo_full(|i_push_fifo_full),
        .o_act_addr(o_comp_raddr),
        .o_act_valid(o_comp_ren),
        .o_wt_addr(o_wt_sram_rd_addr),
        .o_wt_valid(o_wt_sram_rd_en),
        .o_data_last(io_push_data_last),
        .o_addr_valid(o_push_en),
        .o_done(ic_done)
    );

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
    always_comb begin
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
                if ((curr_tile_x == num_tiles_in_width - 1) && 
                    (curr_tile_y == num_tiles_in_height - 1) && 
                    ((kernels_processed + num_kernels_per_group) >= d_comp_num_kernels)) begin
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
                if((d_comp_maxpool_en && (&i_almost_empty)) || (&i_rd_full)) begin
                    next_state = DRAIN;
                end
            DRAIN:
                //we could just do empty
                //and all the signals so fully empty -> all systolic array output buffers are empty.
                if (&i_rd_empty) begin
                    next_state = TILE_SETUP;
                end
            default: next_state = IDLE; // Good practice guardrail
        endcase
    end

    always_ff @(posedge i_clk or negedge i_rst_n)
        if (!i_rst_n) state <= IDLE;
        else        state <= next_state;


    logic [NUM_ARRAYS-1:0] drain_curr_systolic_array; //keeps track of the current sa we're keeping track of.


    //assign
    //set x_bound and y_bound.
    //x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
    //y_bound = min(Ho - top_left_output_pixel_y - 1, 1)

    assign potential_x_bound = d_comp_Wo - ({curr_tile_x, 2'b00}) - 1; 
    assign potential_y_bound = d_comp_Ho - ({curr_tile_y, 1'b0}) - 1; 

   
    assign x_bound = (potential_x_bound < 2'd3) ? potential_x_bound[1:0] : 2'd3;
    assign y_bound = (potential_y_bound < 2'd1) ? potential_y_bound[0] : 1'b1;


    // Latch in inputs upon a i_start
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            d_comp_Ho<= 0; 
            d_comp_Wo<= 0;
            d_comp_num_kernels <= 0;
            num_tiles_in_width <= 0;
            num_tiles_in_height <= 0;
            num_kernel_groups <= 0; 
            d_comp_relu_en <= 0;
            d_comp_maxpool_en <= 0;


            //reset these variables:
            curr_drain_waddr <= '0;
            drain_wen <= '0;
            // drain_wdata <= '0; Removed, now handled in pipeline block above

            
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
            //this logic is the setup -> so this should be fine.
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
            //INCREMENT kernel group
            //we don't want to increment kernel group all the time.
            //basically if we're done with all the then we want to reset tile_x and tile_y and move to the next tile.
            //if curr_tile_x is less than num_tiles_in_width
            if(curr_tile_x < num_tiles_in_width - 1) begin
            //else so its at the last index, so we want to reset.
                curr_tile_x <= curr_tile_x + 1;
            end else begin
                //curr tile_x is reset
                curr_tile_x <= '0;
                //now we need to increment tile. 
                if(curr_tile_y < num_tiles_in_height - 1) begin
                    //increment tile y
                    curr_tile_y <= curr_tile_y + 1;
                end else begin 
                    //we're done with all the tiles so going to increment the kernels processed, update the things that are active etc.
                    curr_tile_y <= '0;

                    //kernel group is done.
                    curr_kernel_group <= curr_kernel_group + 1; 

                    //reset curr_drain_waddr to go back where it should be for the first pixel
                    curr_drain_waddr <= (kernels_processed >> 3);

                    //need to reset curr_sa.
                    drain_curr_systolic_array <= '0;

                    //update kernels processed and active
                    kernels_processed <= kernels_processed + num_kernels_per_group; 

                    if((d_comp_num_kernels - (kernels_processed + num_kernels_per_group)) <= 64) begin
                        num_kernels_per_group <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group));
                        active[0] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 0);  // Array 0 handles kernels 1-8
                        active[1] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 8);  // Array 1 handles kernels 9-16
                        active[2] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 16); // Array 2 handles kernels 17-24
                        active[3] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 24); // Array 3 handles kernels 25-32
                        active[4] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 32); // Array 4 handles kernels 33-40
                        active[5] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 40); // Array 5 handles kernels 41-48
                        active[6] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 48); // Array 6 handles kernels 49-56
                        active[7] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 56); // Array 7 handles kernels 57-64
                    end else begin
                        num_kernels_per_group <= 64;
                        active <= '1;
                    end
                end
            end   
        end else if (state == WAIT_FOR_DRAIN) begin 
            //reset these signals
            drain_curr_systolic_array <= '0; //keeps track of the current sa we're keeping track of.
        end else if (state == DRAIN) begin
            //starting over plan: so basically we go to drain after we're done calculating a tile.
            //so basically we do 64 channels for the tile and we do all the tiles, then we do the next 64 channels
            //so let's see if our active channels logic is correct. 

            //okay fixed that.
            //so for drain -> we go through each systolic array -> get the channels for one pixel, then get the next pixel.
            //if the kernel's processed is not the end, then you need to incorporate a stride which you could do using num_kernels_group.


            //you need to keep track of write_addr to mem_if which we have. 
            //we have drain_curr_systolic_array to do that -> when we're cycling back to systolic array 0, that's when we want to add in the stride.
            /* input logic [WORD_SIZE-1:0] o_pop_data,
            output logic [DIM-1:0] o_pop_en,
            input logic  [DIM-1:0] i_pop_empty*/

            //we basically want to pipeline pop_en, and then writing to output mem_if a cycle later [MEM_IF_ADDR_WIDTH-1:0] o_comp_waddr, //write the drain data to mem_if
            //output   o_comp_wen, //write enable
            //output  [WORD_SIZE-1:0] o_comp_wdata, //the 64-bit data written from the drain
            //ok let's thing about all the signals we'd need.

            //kernels_processed will tell you the stride; you could backtrack your written address to it when you start a new_kernel group; other wise you just want to keep incrementing. 
            //okay so when you get through all of the thigs in the second current group first pixel, then you would have to do, what's left + kernel's processed to get to the next pixel.
            //so you want to reset address to what you want it to be above. 

            //okay the first thing that is very simple to do is incerement drain_curr_systolic_array
            //if the next thing is active, then 
            if(drain_curr_systolic_array < 7 && active[drain_curr_systolic_array + 1]) begin
                drain_curr_systolic_array <= drain_curr_systolic_array + 1; 
                //increment mem_if address by 1.
                curr_drain_waddr <= curr_drain_waddr + 1;
            //else you want to circle back to the front.
            end else begin
                drain_curr_systolic_array <= '0;
                
                //when we circle back to the front we want to check the stride because we're moving to a new pixel.
                
                //at this point we're moving onto the next pixel, so have to calculate stride
                //increment mem_if address by 1.
                //we want to increment the addrss to be current address + the remaining kernels.
                curr_drain_waddr <= curr_drain_waddr + ((d_comp_num_kernels - num_kernels_per_group) >> 3) + 1;
            end
  
        end
    end

    //always comb use to toggle o_pop_en, and pop_data.
    always_comb begin
        o_pop_en = '0;
        drain_wen = '0;

        if(state == DRAIN) begin
            o_pop_en[drain_curr_systolic_array] = 1;
            drain_wen = 1;
        end
    end

endmodule