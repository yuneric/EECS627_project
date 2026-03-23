module im2col_gen #(
    parameter DIM                = 8,        // systolic array dimension
    parameter NUM_ARRAYS         = 8,        // number of systolic arrays
    parameter DIM_WIDTH          = 10,       // bit-width of dimension fields (Updated to 10 bits)
    parameter MEM_IF_ADDR_WIDTH  = 12,       // activation SRAM address width (Updated to 12 bits)
    parameter WT_ADDR_WIDTH      = 11        // weight SRAM address width (Updated to 11 bits)
)(
    input                          i_clk,
    input                          i_rst_n,

    input  [DIM_WIDTH-1:0]         i_cfg_tile_H,         // input tile height in SRAM
    input  [DIM_WIDTH-1:0]         i_cfg_tile_W,         // input tile width in SRAM
    input  [DIM_WIDTH-1:0]         i_cfg_Hf,             // filter height
    input  [DIM_WIDTH-1:0]         i_cfg_Wf,             // filter width
    input  [1:0]                   i_cfg_stride,         // convolution stride
    input  [1:0]                   i_cfg_padding,        // zero padding amount
    input  [DIM_WIDTH-1:0]         i_cfg_words_ci,       // ceil(Ci / values_per_word)
    input  [DIM_WIDTH-1:0]         i_cfg_curr_kernel_group, // the current kernel group that we are on
    input  [7:0]                   i_cfg_num_kernels_per_group, // kernels in this group (max 64)

    input  [DIM_WIDTH-1:0]         i_cfg_sub_tile_x,     // output col / 4
    input  [DIM_WIDTH-1:0]         i_cfg_sub_tile_y,     // output row / 2

    input  [1:0]                   i_cfg_x_bound,
    input                          i_cfg_y_bound,

    input                          i_im2col_start,              // pulse high 1 cycle to begin
    input                          i_fifo_full,

    output reg [MEM_IF_ADDR_WIDTH-1:0] o_act_addr,           // activation SRAM read address
    output reg                         o_act_valid,          // address is in-bounds (else zero-pad)
    output reg [WT_ADDR_WIDTH-1:0]     o_wt_addr,            // weight SRAM read address
    output reg [NUM_ARRAYS-1:0]        o_wt_valid,           // kernel index valid (else zero-pad)
    output reg                         o_push_en,            // push data into the fifo + read sram signal

    output reg                        o_im2col_done         // goes high on the cycle after data_last asserts
);

    ////////////////////////////////////////////
    // Some epic declarations and boilerplate //
    ////////////////////////////////////////////

    logic  [DIM_WIDTH-1:0]         cfg_tile_H               ;
    logic  [DIM_WIDTH-1:0]         cfg_tile_W               ;
    logic  [DIM_WIDTH-1:0]         cfg_Hf                   ;
    logic  [DIM_WIDTH-1:0]         cfg_Wf                   ;
    logic  [1:0]                   cfg_stride               ;
    logic  [1:0]                   cfg_padding              ;
    logic  [DIM_WIDTH-1:0]         cfg_words_ci             ;
    logic  [DIM_WIDTH-1:0]         cfg_curr_kernel_group    ;
    logic  [7:0]                   cfg_num_kernels_per_group;
    logic  [DIM_WIDTH-1:0]         cfg_sub_tile_x           ;
    logic  [DIM_WIDTH-1:0]         cfg_sub_tile_y           ;
    logic  [1:0]                   cfg_x_bound              ;
    logic                          cfg_y_bound              ;

    always_ff @(posedge i_clk) begin
        cfg_tile_H                  <= i_cfg_tile_H               ;
        cfg_tile_W                  <= i_cfg_tile_W               ;
        cfg_Hf                      <= i_cfg_Hf                   ;
        cfg_Wf                      <= i_cfg_Wf                   ;
        cfg_stride                  <= i_cfg_stride               ;
        cfg_padding                 <= i_cfg_padding              ;
        cfg_words_ci                <= i_cfg_words_ci             ;
        cfg_curr_kernel_group       <= i_cfg_curr_kernel_group    ;
        cfg_num_kernels_per_group   <= i_cfg_num_kernels_per_group;
        cfg_sub_tile_x              <= i_cfg_sub_tile_x           ;
        cfg_sub_tile_y              <= i_cfg_sub_tile_y           ;
        cfg_x_bound                 <= i_cfg_x_bound              ;
        cfg_y_bound                 <= i_cfg_y_bound              ;


    end
    //the word offset for the group of channels we are on
    logic [DIM_WIDTH-1:0]         word_idx;

    //kernel weight x coordinate
    logic [DIM_WIDTH-1:0]         wgt_pix_x;
    //kernel weight y coordinate
    logic [DIM_WIDTH-1:0]         wgt_pix_y;

    // The row in the systolic array that we are writing to
    logic [3:0]                   sa_row_idx;

    //the number of words in our lowered im2col featured maps aka. num data we need to push into the fifos
    reg  [31:0] total_feed;
    reg  [31:0] feed_cnt;
    wire        is_last;

    // The x and y of the output pixel in the tile we are working (all tiles are 2x4 here im2col doesn't care about maxpooling)
    wire [1:0] out_px;     // 0..3 horizontal
    wire       out_py;     // 0..1 vertical

    // The 'real' x and y of the output pixel we are writing to in the full output matrix
    wire [DIM_WIDTH+1:0] abs_out_x;
    wire [DIM_WIDTH:0]   abs_out_y;

    // Input pixel x and y in the activation image
    wire signed [DIM_WIDTH+3:0] in_px_s;
    wire signed [DIM_WIDTH+3:0] in_py_s;

    // Is the input pixel that we are currently reading in the bounds of the image?
    wire in_bounds;
    // Is the output pixel that we are writing to in the bounds of our output matrix/current tile?
    wire out_in_tile ;
    // Valid if both of the above are true (if 0, push data is 0's for the systolic array)
    wire mem_act_valid;
    // valid bit for each systolic array (if 0, push data is 0's for the systolic array)
    wire [NUM_ARRAYS-1:0] mem_wt_valid;

    // Sram address for the activation word we want
    wire [MEM_IF_ADDR_WIDTH-1:0] mem_act_addr;
    // Sram address for the weight word we want
    wire [WT_ADDR_WIDTH-1:0] kernel_base_addr;
    wire [WT_ADDR_WIDTH-1:0] kernel_offset;
    wire [WT_ADDR_WIDTH-1:0] kernel_pix_offset;
    wire [WT_ADDR_WIDTH-1:0] mem_wt_addr;

    // The size of a kernel in mem
    wire [WT_ADDR_WIDTH-1:0] kernel_size;

    //states
    typedef enum logic [1:0] {IDLE, FIFO_STALL, FEED} state_t;
    state_t state, state_nxt;

    // Output regs
    always_ff @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            o_act_addr    <= '0;
            o_act_valid   <= '0;
            o_wt_addr     <= '0;
            o_wt_valid    <= '0;
            o_push_en     <= '0;
            o_im2col_done <= '0;
        end else begin
            o_act_addr    <= mem_act_addr;
            o_act_valid   <= mem_act_valid;
            o_wt_addr     <= mem_wt_addr;
            o_wt_valid    <= mem_wt_valid;
            o_push_en     <= state == FEED;
            o_im2col_done <= is_last;
        end
    end

    ///////////////////////
    // Lets do some math //
    ///////////////////////

    assign is_last = (feed_cnt == total_feed - 1) && (total_feed != 0);

    // top_left_output_pixel_x = tile_h*4
    // top_left_output_pixel_y = tile_v*2
    // output_pixel_x += 1
    // if(output_pixel_x > 3):
    //     output_pixel_x = 0
    //     output_pixel_y += 1
    //so the 2nd most significant bit gives height and the last two bits give row -> this is checking the boundary
    assign out_px = sa_row_idx[1:0];     // 0..3 horizontal
    assign out_py = sa_row_idx[2];       // 0..1 vertical

    //I'm assuming this is absolute output x, y
    //feeding in config sub tile x + out_px - I think this is doing the tile_h * 4 and tile_v * 2
    //feeding in config sub tile y + out_py
    assign abs_out_x = ({cfg_sub_tile_x, 2'b00}) + {{DIM_WIDTH{1'b0}}, out_px};
    assign abs_out_y = ({cfg_sub_tile_y, 1'b0})  + {{DIM_WIDTH{1'b0}}, out_py};

    // top_left_input_pixel_x = top_left_output_pixel_x * stride
    // top_left_input_pixel_y = top_left_output_pixel_y * stride
    assign in_px_s = $signed({{2{1'b0}}, abs_out_x}) * $signed({{DIM_WIDTH+4-DIM_WIDTH{1'b0}}, cfg_stride})
                   + $signed({{DIM_WIDTH+4-DIM_WIDTH{1'b0}}, wgt_pix_x})
                   - $signed({{DIM_WIDTH+4-DIM_WIDTH{1'b0}}, cfg_padding});

    assign in_py_s = $signed({{3{1'b0}}, abs_out_y}) * $signed({{DIM_WIDTH+4-DIM_WIDTH{1'b0}}, cfg_stride})
                   + $signed({{DIM_WIDTH+4-DIM_WIDTH{1'b0}}, wgt_pix_y})
                   - $signed({{DIM_WIDTH+4-DIM_WIDTH{1'b0}}, cfg_padding});

    // x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
    // y_bound = min(Ho - top_left_output_pixel_y - 1, 1)
    // valid_in = (0 <= input_pixel_x < Wi) and (0 <= input_pixel_y < Hi)
    assign in_bounds = (in_px_s >= 0) && (in_px_s < $signed({{4{1'b0}}, cfg_tile_W}))
                  && (in_py_s >= 0) && (in_py_s < $signed({{4{1'b0}}, cfg_tile_H}));

    // valid_out = not (output_pixel_x > x_bound or output_pixel_y > y_bound)
    assign out_in_tile = (out_px <= i_cfg_x_bound) && (out_py <= i_cfg_y_bound);

    // if(valid_out and valid_in)
    assign mem_act_valid = in_bounds && out_in_tile;

    // mem_address = (input_pixel_x + input_pixel_y*Wi) * words_needed_for_Ci + word_idx

    assign mem_act_addr = (in_py_s[DIM_WIDTH-1:0] * cfg_tile_W
                          + in_px_s[DIM_WIDTH-1:0]) * cfg_words_ci
                          + word_idx;


    // num_rows_per_kernel = Hf * Wf * words_needed_for_Ci
    //  for array in range(num_arrays):
            // kernel_num = row + (dim * array) + (dim * num_arrays) * kernel_group
            // valid_weight = kernel_num < Co
            // weight_mem_address = ((weight_pixel_x + weight_pixel_y*Wf) * words_needed_for_Ci) + word_idx + (kernel_num * num_rows_per_kernel)
    
            // # Check if the valid kernel and get the chunk of weights
            // if valid_weight:
            //     new_weights = weight_mem[weight_mem_address]
            // else:
            //     new_weights = np.zeros(word_size)

            // # Load into our lowered weight matrix for later
            // col = row
            // lowered_weight[array][kernel_group][tile_idx][lowered_weight_row][col] = new_weights

    // weight_mem_address = ((weight_pixel_x + weight_pixel_y*Wf) * words_needed_for_Ci) + word_idx + (kernel_num * num_rows_per_kernel)

    assign kernel_size = cfg_Hf * cfg_Wf * cfg_words_ci;
    // Base of the 8 kernels for this array
    assign kernel_base_addr  =  DIM * kernel_size * cfg_curr_kernel_group;
    // Which kernel we are picking from the 8
    assign kernel_offset     = sa_row_idx * kernel_size;
    // Which pixel within the kernel we are accessing
    assign kernel_pix_offset = (wgt_pix_y * cfg_Wf + wgt_pix_x) * cfg_words_ci + word_idx;
    // The final address
    assign mem_wt_addr       = kernel_base_addr + kernel_offset + kernel_pix_offset;

    // valid_weight = kernel_num < Co
    genvar i;
    for(i = 0; i < DIM; i = i + 1) begin
        assign mem_wt_valid[i] = ({{4{1'b0}}, sa_row_idx} + i * DIM) < cfg_num_kernels_per_group;
    end

    ////////////////
    // im2col fsm //
    ////////////////

    always @(posedge i_clk or negedge i_rst_n) begin
        if(!i_rst_n) begin
            state <= IDLE;
        end else begin
            state <= state_nxt;
        end
    end

    always @(*) begin
        state_nxt = state;
        case (state)
            // Idle or done
            IDLE:       if(i_im2col_start) state_nxt = FEED;

            // Need to wait until there is more room in the fifo
            FIFO_STALL: if(!i_fifo_full)   state_nxt = FEED;

            // Actively providing data to the systolic array
            FEED: begin
                if(is_last) begin
                    state_nxt = IDLE;
                end else if(i_fifo_full) begin
                    state_nxt = FIFO_STALL;
                end
            end
            default: state_nxt = IDLE;
        endcase
    end

    ///////////////
    // for loops //
    ///////////////

    // For loop incrementers like in the python script
    // for word_idx in range(words_needed_for_Ci):
    //                 for weight_pixel_y in range(Hf):
    //                     for  weight_pixel_x in range(Wf):
    //                         for row in range(dim):
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            wgt_pix_x   <= 0;
            wgt_pix_y   <= 0;
            sa_row_idx  <= 0;
            word_idx    <= 0;
            total_feed  <= 0;
            feed_cnt    <= 0;
        end else begin
            case(state)
                IDLE: begin
                    wgt_pix_x   <= 0;
                    wgt_pix_y   <= 0;
                    sa_row_idx  <= 0;
                    word_idx    <= 0;
                    //the number of words in our lowered im2col featured maps (words_for_channels * Hf * Wf * dim )
                    total_feed  <= cfg_words_ci * cfg_Hf * cfg_Wf * DIM;
                    feed_cnt    <= 0;
                end
                FEED: begin
                    feed_cnt <= feed_cnt + 1;

                    if (sa_row_idx < DIM - 1) begin
                        sa_row_idx <= sa_row_idx + 1;
                    end else begin
                        sa_row_idx <= 0;
                        if (wgt_pix_x < cfg_Wf - 1) begin
                            wgt_pix_x <= wgt_pix_x + 1;
                        end else begin
                            wgt_pix_x <= 0;
                            if (wgt_pix_y < cfg_Hf - 1) begin
                                wgt_pix_y <= wgt_pix_y + 1;
                            end else begin
                                wgt_pix_y <= 0;
                                word_idx <= word_idx + 1;
                            end
                        end
                    end
                end
            endcase
        end
    end


endmodule