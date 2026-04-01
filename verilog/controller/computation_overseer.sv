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
    output                       o_comp_done             , //sending the controller that the computation is done - handshake that helps trigger next set of data/signals - so when finished calculating all the kernel groupss

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
    output  logic o_push_en,
    output logic o_data_last,
    input logic [NUM_ARRAYS-1:0] i_push_fifo_full, //we need to get stuff from of our slices

    // Local weight SRAM ports - should get wt_sram_rd addr and en from im2col
    output  logic [WT_ADDR_WIDTH-1:0] o_wt_sram_rd_addr,
    output  logic [NUM_ARRAYS-1:0] o_wt_sram_rd_en,

    // Output Fifo
    input logic [WORD_SIZE-1:0] i_pop_data,
    output logic [NUM_ARRAYS-1:0] o_pop_en,

    // misc -we're gonna still use this for now
    output wire [NUM_ARRAYS-1:0] o_array_active,

    //from sa_slice - async fifos
    input logic [NUM_ARRAYS-1:0] i_pop_almost_empty, //2 (max_pool enabled)
    input logic [NUM_ARRAYS-1:0] i_pop_full //8 have all data.
);

    //latch in these values into registers because they are already large wires.
    logic [NUM_ARRAYS-1:0] d_pop_almost_empty, d_pop_full;

    //will keep track of the number of writes to each array.
    logic [NUM_ARRAYS-1:0][2:0] drain_cntr;

    localparam [2:0] IDLE = 0, SETUP = 1, TILE_SETUP = 2, COMPUTE = 3, WAIT_FOR_DRAIN = 4, DRAIN = 5;

    //state logic
    logic [2:0] state, next_state;

    //drain logic write address.
    logic [MEM_IF_ADDR_WIDTH-1:0] curr_drain_waddr;
    logic drain_wen; //write enable
    logic [WORD_SIZE-1:0] drain_wdata; //the 64-bit data written from the drain
    
    //Add pipelining registers to handle 1-cycle FIFO read latency!
    logic drain_wen_q;
    logic [MEM_IF_ADDR_WIDTH-1:0] curr_drain_waddr_q;

    logic [2:0] drain_curr_systolic_array;

    //delay by a cycle -> to account for fifo.
    logic same_sa_slice_one_cycle_delay;

    //adding register to latch in cdc_ack and synchronize it because  give time to recover from metastability.
    logic d_cdc_ack, d1_cdc_ack;

    //account for 1 cycle of latency
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            drain_wen_q <= '0;
            curr_drain_waddr_q <= '0;
            drain_wdata <= '0;
        end else begin
            if(state == WAIT_FOR_DRAIN) begin
                //want to reset drain_cntr here:
                drain_cntr <= '0;
            end else begin
                //accounts for the cycle latency.
                //if not then don't want to set write_enable.
                if(!same_sa_slice_one_cycle_delay) begin
                    drain_wen_q <= drain_wen;
                end else begin
                    drain_wen_q <= '0;
                end

                curr_drain_waddr_q <= curr_drain_waddr;
            
                if (drain_wen && !same_sa_slice_one_cycle_delay) begin
                    //so this increments when we feed out comp_wen.
                    drain_cntr[drain_curr_systolic_array] <= drain_cntr[drain_curr_systolic_array] + 1; 
                end
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
    logic [DIM_WIDTH-1:0] kernels_processed, kernels_remaining;

    logic  d_comp_relu_en, d_comp_maxpool_en;
    logic  [SHIFT_WIDTH-1:0] d_comp_scale_amt;

    //tracker variables
    logic [DIM_WIDTH-1:0] curr_tile_x, curr_tile_y, curr_kernel_group;

    logic [1:0]                 x_bound; 
    logic                       y_bound;
    logic [DIM_WIDTH-1:0]       potential_x_bound, potential_y_bound;

    //this keeps track of the current pixel.
    logic [DIM_WIDTH-1:0]       output_pixel_x, output_pixel_y, next_pixel_x, next_pixel_y;

    //im2col - start that goes into im2colgen
    logic im2col_start;

    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin 
            im2col_start = 1'b0;
        end else begin
            im2col_start = ((state == SETUP) || (state == TILE_SETUP)) && (next_state == COMPUTE);
        end
    end

    //done signal from im2gencol 
    logic ic_done; 

    // Indicates the active arrays 
    logic [NUM_ARRAYS-1:0] active;
    assign o_array_active = active;

    assign o_comp_done = (state == TILE_SETUP) && (next_state == IDLE);

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
        .i_im2col_start(im2col_start),
        .i_fifo_full(|i_push_fifo_full),
        .o_act_addr(o_comp_raddr),
        .o_act_valid(o_comp_ren),
        .o_wt_addr(o_wt_sram_rd_addr),
        .o_wt_valid(o_wt_sram_rd_en),
        .o_push_en(o_push_en),
        .o_im2col_done(ic_done)
    );

    assign o_data_last = ic_done;
    assign o_relu_en = d_comp_relu_en;
    assign o_shift_by = d_comp_scale_amt;
    assign o_maxpool_en = d_comp_maxpool_en;
    assign o_cdc_req = (state == SETUP);

    //next_state logic.
    always_comb begin
        next_state = state;
        case (state)
            IDLE:
                if(i_comp_compute_start) begin
                   next_state = SETUP;
                end
            SETUP:
                //if(i_cdc_ack) begin
                if(d1_cdc_ack) begin
                    next_state = COMPUTE;
                end
            TILE_SETUP:
                if ((curr_tile_x == num_tiles_in_width - 1) && 
                    (curr_tile_y == num_tiles_in_height - 1) && 
                    ((kernels_processed + num_kernels_per_group) >= d_comp_num_kernels)) begin
                    next_state = IDLE;
                end else begin
                    next_state = COMPUTE;
                end
            COMPUTE:
                if(ic_done) begin
                    next_state = WAIT_FOR_DRAIN;
                end
            WAIT_FOR_DRAIN:
                if ((d_comp_maxpool_en && (&(~d_pop_almost_empty | ~active))) || (&(d_pop_full | ~active))) begin
                    next_state = DRAIN;
                end
            DRAIN:
                if(drain_curr_systolic_array < 7 && !active[drain_curr_systolic_array + 1] && d_comp_maxpool_en && drain_cntr[drain_curr_systolic_array] == 1) begin
                    next_state = TILE_SETUP;
                end else if(drain_curr_systolic_array < 7 && !active[drain_curr_systolic_array + 1] && drain_cntr[drain_curr_systolic_array] == 7) begin
                    next_state = TILE_SETUP;
                end else if(drain_curr_systolic_array == 7 && d_comp_maxpool_en && drain_cntr[drain_curr_systolic_array] == 1) begin
                    next_state = TILE_SETUP;
                end else if(drain_curr_systolic_array == 7 && drain_cntr[drain_curr_systolic_array] == 7) begin
                    next_state = TILE_SETUP;
                end
            default: next_state = IDLE; 
        endcase
    end

    always_ff @(posedge i_clk or negedge i_rst_n)
        if (!i_rst_n) state <= IDLE;
        else        state <= next_state;

    assign potential_x_bound = d_comp_Wo - {curr_tile_x[DIM_WIDTH-3:0], 2'b00} - 1'b1;
    assign potential_y_bound = d_comp_Ho - {curr_tile_y[DIM_WIDTH-2:0], 1'b0} - 1'b1;
   
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

            curr_drain_waddr <= '0;
            d_pop_almost_empty <= '0;
            d_pop_full     <= '0;

            curr_kernel_group <= '0; 
            num_kernels_per_group <= '0;
            curr_tile_x <= '0;
            curr_tile_y <= '0;
            curr_drain_waddr <= '0;

            same_sa_slice_one_cycle_delay <= '0;

            //reset the cdc_ack signal
            d_cdc_ack <= '0;
            d1_cdc_ack <= '0;

        end else begin
            d_pop_almost_empty <= i_pop_almost_empty;
            d_pop_full     <= i_pop_full;
            
            case (state)
                IDLE: begin
                    if (i_comp_compute_start) begin
                        d_comp_Ho   <= i_comp_Ho;
                        d_comp_Wo   <= i_comp_Wo;
                        d_comp_num_kernels    <= i_comp_num_kernels;
                        d_comp_relu_en  <= i_comp_relu_en;
                        d_comp_maxpool_en <= i_comp_maxpool_en;
                        num_tiles_in_width <= (i_comp_Wo + 3) >> 2;
                        num_tiles_in_height <= (i_comp_Ho + 1) >> 1;
                        num_kernel_groups  <= (i_comp_num_kernels / 64);
                        d_comp_scale_amt <= i_comp_scale_amt;

                        kernels_processed <= '0;

                        curr_tile_x <= '0;
                        curr_tile_y <= '0;
                        curr_kernel_group <= '0;
                        curr_drain_waddr <= '0;
                       
                        if(i_comp_num_kernels <= 64) begin
                            num_kernels_per_group <= i_comp_num_kernels;
                            active[0] <= (i_comp_num_kernels > 0);  
                            active[1] <= (i_comp_num_kernels > 8);  
                            active[2] <= (i_comp_num_kernels > 16); 
                            active[3] <= (i_comp_num_kernels > 24); 
                            active[4] <= (i_comp_num_kernels > 32); 
                            active[5] <= (i_comp_num_kernels > 40); 
                            active[6] <= (i_comp_num_kernels > 48); 
                            active[7] <= (i_comp_num_kernels > 56); 
                        end else begin
                            num_kernels_per_group <= 64;
                            active <= '1;
                        end
                    end

                    d_cdc_ack <= '0;
                    d1_cdc_ack <= '0;
                end 

                SETUP: begin
                    d_cdc_ack <= i_cdc_ack;
                    d1_cdc_ack <= d_cdc_ack;
                end

                TILE_SETUP: begin 
                    if(curr_tile_x < num_tiles_in_width - 1) begin
                        curr_tile_x <= curr_tile_x + 1;
                    end else begin
                        curr_tile_x <= '0;
                        if(curr_tile_y < num_tiles_in_height - 1) begin
                            curr_tile_y <= curr_tile_y + 1;
                        end else begin 
                            curr_tile_y <= '0;
                            curr_kernel_group <= curr_kernel_group + 1; 
                            curr_drain_waddr <= ((kernels_processed + num_kernels_per_group) >> 3);
                            drain_curr_systolic_array <= '0;

                            kernels_processed <= kernels_processed + num_kernels_per_group; 

                            if((d_comp_num_kernels - (kernels_processed + num_kernels_per_group)) <= 64) begin
                                num_kernels_per_group <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group));
                                active[0] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 0);  
                                active[1] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 8);  
                                active[2] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 16); 
                                active[3] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 24); 
                                active[4] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 32); 
                                active[5] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 40); 
                                active[6] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 48); 
                                active[7] <= (d_comp_num_kernels - (kernels_processed + num_kernels_per_group) > 56); 
                            end else begin
                                num_kernels_per_group <= 64;
                                active <= '1;
                            end
                        end
                    end


                    d_cdc_ack <= '0;
                    d1_cdc_ack <= '0;
                end 

                WAIT_FOR_DRAIN: begin 
                    drain_curr_systolic_array <= '0; 

                    output_pixel_x <= {curr_tile_x, 2'b00};
                    output_pixel_y <= {curr_tile_y, 1'b0};

                    if(!d_comp_maxpool_en) begin
                        curr_drain_waddr <=  ( ({curr_tile_y, 1'b0} * num_tiles_in_width * 4 + {curr_tile_x, 2'b00}) * ((d_comp_num_kernels +7) >> 3) ) + (kernels_processed >> 3);
                    end

                    if(num_kernels_per_group <= 8) begin
                        same_sa_slice_one_cycle_delay <= 1;
                    end else begin
                        same_sa_slice_one_cycle_delay <= 0;
                    end

                    d_cdc_ack <= '0;
                    d1_cdc_ack <= '0;
                end 

                DRAIN: begin
                    if (same_sa_slice_one_cycle_delay) begin
                        // 1. FREEZE ALL POINTERS FOR 1 CYCLE
                        // Clear the flag so we resume normally next cycle
                        same_sa_slice_one_cycle_delay <= 1'b0;
                    end else begin
                        // 2. NORMAL DRAIN OPERATION
                        if(drain_curr_systolic_array < 7 && active[drain_curr_systolic_array + 1]) begin
                            drain_curr_systolic_array <= drain_curr_systolic_array + 1; 
                            curr_drain_waddr <= curr_drain_waddr + 1;
                        end else begin
                            drain_curr_systolic_array <= '0;
                            
                            if(d_comp_maxpool_en) begin
                                curr_drain_waddr <= curr_drain_waddr + ((d_comp_num_kernels - num_kernels_per_group + 7) >> 3) + 1;
                            end else begin
                                curr_drain_waddr <=  ( (next_pixel_y * num_tiles_in_width * 4 + next_pixel_x) * ((d_comp_num_kernels + 7) >> 3) ) + (kernels_processed >> 3);
                            end

                            output_pixel_x <= next_pixel_x;
                            output_pixel_y <= next_pixel_y;
                        end
                    end

                    d_cdc_ack <= '0;
                    d1_cdc_ack <= '0;
                end
            endcase
        end
    end

    always_comb begin
        // Default to current values
        next_pixel_x = output_pixel_x;
        next_pixel_y = output_pixel_y;

        if (output_pixel_x < ({curr_tile_x, 2'b00} + 3)) begin
            next_pixel_x = output_pixel_x + 1;
        end else begin
            next_pixel_x = {curr_tile_x, 2'b00};
            next_pixel_y = output_pixel_y + 1;
        end
    end

    // Combinational block for o_pop_en and drain_wen
    always_comb begin
        o_pop_en = '0;
        drain_wen = '0;

        if(state == DRAIN) begin
            // 1. o_pop_en ALWAYS goes high, even during the stall cycle
            //want to turn it off cause only on for 8 cycles.
            if(num_kernels_per_group <= 8 && next_state != DRAIN) begin
                o_pop_en[drain_curr_systolic_array] = 1'b0;
            end else begin
                o_pop_en[drain_curr_systolic_array] = 1'b1;
            end
            
            drain_wen = 1'b1;
     
        end
    end

endmodule





