module computation_overseer #(
    parameter DIM                = 8,
    parameter NUM_ARRAYS         = 8,
    parameter DIM_WIDTH          = 10,
    parameter MEM_IF_ADDR_WIDTH  = 12,
    parameter WT_ADDR_WIDTH      = 11,
    parameter WORD_SIZE          = 64
)(
    input  wire                                  i_clk,
    input  wire                                  i_rst_n,

    input logic                  i_comp_compute_start    ,
    input logic [1:0]            i_comp_stride           ,
    input logic [1:0]            i_comp_padding          ,
    input logic                  i_comp_maxpool_en       ,
    input logic                  i_comp_relu_en          ,
    input logic [4:0]            i_comp_scale_amt        ,
    input logic [DIM_WIDTH-1:0]  i_comp_Hi               ,
    input logic [DIM_WIDTH-1:0]  i_comp_Wi               ,
    input logic [DIM_WIDTH-1:0]  i_comp_Hf               ,
    input logic [DIM_WIDTH-1:0]  i_comp_Wf               ,
    input logic [DIM_WIDTH-1:0]  i_comp_Ho               ,
    input logic [DIM_WIDTH-1:0]  i_comp_Wo               ,
    input logic [DIM_WIDTH-1:0]  i_comp_words_per_channel,
    input logic [DIM_WIDTH-1:0]  i_comp_num_kernels      ,
    output                       o_comp_done             ,

    // config from controller
    // input  wire                                  i_start,
    // input  wire [DIM_FIELD_WIDTH-1:0]            i_cfg_tile_H, i_cfg_tile_W,
    // input  wire [DIM_FIELD_WIDTH-1:0]            i_cfg_Hf, i_cfg_Wf,
    // input  wire [DIM_FIELD_WIDTH-1:0]            i_cfg_stride, i_cfg_padding,
    // input  wire [WORD_IDX_WIDTH-1:0]             i_cfg_words_ci,
    // input  wire [DIM_FIELD_WIDTH-1:0]            i_cfg_Co, i_cfg_Ho, i_cfg_Wo,
    // input  wire                                  i_cfg_relu_en, i_cfg_maxpool_en,

    // activation SRAM (shared read port)
    output reg  [ACT_ADDR_WIDTH-1:0]             o_act_rd_addr,
    output reg                                   o_act_rd_en,
    input  wire [DATA_WIDTH-1:0]                 i_act_rd_data,

    // weight SRAMs (one port per array)
    output reg  [WT_ADDR_WIDTH*NUM_ARRAYS-1:0]   o_wt_rd_addr,
    output reg  [NUM_ARRAYS-1:0]                 o_wt_rd_en,
    input  wire [DATA_WIDTH*NUM_ARRAYS-1:0]      i_wt_rd_data,

    // SA FIFO writes
    output reg  [NUM_ARRAYS-1:0]                 o_sa_wr_en,
    output reg  [DATA_WIDTH-1:0]                 o_sa_wr_act_data,
    output reg  [DATA_WIDTH*NUM_ARRAYS-1:0]      o_sa_wr_wt_data,
    output reg  [NUM_ARRAYS-1:0]                 o_sa_wr_data_last,
    input  wire [NUM_ARRAYS-1:0]                 i_sa_fifo_full,

    // SA outputs
    input  wire [NUM_ARRAYS-1:0]                 i_sa_valid_out,
    input  wire [DATA_WIDTH*NUM_ARRAYS-1:0]      i_sa_data_out,
    input  wire [NUM_ARRAYS-1:0]                 i_sa_flush_done,

    // output SRAM
    output reg  [OUT_ADDR_WIDTH-1:0]             o_out_wr_addr,
    output reg                                   o_out_wr_en,
    output reg  [DATA_WIDTH-1:0]                 o_out_wr_data,

    // misc
    output wire [NUM_ARRAYS-1:0]                 o_array_active,
    output wire                                  o_busy,
    //output wire                                  o_done
);

    // FSM
    localparam [3:0]
        IDLE       = 0, CONFIG     = 1, ST_SETUP  = 2, KG_SETUP  = 3,
        FEED_ADDR  = 4, FEED_WRITE = 5, DRAIN     = 6, OUTPUT_WB = 7,
        KG_NEXT    = 8, ST_NEXT    = 9;

    reg [3:0] state, nxt;

    // Latched in i_start inputs (num_st == num_subtile)
    reg [DIM_FIELD_WIDTH-1:0] d_Ho, d_Wo, d_Co;
    reg [DIM_FIELD_WIDTH-1:0] num_stx, num_sty, num_kg;
    reg                       d_relu, d_maxpool;

    reg [DIM_FIELD_WIDTH-1:0] st_x, st_y, kg_idx;
    // x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
    // y_bound = min(Ho - top_left_output_pixel_y - 1, 1)
    reg [1:0]                 x_bound; 
    reg                       y_bound; 

    // Indicates the active arrays 
    reg [NUM_ARRAYS-1:0] active;
    assign o_array_active = active;

    wire fifo_stall = |(i_sa_fifo_full & active);

    reg                    p_act_valid;
    reg [NUM_ARRAYS-1:0]  p_kern_valid;
    reg                    p_last;

    reg [DATA_WIDTH-1:0]   obuf [0:NUM_ARRAYS-1][0:DIM-1];
    reg [3:0]              cap_cnt [0:NUM_ARRAYS-1];
    reg [NUM_ARRAYS-1:0]   cap_done;
    reg [3:0]              wb_pix, wb_arr;

    //why no assign statements here
    wire [DIM_FIELD_WIDTH-1:0] co_remaining = d_Co - kg_idx * NUM_ARRAYS;
    wire [3:0] n_active_m1 = (co_remaining >= NUM_ARRAYS) ? (NUM_ARRAYS - 1) : co_remaining[3:0] - 1;

    wire ic_start, ic_advance;
    wire [ACT_ADDR_WIDTH-1:0] ic_act_addr;
    wire                      ic_act_valid;
    wire [WT_ADDR_WIDTH-1:0]  ic_wt_addr;
    wire                      ic_wt_valid;
    wire                      ic_data_last, ic_addr_valid, ic_busy, ic_done;

    wire [WT_ADDR_WIDTH-1:0] ksz = i_cfg_Hf * i_cfg_Wf * i_cfg_words_ci;
    reg  [WT_ADDR_WIDTH-1:0] kg_wt_off;

    // Handles all of the address gen for one tile of the output (one systolic array drain)
    im2col_gen #(
        .DIM(DIM), .DIM_FIELD_WIDTH(DIM_FIELD_WIDTH),
        .ACT_ADDR_WIDTH(ACT_ADDR_WIDTH), .WT_ADDR_WIDTH(WT_ADDR_WIDTH),
        .WORD_IDX_WIDTH(WORD_IDX_WIDTH)
    ) u_im2col (
        .i_clk(i_clk), .i_rst_n(i_rst_n),
        .i_cfg_tile_H(i_cfg_tile_H), .i_cfg_tile_W(i_cfg_tile_W),
        .i_cfg_Hf(i_cfg_Hf), .i_cfg_Wf(i_cfg_Wf),
        .i_cfg_stride(i_cfg_stride), .i_cfg_padding(i_cfg_padding),
        .i_cfg_words_ci(i_cfg_words_ci), .i_cfg_Co(i_cfg_Co),
        .i_cfg_sub_tile_x(st_x), .i_cfg_sub_tile_y(st_y),
        .i_cfg_x_bound(x_bound), .i_cfg_y_bound(y_bound),
        .i_start(ic_start), .i_advance(ic_advance),
        .o_act_addr(ic_act_addr), .o_act_valid(ic_act_valid),
        .o_wt_addr(ic_wt_addr), .o_wt_valid(ic_wt_valid),
        .o_data_last(ic_data_last), .o_addr_valid(ic_addr_valid),
        .o_busy(ic_busy), .o_done(ic_done)
    );

    assign ic_start   = (state == KG_SETUP);
    assign ic_advance = (state == FEED_WRITE) && !fifo_stall;

    always @(*) begin
        nxt = state;
        case (state)
            IDLE:       if (i_start) nxt = CONFIG;
            CONFIG:     nxt = ST_SETUP;
            ST_SETUP:   nxt = KG_SETUP;
            KG_SETUP:   nxt = FEED_ADDR;
            FEED_ADDR:  if (ic_addr_valid) nxt = FEED_WRITE;
            FEED_WRITE: begin
                if (fifo_stall)        nxt = FEED_WRITE;
                else if (p_last)       nxt = DRAIN;
                else                   nxt = FEED_ADDR;
            end
            DRAIN:      if ((i_sa_flush_done & active) == active) nxt = OUTPUT_WB;
            OUTPUT_WB:  if (wb_pix == DIM-1 && wb_arr == n_active_m1) nxt = KG_NEXT;
            KG_NEXT:    nxt = (kg_idx == num_kg - 1) ? ST_NEXT : KG_SETUP;
            ST_NEXT: begin
                if (st_x == num_stx - 1 && st_y == num_sty - 1) nxt = IDLE;
                else nxt = ST_SETUP;
            end
            default:    nxt = IDLE;
        endcase
    end

    always @(posedge i_clk or negedge i_rst_n)
        if (!i_rst_n) state <= IDLE;
        else        state <= nxt;

    // Latch in inputs upon a i_start
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            d_Ho <= 0; d_Wo <= 0; d_Co <= 0;
            num_stx <= 0; num_sty <= 0; num_kg <= 0;
            d_relu <= 0; d_maxpool <= 0;
        end else if (state == IDLE && i_start) begin
            d_Ho    <= i_cfg_Ho;
            d_Wo    <= i_cfg_Wo;
            d_Co    <= i_cfg_Co;
            d_relu  <= i_cfg_relu_en;
            d_maxpool <= i_cfg_maxpool_en;
            // tiles_in_width = math.ceil(Wo/4) # how many tiles are in the output width-wise
            num_stx <= (i_cfg_Wo + 3) >> 2;
            // tiles_in_height = math.ceil(Ho/2) # how many tiles are in the output height-wise
            num_sty <= (i_cfg_Ho + 1) >> 1;
            // kernel_groups = math.ceil(Co/(dim*num_arrays)) # how many kernel groups we have to iterate through
            num_kg  <= (i_cfg_Co + NUM_ARRAYS - 1) / NUM_ARRAYS;
        end
    end

    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            st_x <= 0; st_y <= 0; kg_idx <= 0;
        end else case (state)
            CONFIG:   begin st_x <= 0; st_y <= 0; kg_idx <= 0; end
            ST_SETUP: kg_idx <= 0;
            KG_SETUP: kg_wt_off <= kg_idx * ksz;
            ST_NEXT: begin
                if (st_x < num_stx - 1)
                    st_x <= st_x + 1;
                else begin
                    st_x <= 0;
                    st_y <= st_y + 1;
                end
            end
            KG_NEXT: kg_idx <= kg_idx + 1;
            default: ;
        endcase
    end

    // x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
    // y_bound = min(Ho - top_left_output_pixel_y - 1, 1)
    always @(posedge i_clk) begin
        if (state == CONFIG || state == ST_SETUP) begin
            x_bound <= ((d_Wo - {st_x, 2'b00}) > 4) ? 2'd3
                     : d_Wo - {st_x, 2'b00} - 1;
            y_bound <= ((d_Ho - {st_y, 1'b0}) >= 2) ? 1'b1 : 1'b0;
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
    wire [DIM_FIELD_WIDTH+1:0] abs_x = {st_x, 2'b00} + {{DIM_FIELD_WIDTH{1'b0}}, wb_px};
    wire [DIM_FIELD_WIDTH:0]   abs_y = {st_y, 1'b0}   + {{DIM_FIELD_WIDTH{1'b0}}, wb_py};

    wire [OUT_ADDR_WIDTH-1:0] wb_addr =
        (abs_y * d_Wo + abs_x) * d_Co + kg_idx * NUM_ARRAYS + wb_arr;

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
    assign o_done = (state == ST_NEXT) && (st_x == num_stx-1) && (st_y == num_sty-1);

endmodule