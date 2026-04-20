`timescale 1 ns / 1 ps

module net_large_tb;

    parameter NUM_ARRAYS            = 8;
    parameter CPU_ADDR_WIDTH        = 32;
    parameter CPU_DATA_WIDTH        = 32;
    parameter NPU_ACT_ADDR_WIDTH    = 12;
    parameter NPU_WT_ADDR_WIDTH     = 11;
    parameter NPU_DATA_WIDTH        = 64;
    parameter DIM_WIDTH             = 10;
    parameter PRINT_ADDR            = 32'h1000_0000;
    parameter MMIO_ADDR             = 32'h1000_1000;
    parameter MMIO_SIZE             = 32'h0000_0100;
    parameter FMAP_ADDR             = 32'h2000_0000;
    parameter WGT_ADDR              = 32'h2100_0000;

    parameter PSUM_WIDTH        = 32;
    parameter SHIFT_WIDTH       = 5;
    parameter INPUT_FIFO_DEPTH  = 32; 
    parameter INPUT_FIFO_AF_LVL = 5; // needs 4 pushes of headsup
    parameter OUTPUT_FIFO_DEPTH = 8; 

    //Clock & Reset
    // logic clk_sys, clk_sa;
    logic clk_sys;
    initial clk_sys = 0;
    always #`CLK_PERIOD_SYS_HALF clk_sys = ~clk_sys;

    // initial clk_sa = 0;
    // always #`CLK_PERIOD_SA_HALF clk_sa = ~clk_sa;

    logic rstn_sync;
    logic rstn_async;

    //memory size
    localparam int MEM_SIZE_BYTES = 1 * 1024 * 1024; // 1MB
    localparam int MEM_WORDS      = MEM_SIZE_BYTES / 4;
    //define memory seperately for ease of testing
    logic [31:0] prgm_memory [0:MEM_WORDS-1];   // Contains addresses between 0x0000_0000-0x000f_ffff
    logic [31:0] fmap_memory [0:MEM_WORDS-1];       // Contains the fmap mem 0x2000_0000-0x200f_ffff
    logic [31:0] fmap_memory_clean [0:MEM_WORDS-1]; // Contains the clean fmap mem 0x2000_0000-0x200f_ffff
    logic [31:0] wgt_memory  [0:MEM_WORDS-1];       // Contains the wgt mem 0x2100_0000-0x210f_ffff

    //trace signals
    wire trap, trace_valid;
    wire [35:0] trace_data;

    // Off chip memory interface
    logic                      mem_valid;
    logic                      mem_ready;
    logic [CPU_ADDR_WIDTH-1:0] mem_addr;
    logic [CPU_DATA_WIDTH-1:0] mem_wdata;
    logic [3:0]                mem_wstrb;
    logic [CPU_DATA_WIDTH-1:0] mem_rdata;

    // =========================================================================
    // Internal Signals: SA Slice Control (Top 4 Arrays)
    // =========================================================================
    logic [2:0]                     top_clk_sel;
    logic                           top_cdc_req;
    logic [(NUM_ARRAYS/2)-1:0]      top_cdc_ack_arrays;
    logic                           top_relu_en;
    logic [SHIFT_WIDTH-1:0]         top_shift_by;
    logic                           top_maxpool_en;

    logic [NPU_DATA_WIDTH-1:0]      top_push_act_data;
    logic                           top_push_data_last;
    logic [(NUM_ARRAYS/2)-1:0]      top_push_en;
    logic [(NUM_ARRAYS/2)-1:0]      top_push_af;

    logic [NPU_WT_ADDR_WIDTH-1:0]   top_wt_rd_addr;
    logic [(NUM_ARRAYS/2)-1:0]      top_wt_rd_en;
    logic [NPU_WT_ADDR_WIDTH-1:0]   top_wt_wr_addr;
    logic [(NUM_ARRAYS/2)-1:0]      top_wt_wr_en; 
    logic [NPU_DATA_WIDTH-1:0]      top_wt_wr_data;

    logic [NPU_DATA_WIDTH-1:0]      top_pop_data_arr [(NUM_ARRAYS/2)-1:0];
    logic [NPU_DATA_WIDTH-1:0]      top_pop_data_mux;
    logic [(NUM_ARRAYS/2)-1:0]      top_pop_en;
    logic [(NUM_ARRAYS/2)-1:0]      top_pop_ae;
    logic [(NUM_ARRAYS/2)-1:0]      top_pop_full;

    // =========================================================================
    // Internal Signals: SA Slice Control (Bottom 4 Arrays)
    // =========================================================================
    logic [2:0]                     bottom_clk_sel;
    logic                           bottom_cdc_req;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_cdc_ack_arrays;
    logic                           bottom_relu_en;
    logic [SHIFT_WIDTH-1:0]         bottom_shift_by;
    logic                           bottom_maxpool_en;

    logic [NPU_DATA_WIDTH-1:0]      bottom_push_act_data;
    logic                           bottom_push_data_last;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_push_en;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_push_af;

    logic [NPU_WT_ADDR_WIDTH-1:0]   bottom_wt_rd_addr;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_wt_rd_en;
    logic [NPU_WT_ADDR_WIDTH-1:0]   bottom_wt_wr_addr;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_wt_wr_en; 
    logic [NPU_DATA_WIDTH-1:0]      bottom_wt_wr_data;

    logic [NPU_DATA_WIDTH-1:0]      bottom_pop_data_arr [(NUM_ARRAYS/2)-1:0];
    logic [NPU_DATA_WIDTH-1:0]      bottom_pop_data_mux;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_pop_en;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_pop_ae;
    logic [(NUM_ARRAYS/2)-1:0]      bottom_pop_full;


    // Banked on chip mem interface
    logic                           b0_s0_cen   ;
    logic                           b0_s0_wen   ;
    logic [NPU_DATA_WIDTH-1:0]      b0_s0_rdata ;
    logic [NPU_ACT_ADDR_WIDTH-1:0]  b0_s0_addr  ;
    logic [NPU_DATA_WIDTH-1:0]      b0_s0_wdata ;

    logic                           b0_s1_cen   ;
    logic                           b0_s1_wen   ;
    logic  [NPU_DATA_WIDTH-1:0]     b0_s1_rdata ;
    logic  [NPU_ACT_ADDR_WIDTH-1:0] b0_s1_addr  ;
    logic  [NPU_DATA_WIDTH-1:0]     b0_s1_wdata ;

    logic                           b1_s0_cen   ;
    logic                           b1_s0_wen   ;
    logic  [NPU_DATA_WIDTH-1:0]     b1_s0_rdata ;
    logic  [NPU_ACT_ADDR_WIDTH-1:0] b1_s0_addr  ;
    logic  [NPU_DATA_WIDTH-1:0]     b1_s0_wdata ;

    logic                           b1_s1_cen   ;
    logic                           b1_s1_wen   ;
    logic  [NPU_DATA_WIDTH-1:0]     b1_s1_rdata ;
    logic  [NPU_ACT_ADDR_WIDTH-1:0] b1_s1_addr  ;
    logic  [NPU_DATA_WIDTH-1:0]     b1_s1_wdata ;


    // Mux pop data for NPU based on pop enables
    always_comb begin
        top_pop_data_mux = top_pop_data_arr[0];
        for(int array_i = 1; array_i < NUM_ARRAYS/2; array_i += 1) begin
            if(top_pop_en[array_i]) top_pop_data_mux = top_pop_data_arr[array_i];
        end

        bottom_pop_data_mux = bottom_pop_data_arr[0];
        for(int array_i = 1; array_i < NUM_ARRAYS/2; array_i += 1) begin
            if(bottom_pop_en[array_i]) bottom_pop_data_mux = bottom_pop_data_arr[array_i];
        end
    end

