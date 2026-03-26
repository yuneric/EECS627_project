`define NUM_ARRAYS 8
`define ARRAY_SIZE 8

module donut_hole #(
    parameter CPU_ADDR_WIDTH        = 32,
    parameter CPU_DATA_WIDTH        = 32,
    parameter NPU_ACT_ADDR_WIDTH    = 12,
    parameter NPU_WT_ADDR_WIDTH     = 11,
    parameter NPU_DATA_WIDTH        = 64,
    parameter DIM_WIDTH             = 10,
    parameter MMIO_ADDR             = 32'h2000_0000,
    parameter MMIO_SIZE             = 32'h0000_0100,
    parameter ADDR_WIDTH            = 32,
    parameter DATA_WIDTH            = 32,
    parameter WT_ADDR_WIDTH         = 11,
    parameter WORD_SIZE             = 64,
    parameter OUTPUT_WIDTH          = 64,
    parameter DIM                   = 8
)(
    
    //this controller will have cpu, controller, mmu, axi_arbiter, comp_overseer/im2col_gen.
    //it will have ports that interface with mem_if, 8 SA slices, and abstracted off chip memory. 
    //so we need to think about the signals we need.
    input           i_clk       ,
    input           i_rstn_sync ,
    input           i_rstn_async,

    // Cpu trace signals
    output          o_trap       , 
    output          o_trace_valid,
    output [35:0]   o_trace_data ,

    // Axi Arbiter to off chip memory
    output                  o_mem_valid,
    input                   i_mem_ready,
    output [ADDR_WIDTH-1:0] o_mem_addr ,
    output [DATA_WIDTH-1:0] o_mem_wdata,
    output [3:0]            o_mem_wstrb,
    input  [DATA_WIDTH-1:0] i_mem_rdata,

    // ACT/OUTPUT SRAM interface - for the two banks.
    output                            o_b0_s0_cen   ,
    output                            o_b0_s0_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b0_s0_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b0_s0_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b0_s0_wdata ,

    output                            o_b0_s1_cen   ,
    output                            o_b0_s1_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b0_s1_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b0_s1_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b0_s1_wdata ,

    output                            o_b1_s0_cen   ,
    output                            o_b1_s0_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b1_s0_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b1_s0_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b1_s0_wdata ,

    output                            o_b1_s1_cen   ,
    output                            o_b1_s1_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b1_s1_rdata ,
    output [NPU_ACT_ADDR_WIDTH-1:0]   o_b1_s1_addr  ,
    output [NPU_DATA_WIDTH-1:0]       o_b1_s1_wdata ,

    // Systolic array ports
    //   Top Slices
    //     Config
    output                           o_top_cdc_req   ,
    input                            i_top_cdc_ack   ,
    output                           o_top_relu_en   ,
    output [4:0]                     o_top_shift_by  ,
    output                           o_top_maxpool_en,

    //     Input Fifos
    output  logic [NPU_DATA_WIDTH-1:0]             o_top_push_act_data,
    output  logic                                  o_top_push_data_last,
    output  logic [`NUM_ARRAYS-1:0]                o_top_push_en,
    input   logic                                  i_top_push_fifo_full,

    //      Weight SRAM ports
    output  logic [WT_ADDR_WIDTH-1:0]               o_top_wt_sram_rd_addr, //so this is to read from weight sram which we'll get from im2col_gen
    output  logic                                   o_top_wt_sram_rd_en, //this is to read from weight sram which we'll get from im2col_gen
    output  logic [WT_ADDR_WIDTH-1:0]               o_wt_mem_wr_addr, //this is the weight write address we'll get from mmu - when we want to load weights.
    output  logic [WORD_SIZE-1:0]                   o_wt_mem_wr_data, //this is the data we'll get from the off chip memory and through the mmu - we need the mmu because it parses the words
    output  logic [WT_BANKS-1:0]                    o_wt_mem_wr_en, //this gives us the sram_selection when we load weights
    output  logic [WORD_SIZE-1:0]                   o_wt_mem_wr_data, //this is the parsed, 64 bit data we'll be getting from mmu.
   

    // Local weight SRAM MMU writes
    // input  logic [WT_ADDR_WIDTH-1:0]               i_wt_sram_wr_addr,
    // input  logic                                   i_wt_sram_wr_en,
    // input  logic [DATA_WIDTH*WORD_SIZE-1:0]        i_wt_sram_wr_data,

    // Output Fifo
    output logic [`ARRAY_SIZE*OUTPUT_WIDTH-1:0]    o_pop_data,
    input  logic                                   i_pop_en,
    output logic                                   o_pop_empty, 
    output logic                                   o_rd_almost_empty,
    output logic                                   o_rd_full

    //    Bot Slices
);    

    // CPU to Address decoder signals
    logic                        cpu_valid;
    logic                        cpu_instr;
    logic                        cpu_ready;
    logic [CPU_ADDR_WIDTH-1:0]   cpu_addr;
    logic [CPU_DATA_WIDTH-1:0]   cpu_wdata;
    logic [3:0]                  cpu_wstrb;
    logic [CPU_DATA_WIDTH-1:0]   cpu_rdata;

    // Address Decoder to Arbiter (CPU Path)
    logic                        dec_mem_valid; 
    logic                        dec_mem_instr;
    logic [CPU_ADDR_WIDTH-1:0]   dec_mem_addr;
    logic [CPU_DATA_WIDTH-1:0]   dec_mem_wdata;
    logic [3:0]                  dec_mem_wstrb;
    logic                        dec_mem_ready;
    logic [CPU_DATA_WIDTH-1:0]   dec_mem_rdata;

    // Address Decoder to Controller (MMIO Path)
    logic                        mmio_valid; 
    logic                        mmio_ready;
    logic [CPU_ADDR_WIDTH-1:0]   mmio_addr;
    logic [CPU_DATA_WIDTH-1:0]   mmio_wdata;
    logic [3:0]                  mmio_wstrb;
    logic [CPU_DATA_WIDTH-1:0]   mmio_rdata;

    // Controller to Computation Overseer
    logic                  comp_compute_start; 
    logic [1:0]            comp_stride; 
    logic [1:0]            comp_padding;
    logic                  comp_maxpool_en; 
    logic                  comp_relu_en;
    logic [4:0]            comp_scale_amt;
    logic [DIM_WIDTH-1:0]  comp_Hi; 
    logic [DIM_WIDTH-1:0]  comp_Wi; 
    logic [DIM_WIDTH-1:0]  comp_Hf; 
    logic [DIM_WIDTH-1:0]  comp_Wf;
    logic [DIM_WIDTH-1:0]  comp_Ho; 
    logic [DIM_WIDTH-1:0]  comp_Wo; 
    logic [DIM_WIDTH-1:0]  comp_words_per_channel;
    logic [DIM_WIDTH-1:0]  comp_num_kernels;
    logic                  comp_done;

    // Controller to MMU
    logic                      mmu_load_weights; 
    logic                      mmu_load_tile;
    logic                      mmu_store_tile;
    logic [DIM_WIDTH-1:0]      mmu_N;
    logic [DIM_WIDTH-1:0]      mmu_H;
    logic [DIM_WIDTH-1:0]      mmu_W;
    logic [DIM_WIDTH-1:0]      mmu_words_per_channel;
    logic [DIM_WIDTH-1:0]      mmu_tile_stride;
    logic [CPU_ADDR_WIDTH-1:0] mmu_addr;
    logic                      mmu_done;

    // MMU to Arbiter (NPU AXI)
    logic [CPU_ADDR_WIDTH-1:0]  npu_araddr, npu_awaddr;
    logic [7:0]                 npu_arlen, npu_awlen;
    logic [2:0]                 npu_arsize, npu_awsize;
    logic                       npu_arvalid, npu_arready, npu_awvalid, npu_awready;
    logic [CPU_DATA_WIDTH-1:0]  npu_rdata, npu_wdata;
    logic [3:0]                 npu_wstrb;
    logic                       npu_rlast, npu_rvalid, npu_rready;
    logic                       npu_wlast, npu_wvalid, npu_wready;
    logic                       npu_bvalid, npu_bready;

    // Controller to Srams
    logic                      sram_load_weights;
    logic                      bank_sel;

    // MMU to SRAMs
    logic [NPU_WT_ADDR_WIDTH-1:0]  wgt_addr;
    logic                          wgt_wen;
    logic [NPU_DATA_WIDTH-1:0]     wgt_wdata;
    logic [2:0]                    wgt_sram_sel;
    logic [NPU_ACT_ADDR_WIDTH-1:0] act_waddr;
    logic [NPU_ACT_ADDR_WIDTH-1:0] act_raddr;
    logic                          act_wen;
    logic                          act_ren;
    logic [NPU_DATA_WIDTH-1:0]     act_wdata;
    logic [NPU_DATA_WIDTH-1:0]     act_rdata;

    // Computation Overseer to Mem Interface
    logic [NPU_ACT_ADDR_WIDTH-1:0] comp_waddr;
    logic                          comp_wen;
    logic [NPU_DATA_WIDTH-1:0]     comp_wdata;
    logic [NPU_ACT_ADDR_WIDTH-1:0] comp_raddr;
    logic                          comp_ren;
    logic [NPU_DATA_WIDTH-1:0]     comp_rdata;

    picorv32 proc (
        .clk        (i_clk          ), 
        .resetn     (i_rstn_sync    ), 
        .trap       (o_trap         ),
        .trace_valid(o_trace_valid  ), 
        .trace_data (o_trace_data   ),
        .mem_valid  (cpu_valid      ), 
        .mem_instr  (cpu_instr      ), 
        .mem_ready  (cpu_ready      ),
        .mem_addr   (cpu_addr       ), 
        .mem_wdata  (cpu_wdata      ), 
        .mem_wstrb  (cpu_wstrb      ), 
        .mem_rdata  (cpu_rdata      )
    );

    address_decoder #(
        .ADDR_WIDTH(CPU_ADDR_WIDTH), 
        .DATA_WIDTH(CPU_DATA_WIDTH),
        .MMIO_ADDR(MMIO_ADDR), 
        .MMIO_SIZE(MMIO_SIZE)
    ) addr_dec_inst (
        .i_cpu_valid(cpu_valid      ), 
        .i_cpu_instr(cpu_instr      ), 
        .i_cpu_addr (cpu_addr       ),
        .i_cpu_wdata(cpu_wdata      ), 
        .i_cpu_wstrb(cpu_wstrb      ), 
        .o_cpu_ready(cpu_ready      ), 
        .o_cpu_rdata(cpu_rdata      ),

        .o_mem_valid(dec_mem_valid  ), 
        .o_mem_instr(dec_mem_instr  ), 
        .o_mem_addr (dec_mem_addr   ),
        .o_mem_wdata(dec_mem_wdata  ), 
        .o_mem_wstrb(dec_mem_wstrb  ), 
        .i_mem_ready(dec_mem_ready  ), 
        .i_mem_rdata(dec_mem_rdata  ),

        .o_mmio_valid(mmio_valid    ), 
        .o_mmio_addr (mmio_addr     ), 
        .o_mmio_wdata(mmio_wdata    ),
        .o_mmio_wstrb(mmio_wstrb    ), 
        .i_mmio_ready(mmio_ready    ), 
        .i_mmio_rdata(mmio_rdata    )
    );

    axi_arbiter #(
        .ADDR_WIDTH(CPU_ADDR_WIDTH), 
        .DATA_WIDTH(CPU_DATA_WIDTH)
    ) arbiter_inst (
        .clk            (i_clk          ), 
        .rst_n          (i_rstn_async   ),
        .i_cpu_valid    (dec_mem_valid  ), 
        .o_cpu_ready    (dec_mem_ready  ), 
        .i_cpu_addr     (dec_mem_addr   ),
        .i_cpu_wdata    (dec_mem_wdata  ), 
        .i_cpu_wstrb    (dec_mem_wstrb  ), 
        .o_cpu_rdata    (dec_mem_rdata  ),

        .i_npu_araddr   (npu_araddr     ),
        .i_npu_arlen    (npu_arlen      ), 
        .i_npu_arsize   (npu_arsize     ),
        .i_npu_arvalid  (npu_arvalid    ), 
        .o_npu_arready  (npu_arready    ),
        .o_npu_rdata    (npu_rdata      ), 
        .o_npu_rvalid   (npu_rvalid     ), 
        .o_npu_rlast    (npu_rlast      ), 
        .i_npu_rready   (npu_rready     ),

        .i_npu_awaddr   (npu_awaddr     ), 
        .i_npu_awlen    (npu_awlen      ), 
        .i_npu_awsize   (npu_awsize     ),
        .i_npu_awvalid  (npu_awvalid    ), 
        .o_npu_awready  (npu_awready    ),
        .i_npu_wdata    (npu_wdata      ), 
        .i_npu_wstrb    (npu_wstrb      ), 
        .i_npu_wlast    (npu_wlast      ),
        .i_npu_wvalid   (npu_wvalid     ), 
        .o_npu_wready   (npu_wready     ),
        .o_npu_bresp    (               ), 
        .o_npu_bvalid   (npu_bvalid     ), 
        .i_npu_bready   (npu_bready     ),

        .o_mem_valid    (o_mem_valid    ), 
        .i_mem_ready    (i_mem_ready    ), 
        .o_mem_addr     (o_mem_addr     ),
        .o_mem_wdata    (o_mem_wdata    ), 
        .o_mem_wstrb    (o_mem_wstrb    ), 
        .i_mem_rdata    (i_mem_rdata    )
    );
    
    controller #(
        .ADDR_WIDTH(CPU_ADDR_WIDTH), 
        .DATA_WIDTH(CPU_DATA_WIDTH), 
        .DIM_WIDTH(DIM_WIDTH)
    ) controller_inst (
        .i_clk      (i_clk       ), 
        .i_resetn   (i_rstn_async),

        // CPU connections
        .i_cpu_valid(mmio_valid), 
        .i_cpu_addr (mmio_addr ), 
        .i_cpu_wdata(mmio_wdata),
        .i_cpu_wstrb(mmio_wstrb), 
        .o_cpu_ready(mmio_ready), 
        .o_cpu_rdata(mmio_rdata), 

        // Computation overseer connections
        .o_comp_compute_start    (comp_compute_start  ), 
        .i_comp_done             (comp_done           ),
        .o_comp_stride           (comp_stride         ),
        .o_comp_padding          (comp_padding        ),
        .o_comp_maxpool_en       (comp_maxpool_en     ), 
        .o_comp_relu_en          (comp_relu_en        ),
        .o_comp_scale_amt        (comp_scale_amt      ), 
        .o_comp_Hi               (comp_Hi             ),
        .o_comp_Wi               (comp_Wi             ), 
        .o_comp_Hf               (comp_Hf             ), 
        .o_comp_Wf               (comp_Wf             ),
        .o_comp_Ho               (comp_Ho             ), 
        .o_comp_Wo               (comp_Wo             ),
        .o_comp_words_per_channel(comp_words_per_channel), 
        .o_comp_num_kernels      (comp_num_kernels    ),

        // MMU connections
        .o_sram_load_weights    (sram_load_weights      ),
        .o_mmu_load_weights     (mmu_load_weights       ), 
        .o_mmu_load_tile        (mmu_load_tile          ), 
        .o_mmu_store_tile       (mmu_store_tile         ),
        .o_mmu_N                (mmu_N                  ), 
        .o_mmu_H                (mmu_H                  ), 
        .o_mmu_W                (mmu_W                  ),
        .o_mmu_words_per_channel(mmu_words_per_channel  ), 
        .o_mmu_tile_stride      (mmu_tile_stride        ),
        .o_mmu_addr             (mmu_addr               ), 
        .i_mmu_done             (mmu_done               ),
        .o_bank_sel             (bank_sel               )
    );

    mmu #(
        .ADDR_WIDTH(CPU_ADDR_WIDTH), 
        .DATA_WIDTH(CPU_DATA_WIDTH), 
        .WORD_SIZE(NPU_DATA_WIDTH)
    ) mmu_inst (
        .i_clk  (i_clk), 
        .i_rst_n(i_rstn_async),

        .i_load_weights     (mmu_load_weights   ), 
        .i_load_tile        (mmu_load_tile      ), 
        .i_store_tile       (mmu_store_tile     ),
        .i_N                (mmu_N              ), 
        .i_W                (mmu_W              ), 
        .i_H                (mmu_H              ),
        .i_words_per_channel(mmu_words_per_channel), 
        .i_addr             (mmu_addr           ), 
        .i_tile_stride      (mmu_tile_stride    ),
        .o_done             (mmu_done           ),

        .o_wgt_addr     (wgt_addr   ), 
        .o_wgt_wen      (wgt_wen    ), 
        .o_wgt_wdata    (wgt_wdata  ), 
        .o_wgt_sram_sel (wgt_sram_sel),
        .o_act_waddr    (act_waddr  ), 
        .o_act_wen      (act_wen    ), 
        .o_act_wdata    (act_wdata  ),
        .o_act_raddr    (act_raddr  ), 
        .o_act_ren      (act_ren    ), 
        .i_act_rdata    (act_rdata  ),

        .o_npu_araddr   (npu_araddr ), 
        .o_npu_arlen    (npu_arlen  ), 
        .o_npu_arsize   (npu_arsize ),
        .o_npu_arvalid  (npu_arvalid), 
        .i_npu_arready  (npu_arready),
        .i_npu_rdata    (npu_rdata  ), 
        .i_npu_rlast    (npu_rlast  ), 
        .i_npu_rvalid   (npu_rvalid ), 
        .o_npu_rready   (npu_rready ),

        .o_npu_awaddr   (npu_awaddr ), 
        .o_npu_awlen    (npu_awlen  ), 
        .o_npu_awsize   (npu_awsize ),
        .o_npu_awvalid  (npu_awvalid), 
        .i_npu_awready  (npu_awready),
        .o_npu_wdata    (npu_wdata  ), 
        .o_npu_wstrb    (npu_wstrb  ), 
        .o_npu_wlast    (npu_wlast  ),
        .o_npu_wvalid   (npu_wvalid ), 
        .i_npu_wready   (npu_wready ),
        .i_npu_bvalid   (npu_bvalid ), 
        .o_npu_bready   (npu_bready )
    );
    
    // SA Slice & Im2Col Signals
    logic                           push_en;
    logic [DIM-1:0]                 push_fifo_full;
    logic [WT_ADDR_WIDTH-1:0]       wt_sram_rd_addr;
    logic                           wt_sram_rd_en;
    logic [NUM_ARRAYS-1:0]          array_active;

    // FIFO Interface
    logic [WORD_SIZE-1:0]           pop_data;
    logic [DIM-1:0]                 pop_en;
    logic [DIM-1:0]                 pop_empty;
    logic [DIM-1:0]                 almost_empty;
    logic [DIM-1:0]                 rd_full;
    logic [DIM-1:0]                 rd_empty;

    computation_overseer #(
        .DIM(8), 
        .NUM_ARRAYS(8), 
        .DIM_WIDTH(DIM_WIDTH),
        .MEM_IF_ADDR_WIDTH(NPU_ACT_ADDR_WIDTH), 
        .WT_ADDR_WIDTH(NPU_WT_ADDR_WIDTH),
        .WORD_SIZE(NPU_DATA_WIDTH), 
        .SHIFT_WIDTH(5)
    ) dut (
        .i_clk(i_clk), 
        .i_rst_n(i_rstn_async),

        .i_comp_compute_start   (comp_compute_start),
        .i_comp_stride          (comp_stride),
        .i_comp_padding         (comp_padding),
        .i_comp_maxpool_en      (comp_maxpool_en),
        .i_comp_relu_en         (comp_relu_en),
        .i_comp_scale_amt       (comp_scale_amt),
        .i_comp_Hi              (comp_Hi), 
        .i_comp_Wi              (comp_Wi),
        .i_comp_Hf              (comp_Hf), 
        .i_comp_Wf              (comp_Wf),
        .i_comp_Ho              (comp_Ho), 
        .i_comp_Wo              (comp_Wo),
        .i_comp_words_per_channel(comp_words_per_channel),
        .i_comp_num_kernels     (comp_num_kernels),

        .o_comp_done            (comp_done),
        .o_comp_waddr           (comp_waddr),
        .o_comp_wen             (comp_wen),
        .o_comp_wdata           (comp_wdata),
        .o_comp_raddr           (comp_raddr),
        .o_comp_ren             (comp_ren),

        .o_cdc_req              (o_top_cdc_req), // Hooked to your top level port
        .i_cdc_ack              (i_top_cdc_ack),
        .o_relu_en              (o_top_relu_en),
        .o_shift_by             (o_top_shift_by),
        .o_maxpool_en           (o_top_maxpool_en),

        .o_push_en              (push_en),
        .i_push_fifo_full       (push_fifo_full),
        .o_wt_sram_rd_addr      (wt_sram_rd_addr),
        .o_wt_sram_rd_en        (wt_sram_rd_en),

        .i_pop_data             (pop_data),
        .o_pop_en               (pop_en),
        .i_pop_empty            (pop_empty),
        .o_array_active         (array_active),

        .i_almost_empty         (almost_empty),
        .i_rd_full              (rd_full),
        .i_rd_empty             (rd_empty)
    );

    // mem_if #(
    //     .ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
    //     .DATA_WIDTH(NPU_DATA_WIDTH)
    // ) mem_if_inst (
    //     .i_mmu_waddr(act_waddr),
    //     .i_mmu_wen  (act_wen),
    //     .i_mmu_wdata(act_wdata),

    //     .i_mmu_raddr(act_raddr),
    //     .i_mmu_ren  (act_ren),
    //     .o_mmu_rdata(act_rdata),
        
    //     .i_comp_waddr(comp_waddr),
    //     .i_comp_wen  (comp_wen),
    //     .i_comp_wdata(comp_wdata),

    //     .i_comp_raddr(comp_raddr),
    //     .i_comp_ren  (comp_ren),
    //     .o_comp_rdata(comp_rdata),

    //     .o_b0_s0_cen  (o_b0_s0_cen  ),
    //     .o_b0_s0_wen  (o_b0_s0_wen  ),
    //     .i_b0_s0_rdata(i_b0_s0_rdata),
    //     .o_b0_s0_addr (o_b0_s0_addr ),
    //     .o_b0_s0_wdata(o_b0_s0_wdata),
    //     .o_b0_s1_cen  (o_b0_s1_cen  ),
    //     .o_b0_s1_wen  (o_b0_s1_wen  ),
    //     .i_b0_s1_rdata(i_b0_s1_rdata),
    //     .o_b0_s1_addr (o_b0_s1_addr ),
    //     .o_b0_s1_wdata(o_b0_s1_wdata),
    //     .o_b1_s0_cen  (o_b1_s0_cen  ),
    //     .o_b1_s0_wen  (o_b1_s0_wen  ),
    //     .i_b1_s0_rdata(i_b1_s0_rdata),
    //     .o_b1_s0_addr (o_b1_s0_addr ),
    //     .o_b1_s0_wdata(o_b1_s0_wdata),
    //     .o_b1_s1_cen  (o_b1_s1_cen  ),
    //     .o_b1_s1_wen  (o_b1_s1_wen  ),
    //     .i_b1_s1_rdata(i_b1_s1_rdata),
    //     .o_b1_s1_addr (o_b1_s1_addr ),
    //     .o_b1_s1_wdata(o_b1_s1_wdata),

    //     .i_bank_sel(bank_sel) 
    // );

    // // =====================================================================
    // // ADDED LOGIC: Glue Logic & SA Slices (Top/Bottom Split)
    // // (Appended below without changing any existing code above)
    // // =====================================================================

    // // 1. SRAM Alignment Pipeline (1-cycle delay to align with SRAM rdata)
    // logic [`NUM_ARRAYS-1:0] push_en_aligned;
    // logic [NPU_DATA_WIDTH-1:0] push_act_data_aligned;
    
    // always_ff @(posedge i_clk or negedge i_rstn_sync) begin
    //     if (!i_rstn_sync) begin
    //         push_en_aligned <= '0;
    //     end else begin
    //         push_en_aligned <= push_en; // push_en comes from computation_overseer
    //     end
    // end
    // assign push_act_data_aligned = comp_rdata; // The returned data from mem_if

    // // 2. Weight SRAM Write Decoder (translates MMU's 3-bit sel to 8-bit enable)
    // logic [`NUM_ARRAYS-1:0] decoded_wgt_wen;
    // always_comb begin
    //     decoded_wgt_wen = '0;
    //     if (wgt_wen) begin
    //         decoded_wgt_wen[wgt_sram_sel] = 1'b1;
    //     end
    // end

    // // 3. Output Pop Data Multiplexer (muxes flattened bus into Overseer)
    // logic [`NUM_ARRAYS*NPU_DATA_WIDTH-1:0] pop_data_flat;
    // logic [NPU_DATA_WIDTH-1:0] pop_data_muxed;
    // integer j;
    // always_comb begin
    //     pop_data_muxed = '0;
    //     for (j = 0; j < `NUM_ARRAYS; j = j + 1) begin
    //         if (pop_en[j]) begin
    //             pop_data_muxed = pop_data_flat[j*NPU_DATA_WIDTH +: NPU_DATA_WIDTH];
    //         end
    //     end
    // end
    // assign pop_data = pop_data_muxed; // Feeds into computation_overseer

    // // Wires to connect the internal SA slices back to the Overseer
    // logic [`NUM_ARRAYS-1:0] sa_cdc_ack_arr;
    // logic [`NUM_ARRAYS-1:0] sa_push_fifo_full_arr;
    // logic [`NUM_ARRAYS-1:0] sa_pop_empty_arr;
    // logic [`NUM_ARRAYS-1:0] sa_pop_almost_empty_arr;
    // logic [`NUM_ARRAYS-1:0] sa_pop_full_arr;

    // assign push_fifo_full = sa_push_fifo_full_arr;
    // assign pop_empty = sa_pop_empty_arr;
    // assign almost_empty = sa_pop_almost_empty_arr;
    // assign rd_full = sa_pop_full_arr;
    // assign rd_empty = sa_pop_empty_arr;

    // // Optional: Route internally generated signals to the external ports you defined
    // assign o_top_push_en = push_en_aligned;
    // assign o_top_push_act_data = push_act_data_aligned;
    // assign o_top_push_data_last = 1'b0;

    // // 4. Systolic Array Instantiations (Split into Top and Bottom groups)
    // genvar i;
    // generate
    //     // TOP SLICES (0 to 3)
    //     for (i = 0; i < 4; i = i + 1) begin : top_sa_slices
    //         sa_slice #(
    //             .WT_ADDR_WIDTH(NPU_WT_ADDR_WIDTH),
    //             .DATA_WIDTH(NPU_DATA_WIDTH),
    //             .SHIFT_WIDTH(5)
    //         ) slice_inst (
    //             .i_clk(i_clk),
    //             .i_rst_n(i_rstn_sync),

    //             // Config
    //             .i_cdc_req(o_top_cdc_req),        
    //             .o_cdc_ack(sa_cdc_ack_arr[i]),
    //             .i_relu_en(o_top_relu_en),
    //             .i_shift_by(o_top_shift_by),
    //             .i_maxpool_en(o_top_maxpool_en),

    //             // Activation Push
    //             .i_push_act_data(push_act_data_aligned),
    //             .i_push_data_last(1'b0), 
    //             .i_push_en(push_en_aligned[i]),
    //             .o_push_fifo_full(sa_push_fifo_full_arr[i]),

    //             // Weight SRAM Read/Write
    //             .i_wt_sram_rd_addr(wt_sram_rd_addr),
    //             .i_wt_sram_rd_en(wt_sram_rd_en),
    //             .i_wt_sram_wr_addr(wgt_addr),
    //             .i_wt_sram_wr_en(decoded_wgt_wen[i]),
    //             .i_wt_sram_wr_data(wgt_wdata),

    //             // Output Pop
    //             .o_pop_data(pop_data_flat[i * NPU_DATA_WIDTH +: NPU_DATA_WIDTH]),
    //             .i_pop_en(pop_en[i]),
    //             .o_pop_almost_empty(sa_pop_almost_empty_arr[i]),
    //             .o_pop_full(sa_pop_full_arr[i]),
    //             .o_pop_empty(sa_pop_empty_arr[i])
    //         );
    //     end

    //     // BOTTOM SLICES (4 to 7)
    //     for (i = 4; i < 8; i = i + 1) begin : bot_sa_slices
    //         sa_slice #(
    //             .WT_ADDR_WIDTH(NPU_WT_ADDR_WIDTH),
    //             .DATA_WIDTH(NPU_DATA_WIDTH),
    //             .SHIFT_WIDTH(5)
    //         ) slice_inst (
    //             .i_clk(i_clk),
    //             .i_rst_n(i_rstn_sync),

    //             // Config
    //             .i_cdc_req(o_top_cdc_req),
    //             .o_cdc_ack(sa_cdc_ack_arr[i]),
    //             .i_relu_en(o_top_relu_en),
    //             .i_shift_by(o_top_shift_by),
    //             .i_maxpool_en(o_top_maxpool_en),

    //             // Activation Push
    //             .i_push_act_data(push_act_data_aligned),
    //             .i_push_data_last(1'b0),
    //             .i_push_en(push_en_aligned[i]),
    //             .o_push_fifo_full(sa_push_fifo_full_arr[i]),

    //             // Weight SRAM Read/Write
    //             .i_wt_sram_rd_addr(wt_sram_rd_addr),
    //             .i_wt_sram_rd_en(wt_sram_rd_en),
    //             .i_wt_sram_wr_addr(wgt_addr),
    //             .i_wt_sram_wr_en(decoded_wgt_wen[i]),
    //             .i_wt_sram_wr_data(wgt_wdata),

    //             // Output Pop
    //             .o_pop_data(pop_data_flat[i * NPU_DATA_WIDTH +: NPU_DATA_WIDTH]),
    //             .i_pop_en(pop_en[i]),
    //             .o_pop_almost_empty(sa_pop_almost_empty_arr[i]),
    //             .o_pop_full(sa_pop_full_arr[i]),
    //             .o_pop_empty(sa_pop_empty_arr[i])
    //         );
    //     end
    // endgenerate

endmodule