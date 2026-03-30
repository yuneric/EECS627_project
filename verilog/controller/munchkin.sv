`define NUM_ARRAYS 8

module munchkin #(
    parameter CPU_ADDR_WIDTH        = 32,
    parameter CPU_DATA_WIDTH        = 32,
    parameter NPU_ACT_ADDR_WIDTH    = 12,
    parameter NPU_WT_ADDR_WIDTH     = 11,
    parameter NPU_DATA_WIDTH        = 64,
    parameter DIM_WIDTH             = 10,
    parameter MMIO_ADDR             = 32'h2000_0000,
    parameter MMIO_SIZE             = 32'h0000_0100
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
    output                      o_mem_valid,
    input                       i_mem_ready,
    output [CPU_ADDR_WIDTH-1:0] o_mem_addr ,
    output [CPU_DATA_WIDTH-1:0] o_mem_wdata,
    output [3:0]                o_mem_wstrb,
    input  [CPU_DATA_WIDTH-1:0] i_mem_rdata,

    // ACT/OUTPUT SRAM interface - for the two banks and two ports.
    output                            o_b0_s0_cen   ,
    output                            o_b0_s0_wen   ,
    input  [NPU_DATA_WIDTH-1:0]       i_b0_s0_rdata , //we want this to be input so that this data could be fed into SA slice -> the input fifo.
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
    output                           o_cdc_req   ,
    input  [`NUM_ARRAYS-1:0]         i_cdc_ack   ,
    output                           o_relu_en   ,
    output [4:0]                     o_shift_by  ,
    output                           o_maxpool_en,

    //     Input Fifos
    output  logic [NPU_DATA_WIDTH-1:0]             o_push_act_data,
    output  logic                                  o_push_data_last,
    output  logic [`NUM_ARRAYS-1:0]                o_push_en,
    input   logic [`NUM_ARRAYS-1:0]                i_push_af,

    //      Weight SRAM ports
    output  logic [NPU_WT_ADDR_WIDTH-1:0]           o_wt_sram_rd_addr, //so this is to read from weight sram which we'll get from im2col_gen
    output  logic [`NUM_ARRAYS-1:0]                 o_wt_sram_rd_en, //this is to read from weight sram which we'll get from im2col_gen
    output  logic [NPU_WT_ADDR_WIDTH-1:0]           o_wt_mem_wr_addr, //this is the weight write address we'll get from mmu - when we want to load weights.
    output  logic [NPU_DATA_WIDTH-1:0]              o_wt_mem_wr_data, //this is the data we'll get from the off chip memory and through the mmu - we need the mmu because it parses the words
    output  logic [`NUM_ARRAYS-1:0]                 o_wt_mem_wr_en, //this gives us the sram_selection when we load weights
   

    // Local weight SRAM MMU writes
    // input  logic [WT_ADDR_WIDTH-1:0]               i_wt_sram_wr_addr,
    // input  logic                                   i_wt_sram_wr_en,
    // input  logic [DATA_WIDTH*WORD_SIZE-1:0]        i_wt_sram_wr_data,

    // Output Fifo
    input  logic [NPU_DATA_WIDTH-1:0]              i_pop_data,
    output logic [`NUM_ARRAYS-1:0]                 o_pop_en,
    // input  logic                                   i_pop_empty, 
    input  logic [`NUM_ARRAYS-1:0]                 i_pop_ae,
    input  logic [`NUM_ARRAYS-1:0]                 i_pop_full

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
    //logic                      sram_load_weights;
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
        .o_sram_load_weights    (),
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
        .CPU_ADDR_WIDTH(CPU_ADDR_WIDTH), 
        .CPU_DATA_WIDTH(CPU_DATA_WIDTH),
        .NPU_ACT_ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
        .NPU_WT_ADDR_WIDTH(NPU_WT_ADDR_WIDTH),
        .NPU_DATA_WIDTH(NPU_DATA_WIDTH)
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
    logic                           push_data_last;
    logic [NPU_WT_ADDR_WIDTH-1:0]   wt_sram_rd_addr;
    logic [`NUM_ARRAYS-1:0]         wt_sram_rd_en;
    logic [`NUM_ARRAYS-1:0]         array_active;

    computation_overseer #(
        // .DIM(`ARRA), 
        .NUM_ARRAYS(`NUM_ARRAYS), 
        .DIM_WIDTH(DIM_WIDTH),
        .MEM_IF_ADDR_WIDTH(NPU_ACT_ADDR_WIDTH), 
        .WT_ADDR_WIDTH(NPU_WT_ADDR_WIDTH),
        .WORD_SIZE(NPU_DATA_WIDTH), 
        .SHIFT_WIDTH(5)
    ) comp_over_inst (
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

        .o_cdc_req              (o_cdc_req), // Hooked to your top level port
        .i_cdc_ack              (&(i_cdc_ack | ~array_active)),
        .o_relu_en              (o_relu_en),
        .o_shift_by             (o_shift_by),
        .o_maxpool_en           (o_maxpool_en),

        .o_push_en              (push_en),
        .i_push_fifo_full       (i_push_af),
        .o_data_last            (push_data_last),
        .o_wt_sram_rd_addr      (wt_sram_rd_addr),
        .o_wt_sram_rd_en        (wt_sram_rd_en),

        .o_array_active         (array_active),

        .i_pop_data             (i_pop_data),
        .o_pop_en               (o_pop_en),
        // .i_pop_empty            (i_pop_empty),
        .i_pop_almost_empty     (i_pop_ae),
        .i_pop_full             (i_pop_full)
    );

    mem_if #(
        .ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
        .DATA_WIDTH(NPU_DATA_WIDTH)
    ) mem_if_inst (
        .i_mmu_waddr  (act_waddr),
        .i_mmu_wen    (act_wen),
        .i_mmu_wdata  (act_wdata),
        .i_mmu_raddr  (act_raddr),
        .i_mmu_ren    (act_ren),
        .o_mmu_rdata  (act_rdata),
        
        .i_comp_waddr (comp_waddr),
        .i_comp_wen   (comp_wen),
        .i_comp_wdata (comp_wdata),
        .i_comp_raddr (comp_raddr),
        .i_comp_ren   (comp_ren),
        .o_comp_rdata (comp_rdata),

        .o_b0_s0_cen  (o_b0_s0_cen  ),
        .o_b0_s0_wen  (o_b0_s0_wen  ),
        .i_b0_s0_rdata(i_b0_s0_rdata),
        .o_b0_s0_addr (o_b0_s0_addr ),
        .o_b0_s0_wdata(o_b0_s0_wdata),

        .o_b0_s1_cen  (o_b0_s1_cen  ),
        .o_b0_s1_wen  (o_b0_s1_wen  ),
        .i_b0_s1_rdata(i_b0_s1_rdata),
        .o_b0_s1_addr (o_b0_s1_addr ),
        .o_b0_s1_wdata(o_b0_s1_wdata),

        .o_b1_s0_cen  (o_b1_s0_cen  ),
        .o_b1_s0_wen  (o_b1_s0_wen  ),
        .i_b1_s0_rdata(i_b1_s0_rdata),
        .o_b1_s0_addr (o_b1_s0_addr ),
        .o_b1_s0_wdata(o_b1_s0_wdata),

        .o_b1_s1_cen  (o_b1_s1_cen  ),
        .o_b1_s1_wen  (o_b1_s1_wen  ),
        .i_b1_s1_rdata(i_b1_s1_rdata),
        .o_b1_s1_addr (o_b1_s1_addr ),
        .o_b1_s1_wdata(o_b1_s1_wdata),

        .i_bank_sel   (bank_sel) 
    );

    // Alignment Registers for Outputs to SA Slices / External SRAM
    // Exactly matching the testbench pipelining
    logic                         push_data_last_d0, push_data_last_d1;
    logic                         push_en_d0, push_en_d1;
    logic [NPU_WT_ADDR_WIDTH-1:0] wt_rd_addr_d0;
    logic [`NUM_ARRAYS-1:0]       wt_rd_en_d0;
    logic                         push_act_data_ren_d0;
    logic [NPU_DATA_WIDTH-1:0]    push_act_data_d1;

    always_ff @(posedge i_clk or negedge i_rstn_async) begin
        if(!i_rstn_async) begin
            push_data_last_d0 <= '0;
            push_data_last_d1 <= '0;

            push_en_d0 <= '0;
            push_en_d1 <= '0;

            wt_rd_addr_d0 <= '0;
            wt_rd_en_d0   <= '0;

            push_act_data_ren_d0 <= '0;
            push_act_data_d1     <= '0;
        end else begin
            push_data_last_d0 <= push_data_last;
            push_data_last_d1 <= push_data_last_d0;

            push_en_d0 <= push_en;
            push_en_d1 <= push_en_d0;

            wt_rd_addr_d0 <= wt_sram_rd_addr;
            wt_rd_en_d0   <= wt_sram_rd_en;

            push_act_data_ren_d0 <= comp_ren;
            push_act_data_d1     <= push_act_data_ren_d0 ? comp_rdata : '0;
        end
    end

    // 1. Assigning Weight Read Signals to External Ports (from Overseer)
    assign o_wt_sram_rd_addr = wt_rd_addr_d0;
    assign o_wt_sram_rd_en   = wt_rd_en_d0;

    // 2. Assigning Weight Write Signals to External Ports (from MMU)
    assign o_wt_mem_wr_addr = wgt_addr;
    assign o_wt_mem_wr_data = wgt_wdata;

    // 3. Decoding MMU's 3-bit sram select to the WT_BANKS write enable array
    always_comb begin
        o_wt_mem_wr_en = '0;
        if (wgt_wen) begin
            o_wt_mem_wr_en[wgt_sram_sel] = 1'b1;
        end
    end

    //everything except 4 looks good.
    // 4. Align push_en and data with the SRAM pipeline 
    //enabled based on array_active for now
    always_comb begin
        for (int i = 0; i < `NUM_ARRAYS; i++) begin
            o_push_en[i] = push_en_d1 & array_active[i];
        end
    end
    
    assign o_push_act_data  = push_act_data_d1;             //to the systolic arrays. 
    assign o_push_data_last = push_data_last_d1;

endmodule