// =========================================================================
// Dunkin Donuts Core Instantiation
// =========================================================================
dunkin_donuts #(
    .CPU_ADDR_WIDTH    (CPU_ADDR_WIDTH),
    .CPU_DATA_WIDTH    (CPU_DATA_WIDTH),
    .NPU_ACT_ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
    .NPU_WT_ADDR_WIDTH (NPU_WT_ADDR_WIDTH),
    .NPU_DATA_WIDTH    (NPU_DATA_WIDTH),
    .DIM_WIDTH         (DIM_WIDTH),
    .MMIO_ADDR         (MMIO_ADDR),
    .MMIO_SIZE         (MMIO_SIZE)
) dut_dunkin (
    
    .i_clk       (clk_sys),
    .i_rstn_sync (rstn_sync),
    .i_rstn_async(rstn_async),

    // Cpu trace signals
    .o_trap       (trap), 
    .o_trace_valid(trace_valid),
    .o_trace_data (trace_data),

    // Axi Arbiter to off chip memory
    .o_mem_valid(mem_valid),
    .i_mem_ready(mem_ready),
    .o_mem_addr (mem_addr ),
    .o_mem_wdata(mem_wdata),
    .o_mem_wstrb(mem_wstrb),
    .i_mem_rdata(mem_rdata),

    // ACT/OUTPUT SRAM interface
    .o_b0_s0_cen  (b0_s0_cen   ),
    .o_b0_s0_wen  (b0_s0_wen   ),
    .i_b0_s0_rdata(b0_s0_rdata ),
    .o_b0_s0_addr (b0_s0_addr  ),
    .o_b0_s0_wdata(b0_s0_wdata ),

    .o_b0_s1_cen  (b0_s1_cen   ),
    .o_b0_s1_wen  (b0_s1_wen   ),
    .i_b0_s1_rdata(b0_s1_rdata ),
    .o_b0_s1_addr (b0_s1_addr  ),
    .o_b0_s1_wdata(b0_s1_wdata ),

    .o_b1_s0_cen  (b1_s0_cen   ),
    .o_b1_s0_wen  (b1_s0_wen   ),
    .i_b1_s0_rdata(b1_s0_rdata ),
    .o_b1_s0_addr (b1_s0_addr  ),
    .o_b1_s0_wdata(b1_s0_wdata ),

    .o_b1_s1_cen  (b1_s1_cen   ),
    .o_b1_s1_wen  (b1_s1_wen   ),
    .i_b1_s1_rdata(b1_s1_rdata ),
    .o_b1_s1_addr (b1_s1_addr  ),
    .o_b1_s1_wdata(b1_s1_wdata ),

    // Systolic array ports (Top)
    .o_top_clk_sel              (top_clk_sel),
    .o_top_cdc_req              (top_cdc_req),
    .i_top_cdc_ack              (top_cdc_ack_arrays),
    .o_top_relu_en              (top_relu_en),
    .o_top_shift_by             (top_shift_by),
    .o_top_maxpool_en           (top_maxpool_en),

    .o_top_push_act_data        (top_push_act_data),
    .o_top_push_data_last       (top_push_data_last),
    .o_top_push_en              (top_push_en),
    .i_top_push_af              (top_push_af),

    .o_top_wt_sram_rd_addr      (top_wt_rd_addr), 
    .o_top_wt_sram_rd_en        (top_wt_rd_en), 
    .o_top_wt_mem_wr_addr       (top_wt_wr_addr), 
    .o_top_wt_mem_wr_data       (top_wt_wr_data), 
    .o_top_wt_mem_wr_en         (top_wt_wr_en),
   
    .i_top_pop_data             (top_pop_data_mux),
    .o_top_pop_en               (top_pop_en),
    .i_top_pop_ae               (top_pop_ae),
    .i_top_pop_full             (top_pop_full),

    // Systolic array ports (Bottom)
    .o_bottom_clk_sel           (bottom_clk_sel),
    .o_bottom_cdc_req           (bottom_cdc_req),
    .i_bottom_cdc_ack           (bottom_cdc_ack_arrays),
    .o_bottom_relu_en           (bottom_relu_en),
    .o_bottom_shift_by          (bottom_shift_by),
    .o_bottom_maxpool_en        (bottom_maxpool_en),

    .o_bottom_push_act_data     (bottom_push_act_data),
    .o_bottom_push_data_last    (bottom_push_data_last),
    .o_bottom_push_en           (bottom_push_en),
    .i_bottom_push_af           (bottom_push_af),

    .o_bottom_wt_sram_rd_addr   (bottom_wt_rd_addr), 
    .o_bottom_wt_sram_rd_en     (bottom_wt_rd_en), 
    .o_bottom_wt_mem_wr_addr    (bottom_wt_wr_addr), 
    .o_bottom_wt_mem_wr_data    (bottom_wt_wr_data), 
    .o_bottom_wt_mem_wr_en      (bottom_wt_wr_en),
   
    .i_bottom_pop_data          (bottom_pop_data_mux),
    .o_bottom_pop_en            (bottom_pop_en),
    .i_bottom_pop_ae            (bottom_pop_ae),
    .i_bottom_pop_full          (bottom_pop_full)

);    

    // =========================================================================
    // Module: Top Half Systolic Arrays (Daisy Chained)
    // =========================================================================
    genvar top_i;
    generate
        // Step by 2: Index 'top_i' is Inner, 'top_i + 1' is Outer
        for (top_i = 0; top_i < NUM_ARRAYS/2; top_i = top_i + 2) begin : TOP_SYSTOLIC_ARRAYS
            localparam INNER = top_i;
            localparam OUTER = top_i + 1;

            // Intermediate wires between Inner (sa_slice_thru) and Outer (sa_slice)
            logic                     thru_rst_n;
            logic [2:0]               thru_clk_sel;
            logic                     thru_cdc_req;
            logic                     thru_cdc_ack;
            logic                     thru_relu_en;
            logic [SHIFT_WIDTH-1:0]   thru_shift_by;
            logic                     thru_maxpool_en;

            logic [NPU_DATA_WIDTH-1:0] thru_push_act_data;
            logic                     thru_push_data_last;
            logic                     thru_push_en;
            logic                     thru_push_af;

            logic [NPU_WT_ADDR_WIDTH-1:0] thru_wt_rd_addr;
            logic                     thru_wt_rd_en;

            logic [NPU_WT_ADDR_WIDTH-1:0] thru_wt_wr_addr;
            logic                     thru_wt_wr_en;
            logic [NPU_DATA_WIDTH-1:0] thru_wt_wr_data;

            logic [NPU_DATA_WIDTH-1:0] thru_pop_data;
            logic                     thru_pop_en;
            logic                     thru_pop_empty;
            logic                     thru_pop_ae;
            logic                     thru_pop_full;

            // INNER SLICE
            sa_slice_thru #(
                .PSUM_WIDTH         (PSUM_WIDTH),
                .SHIFT_WIDTH        (SHIFT_WIDTH),
                .WT_ADDR_WIDTH      (NPU_WT_ADDR_WIDTH),
                .WORD_SIZE          (NPU_DATA_WIDTH),
                .INPUT_FIFO_DEPTH   (INPUT_FIFO_DEPTH),
                .INPUT_FIFO_AF_LVL  (INPUT_FIFO_AF_LVL),
                .OUTPUT_FIFO_DEPTH  (OUTPUT_FIFO_DEPTH)
            ) slice_inner (
                .i_clk_sys         (clk_sys),
                .i_clk_sel         (top_clk_sel),
                .i_rst_n           (rstn_async),

                .i_cdc_req         (top_cdc_req),
                .o_cdc_ack         (top_cdc_ack_arrays[INNER]),
                .i_relu_en         (top_relu_en),
                .i_shift_by        (top_shift_by),
                .i_maxpool_en      (top_maxpool_en),

                .i_push_act_data   (top_push_act_data),
                .i_push_data_last  (top_push_data_last),
                .i_push_en         (top_push_en[INNER]),
                .o_push_af         (top_push_af[INNER]),
                
                .i_wt_sram_rd_addr (top_wt_rd_addr),
                .i_wt_sram_rd_en   (top_wt_rd_en[INNER]),

                .i_wt_sram_wr_addr (top_wt_wr_addr),
                .i_wt_sram_wr_en   (top_wt_wr_en[INNER]),
                .i_wt_sram_wr_data (top_wt_wr_data),

                .o_pop_data        (top_pop_data_arr[INNER]),
                .i_pop_en          (top_pop_en[INNER]),
                .o_pop_empty       (),
                .o_pop_ae          (top_pop_ae[INNER]),
                .o_pop_full        (top_pop_full[INNER]),

                // THRU ports: Route core's "OUTER" signals to/from the outer slice
                .o_thru_rst_n           (thru_rst_n),
                .o_thru_clk_sel         (thru_clk_sel),
                .o_thru_cdc_req         (thru_cdc_req),
                .i_thru_cdc_ack         (thru_cdc_ack),
                .o_thru_cdc_ack         (top_cdc_ack_arrays[OUTER]),
                .o_thru_relu_en         (thru_relu_en),
                .o_thru_shift_by        (thru_shift_by),
                .o_thru_maxpool_en      (thru_maxpool_en),

                .o_thru_push_act_data   (thru_push_act_data),
                .o_thru_push_data_last  (thru_push_data_last),
                .i_thru_push_en         (top_push_en[OUTER]),
                .o_thru_push_en         (thru_push_en),
                .i_thru_push_af         (thru_push_af),
                .o_thru_push_af         (top_push_af[OUTER]),

                .o_thru_wt_sram_rd_addr (thru_wt_rd_addr),
                .i_thru_wt_sram_rd_en   (top_wt_rd_en[OUTER]),
                .o_thru_wt_sram_rd_en   (thru_wt_rd_en),

                .o_thru_wt_sram_wr_addr (thru_wt_wr_addr),
                .i_thru_wt_sram_wr_en   (top_wt_wr_en[OUTER]),
                .o_thru_wt_sram_wr_en   (thru_wt_wr_en),
                .o_thru_wt_sram_wr_data (thru_wt_wr_data),

                .i_thru_pop_data        (thru_pop_data),
                .o_thru_pop_data        (top_pop_data_arr[OUTER]),
                .i_thru_pop_en          (top_pop_en[OUTER]),
                .o_thru_pop_en          (thru_pop_en),
                .i_thru_pop_empty       (thru_pop_empty),
                .o_thru_pop_empty       (), // Not used by core
                .i_thru_pop_ae          (thru_pop_ae),
                .o_thru_pop_ae          (top_pop_ae[OUTER]),
                .i_thru_pop_full        (thru_pop_full),
                .o_thru_pop_full        (top_pop_full[OUTER])
            );    

            // OUTER SLICE
            sa_slice #(
                .PSUM_WIDTH         (PSUM_WIDTH),
                .SHIFT_WIDTH        (SHIFT_WIDTH),
                .WT_ADDR_WIDTH      (NPU_WT_ADDR_WIDTH),
                .WORD_SIZE          (NPU_DATA_WIDTH),
                .INPUT_FIFO_DEPTH   (INPUT_FIFO_DEPTH),
                .INPUT_FIFO_AF_LVL  (INPUT_FIFO_AF_LVL),
                .OUTPUT_FIFO_DEPTH  (OUTPUT_FIFO_DEPTH)
            ) slice_outer (
                .i_clk_sys         (clk_sys),
                .i_clk_sel         (thru_clk_sel),
                .i_rst_n           (thru_rst_n),

                .i_cdc_req         (thru_cdc_req),
                .o_cdc_ack         (thru_cdc_ack),
                .i_relu_en         (thru_relu_en),
                .i_shift_by        (thru_shift_by),
                .i_maxpool_en      (thru_maxpool_en),

                .i_push_act_data   (thru_push_act_data),
                .i_push_data_last  (thru_push_data_last),
                .i_push_en         (thru_push_en),
                .o_push_af         (thru_push_af),
                
                .i_wt_sram_rd_addr (thru_wt_rd_addr),
                .i_wt_sram_rd_en   (thru_wt_rd_en),

                .i_wt_sram_wr_addr (thru_wt_wr_addr),
                .i_wt_sram_wr_en   (thru_wt_wr_en),
                .i_wt_sram_wr_data (thru_wt_wr_data),

                .o_pop_data        (thru_pop_data),
                .i_pop_en          (thru_pop_en),
                .o_pop_empty       (thru_pop_empty),
                .o_pop_ae          (thru_pop_ae),
                .o_pop_full        (thru_pop_full)
            );
            initial begin
                $display("[%0t] SYN not defined, annotating clock gen only", $time);
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/Clock_Gen/IBM130/syn/clk_gen_mode.syn.sdf", slice_inner.u_clk_gen);
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/Clock_Gen/IBM130/syn/clk_gen_mode.syn.sdf", slice_outer.u_clk_gen);
            end  
        end
    endgenerate

    // =========================================================================
    // Module: Bottom Half Systolic Arrays (Daisy Chained)
    // =========================================================================
    genvar bot_i;
    generate
        // Step by 2: Index 'bot_i' is Inner, 'bot_i + 1' is Outer
        for (bot_i = 0; bot_i < NUM_ARRAYS/2; bot_i = bot_i + 2) begin : BOTTOM_SYSTOLIC_ARRAYS
            localparam INNER = bot_i;
            localparam OUTER = bot_i + 1;

            // Intermediate wires between Inner (sa_slice_thru) and Outer (sa_slice)
            logic                     thru_rst_n;
            logic [2:0]               thru_clk_sel;
            logic                     thru_cdc_req;
            logic                     thru_cdc_ack;
            logic                     thru_relu_en;
            logic [SHIFT_WIDTH-1:0]   thru_shift_by;
            logic                     thru_maxpool_en;

            logic [NPU_DATA_WIDTH-1:0] thru_push_act_data;
            logic                     thru_push_data_last;
            logic                     thru_push_en;
            logic                     thru_push_af;

            logic [NPU_WT_ADDR_WIDTH-1:0] thru_wt_rd_addr;
            logic                     thru_wt_rd_en;

            logic [NPU_WT_ADDR_WIDTH-1:0] thru_wt_wr_addr;
            logic                     thru_wt_wr_en;
            logic [NPU_DATA_WIDTH-1:0] thru_wt_wr_data;

            logic [NPU_DATA_WIDTH-1:0] thru_pop_data;
            logic                     thru_pop_en;
            logic                     thru_pop_empty;
            logic                     thru_pop_ae;
            logic                     thru_pop_full;

            // INNER SLICE
            sa_slice_thru #(
                .PSUM_WIDTH         (PSUM_WIDTH),
                .SHIFT_WIDTH        (SHIFT_WIDTH),
                .WT_ADDR_WIDTH      (NPU_WT_ADDR_WIDTH),
                .WORD_SIZE          (NPU_DATA_WIDTH),
                .INPUT_FIFO_DEPTH   (INPUT_FIFO_DEPTH),
                .INPUT_FIFO_AF_LVL  (INPUT_FIFO_AF_LVL),
                .OUTPUT_FIFO_DEPTH  (OUTPUT_FIFO_DEPTH)
            ) slice_inner (
                .i_clk_sys         (clk_sys),
                .i_clk_sel         (bottom_clk_sel),
                .i_rst_n           (rstn_async),

                .i_cdc_req         (bottom_cdc_req),
                .o_cdc_ack         (bottom_cdc_ack_arrays[INNER]),
                .i_relu_en         (bottom_relu_en),
                .i_shift_by        (bottom_shift_by),
                .i_maxpool_en      (bottom_maxpool_en),

                .i_push_act_data   (bottom_push_act_data),
                .i_push_data_last  (bottom_push_data_last),
                .i_push_en         (bottom_push_en[INNER]),
                .o_push_af         (bottom_push_af[INNER]),
                
                .i_wt_sram_rd_addr (bottom_wt_rd_addr),
                .i_wt_sram_rd_en   (bottom_wt_rd_en[INNER]),

                .i_wt_sram_wr_addr (bottom_wt_wr_addr),
                .i_wt_sram_wr_en   (bottom_wt_wr_en[INNER]),
                .i_wt_sram_wr_data (bottom_wt_wr_data),

                .o_pop_data        (bottom_pop_data_arr[INNER]),
                .i_pop_en          (bottom_pop_en[INNER]),
                .o_pop_empty       (),
                .o_pop_ae          (bottom_pop_ae[INNER]),
                .o_pop_full        (bottom_pop_full[INNER]),

                // THRU ports: Route core's "OUTER" signals to/from the outer slice
                .o_thru_rst_n           (thru_rst_n),
                .o_thru_clk_sel         (thru_clk_sel),
                .o_thru_cdc_req         (thru_cdc_req),
                .i_thru_cdc_ack         (thru_cdc_ack),
                .o_thru_cdc_ack         (bottom_cdc_ack_arrays[OUTER]),
                .o_thru_relu_en         (thru_relu_en),
                .o_thru_shift_by        (thru_shift_by),
                .o_thru_maxpool_en      (thru_maxpool_en),

                .o_thru_push_act_data   (thru_push_act_data),
                .o_thru_push_data_last  (thru_push_data_last),
                .i_thru_push_en         (bottom_push_en[OUTER]),
                .o_thru_push_en         (thru_push_en),
                .i_thru_push_af         (thru_push_af),
                .o_thru_push_af         (bottom_push_af[OUTER]),

                .o_thru_wt_sram_rd_addr (thru_wt_rd_addr),
                .i_thru_wt_sram_rd_en   (bottom_wt_rd_en[OUTER]),
                .o_thru_wt_sram_rd_en   (thru_wt_rd_en),

                .o_thru_wt_sram_wr_addr (thru_wt_wr_addr),
                .i_thru_wt_sram_wr_en   (bottom_wt_wr_en[OUTER]),
                .o_thru_wt_sram_wr_en   (thru_wt_wr_en),
                .o_thru_wt_sram_wr_data (thru_wt_wr_data),

                .i_thru_pop_data        (thru_pop_data),
                .o_thru_pop_data        (bottom_pop_data_arr[OUTER]),
                .i_thru_pop_en          (bottom_pop_en[OUTER]),
                .o_thru_pop_en          (thru_pop_en),
                .i_thru_pop_empty       (thru_pop_empty),
                .o_thru_pop_empty       (), // Not used by core
                .i_thru_pop_ae          (thru_pop_ae),
                .o_thru_pop_ae          (bottom_pop_ae[OUTER]),
                .i_thru_pop_full        (thru_pop_full),
                .o_thru_pop_full        (bottom_pop_full[OUTER])
            );    

            // OUTER SLICE
            sa_slice #(
                .PSUM_WIDTH         (PSUM_WIDTH),
                .SHIFT_WIDTH        (SHIFT_WIDTH),
                .WT_ADDR_WIDTH      (NPU_WT_ADDR_WIDTH),
                .WORD_SIZE          (NPU_DATA_WIDTH),
                .INPUT_FIFO_DEPTH   (INPUT_FIFO_DEPTH),
                .INPUT_FIFO_AF_LVL  (INPUT_FIFO_AF_LVL),
                .OUTPUT_FIFO_DEPTH  (OUTPUT_FIFO_DEPTH)
            ) slice_outer (
                .i_clk_sys         (clk_sys),
                .i_clk_sel         (thru_clk_sel),
                .i_rst_n           (thru_rst_n),

                .i_cdc_req         (thru_cdc_req),
                .o_cdc_ack         (thru_cdc_ack),
                .i_relu_en         (thru_relu_en),
                .i_shift_by        (thru_shift_by),
                .i_maxpool_en      (thru_maxpool_en),

                .i_push_act_data   (thru_push_act_data),
                .i_push_data_last  (thru_push_data_last),
                .i_push_en         (thru_push_en),
                .o_push_af         (thru_push_af),
                
                .i_wt_sram_rd_addr (thru_wt_rd_addr),
                .i_wt_sram_rd_en   (thru_wt_rd_en),

                .i_wt_sram_wr_addr (thru_wt_wr_addr),
                .i_wt_sram_wr_en   (thru_wt_wr_en),
                .i_wt_sram_wr_data (thru_wt_wr_data),

                .o_pop_data        (thru_pop_data),
                .i_pop_en          (thru_pop_en),
                .o_pop_empty       (thru_pop_empty),
                .o_pop_ae          (thru_pop_ae),
                .o_pop_full        (thru_pop_full)
            );
            initial begin
                $display("[%0t] SYN not defined, annotating clock gen only", $time);
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/Clock_Gen/IBM130/syn/clk_gen_mode.syn.sdf", slice_inner.u_clk_gen);
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/Clock_Gen/IBM130/syn/clk_gen_mode.syn.sdf", slice_outer.u_clk_gen);
            end
        end
    endgenerate

    //mem_if wiring
    mem_bank #(
        .ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
        .DATA_WIDTH(NPU_DATA_WIDTH)
    ) bank0 (
        .i_clk(clk_sys),

        .i_s0_cen  (b0_s0_cen  ), 
        .i_s0_wen  (b0_s0_wen  ),
        .o_s0_rdata(b0_s0_rdata),
        .i_s0_addr (b0_s0_addr ),
        .i_s0_wdata(b0_s0_wdata),
        .i_s1_cen  (b0_s1_cen  ), 
        .i_s1_wen  (b0_s1_wen  ),
        .o_s1_rdata(b0_s1_rdata),
        .i_s1_addr (b0_s1_addr ),
        .i_s1_wdata(b0_s1_wdata)
    );

    mem_bank #(
        .ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
        .DATA_WIDTH(NPU_DATA_WIDTH)
    ) bank1 (
        .i_clk(clk_sys),

        .i_s0_cen  (b1_s0_cen  ), 
        .i_s0_wen  (b1_s0_wen  ),
        .o_s0_rdata(b1_s0_rdata),
        .i_s0_addr (b1_s0_addr ),
        .i_s0_wdata(b1_s0_wdata),
        .i_s1_cen  (b1_s1_cen  ), 
        .i_s1_wen  (b1_s1_wen  ),
        .o_s1_rdata(b1_s1_rdata),
        .i_s1_addr (b1_s1_addr ),
        .i_s1_wdata(b1_s1_wdata)
    );

    
    //writing to off-chip main memory
    logic [CPU_ADDR_WIDTH-1:0] adj_addr;
    always @(posedge clk_sys) begin
        mem_ready <= 0;
        if (mem_valid && !mem_ready) begin
            mem_ready <= 1;
            mem_rdata <= 'bx;
            case (1)
                (mem_addr >> 2) < MEM_WORDS: begin
                    if (|mem_wstrb) begin
                        if (mem_wstrb[0]) prgm_memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) prgm_memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) prgm_memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) prgm_memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
                    end else begin
                        mem_rdata <= prgm_memory[mem_addr >> 2];
                    end
                end

                // printing
                (mem_addr == PRINT_ADDR): begin
                    $write("%c", mem_wdata[7:0]);
                end

                // to the fmap memory
                (FMAP_ADDR <= mem_addr && mem_addr < WGT_ADDR): begin 
                    adj_addr = mem_addr - FMAP_ADDR;
                    //$display("fmap memaccess @%08h", mem_addr);
                    if (|mem_wstrb) begin
                        if (mem_wstrb[0]) fmap_memory[adj_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) fmap_memory[adj_addr >> 2][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) fmap_memory[adj_addr >> 2][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) fmap_memory[adj_addr >> 2][31:24] <= mem_wdata[31:24];
                        //$display("writef @addr:%8h  data: %h", adj_addr, mem_wdata);
                    end else begin
                        mem_rdata <= fmap_memory[adj_addr >> 2];
                        //$display("readf @addr:%8h  line: %d data: %h", adj_addr, adj_addr >> 2, mem_wdata);
                    end
                end

                // to the wgt memory
                (WGT_ADDR <= mem_addr): begin 
                    adj_addr = mem_addr - WGT_ADDR;
                    if (|mem_wstrb) begin
                        if (mem_wstrb[0]) wgt_memory[adj_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) wgt_memory[adj_addr >> 2][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) wgt_memory[adj_addr >> 2][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) wgt_memory[adj_addr >> 2][31:24] <= mem_wdata[31:24];
                    end else begin
                        mem_rdata <= wgt_memory[adj_addr >> 2];
                        //$display("readw @addr:%8h  data: %h", adj_addr, wgt_memory[adj_addr >> 2]);
                    end
                end

                default: $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
            endcase
        end
    end

    //file I/O and logger variables
    string program_memory_file;
    string fmap_memory_file;
    string wgt_memory_file;
    string program_trace_file;
    string memory_access_file;
    integer trace_fd;
    integer mem_access_fd;
    integer output_fd;
    integer retval;

    // Arg parsing and mem loading
    initial begin
        //dump for verdi
        // $fsdbDumpfile("net_large_tb.fsdb");
        // $fsdbDumpvars(0, net_large_tb);
        // $fsdbDumpMDA();

        for (int j=0; j<MEM_WORDS; j++) prgm_memory[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) fmap_memory[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) fmap_memory_clean[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) wgt_memory[j] = 0;
        
        //plusargs files
        if ($value$plusargs("PRGM_MEMORY=%s", program_memory_file)) begin
            $display("Loading main memory file: %s", program_memory_file);
        end else begin
            $display("Loading default memory file: program.mem");
            program_memory_file = "program.mem";
        end
        $readmemh(program_memory_file, prgm_memory);
        
        //trace_file
        // if ($value$plusargs("TRACE=%s", program_trace_file)) begin
        //     $display("Using trace output file: %s", program_trace_file);
        // end else begin
        //     $display("Using default trace output file: trace.out");
        //     program_trace_file = "trace.out";
        // end
        // trace_fd = $fopen(program_trace_file, "w");
        
        //mem_access file
        // if ($value$plusargs("MEMACCESS=%s", memory_access_file)) begin
        //     $display("Using memory access output file: %s", memory_access_file);
        // end else begin
        //     $display("Using default memory access file: mem_access.out");
        //     memory_access_file = "mem_access.out";
        // end
        // mem_access_fd = $fopen(memory_access_file, "w");

        // Load the mem files
        fmap_memory_file = "net_large_fmap.mem";
        wgt_memory_file = "net_large_wgt.mem";
        $readmemh(fmap_memory_file, fmap_memory);
        $readmemh(fmap_memory_file, fmap_memory_clean);
        $readmemh(wgt_memory_file, wgt_memory);

        // Clear the output portion of our dut fmap memory
        for (int j=(32'h00017a20 >> 2); j<MEM_WORDS; j++) fmap_memory[j] = 0;

        rstn_sync <= 0;
        rstn_async <= 0;
        repeat (100) @(posedge clk_sys);
        #1;
        rstn_sync <= 1;
        rstn_async <= 1;
    end

   
    // Flight Data Recorder (Trace)
    // initial begin
    //     repeat (10) @(posedge clk_sys);
    //     while (!trap) begin
    //         @(posedge clk_sys);
    //         if (trace_valid)
    //             $fwrite(trace_fd, "%x\n", trace_data);
    //     end
    //     $fclose(trace_fd);
    // end

    // Memory Access Logger
    // initial begin
    //     repeat (10) @(posedge clk_sys);
    //     while (!trap) begin
    //         @(posedge clk_sys);
    //         if (mem_valid && mem_ready) begin
    //             if (|mem_wstrb) begin
    //                 $fwrite(mem_access_fd, "WRITE: Addr=%08x, Data=%08x, Strb=%b\n", mem_addr, mem_wdata, mem_wstrb);
    //             end else begin
    //                 $fwrite(mem_access_fd, "READ:  Addr=%08x, Data=%08x\n", mem_addr, mem_rdata);
    //             end
    //         end
    //     end
    //     $fclose(mem_access_fd);
    // end

    int num_errors;

    always @(posedge clk_sys) begin
        if (rstn_sync && trap) begin
            $display("CPU TRAP HIT");
            $display("Checking memory...");
            output_fd = $fopen("net_large_fmap_dut.mem", "w");
            num_errors = 0;
            for(int word = 0; word < MEM_WORDS; word +=1 ) begin
            // for(int word = 0; word < ((32'h20051000 - FMAP_ADDR) >> 2); word +=1 ) begin
                $fwrite(output_fd, "%h\n", fmap_memory[word]);
                if(fmap_memory[word] !== fmap_memory_clean[word]) begin
                    num_errors += 1;
                    $display("Mismatch @addr:%8h @line:%0d act: %h exp: %h", (word << 2) + FMAP_ADDR, word+1, fmap_memory[word], fmap_memory_clean[word]);
    
                end
            end
            if(num_errors == 0) begin
                $display("TEST PASSED!!!!!!!");
            end else begin
                $display("TEST FAILED WITH %d ERRORS!!!!!!!", num_errors);
            end
            $finish;
        end
    end

    // Timeout failsafe
    initial begin
        #100000000;
        $display("TIMEOUT ERROR: Simulation hung.");
        $finish;
    end


endmodule