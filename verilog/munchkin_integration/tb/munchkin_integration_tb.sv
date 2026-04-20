`timescale 1 ns / 1 ps

`define HI 0
`define WI 1
`define HF 2
`define WF 3
`define HO 4
`define WO 5
`define CI 6
`define NUM_KERNELS 7
`define WORDS_NEEDED_FOR_CI 8
`define WORDS_NEEDED_FOR_CO 9
`define STRIDE 10
`define PADDING 11
`define MAXPOOL_EN 12
`define RELU_EN 13
`define SCALE_AMT 14
`define ACT_START_ADDR 15
`define ACT_END_ADDR 16
`define WT_START_ADDR 17
`define WT_END_ADDR 18
`define OUTPUT_START_ADDR 19
`define OUTPUT_END_ADDR 20

module munchkin_integration_tb;

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
    parameter CFG_ADDR              = 32'h1000_2000;
    parameter CFG_SIZE              = 32'h0000_0100;
    parameter CNN_ADDR              = 32'h2000_0000;

    parameter PSUM_WIDTH        = 32;
    parameter SHIFT_WIDTH       = 5;
    parameter INPUT_FIFO_DEPTH  = 16; 
    parameter INPUT_FIFO_AF_LVL = 5; // needs 4 pushes of headsup
    parameter OUTPUT_FIFO_DEPTH = 8; 

    //Clock & Reset
    // logic clk_sys, clk_sa;
    logic clk_sys;
    initial clk_sys = 0;
    always #`CLK_PERIOD_SYS_HALF clk_sys = ~clk_sys;

    // initial clk_sa = 0;
    // always #`CLK_PERIOD_SA_HALF clk_sa = ~clk_sa;
    logic [2:0] clk_sel;

    logic rstn_sync;
    logic rstn_async;

    //memory size
    localparam int MEM_SIZE_BYTES = 1 * 1024 * 1024; // 1MB
    localparam int MEM_WORDS      = MEM_SIZE_BYTES / 4;
    //define memory seperately for ease of testing
    logic [31:0] prgm_memory [0:MEM_WORDS-1];   // Contains addresses between 0x0000_0000-0x000f_ffff
    logic [31:0] cnn_memory [0:MEM_WORDS-1];    // Contains addresses between 0x2000_0000-0x200f_ffff
    logic [31:0] cnn_memory_clean [0:MEM_WORDS-1];    // Contains addresses between 0x2000_0000-0x200f_ffff
    logic [31:0] cfg_memory       [0:31]; // Contains the test configuration info for the cpu

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

    // SA Slice control signals
    logic                           cdc_req;
    logic [NUM_ARRAYS-1:0]          cdc_ack_arrays;
    logic                           relu_en;
    logic [SHIFT_WIDTH-1:0]         shift_by;
    logic                           maxpool_en;
    logic [NPU_WT_ADDR_WIDTH-1:0]   wt_rd_addr;
    logic [NUM_ARRAYS-1:0]          wt_rd_en;
    logic [NUM_ARRAYS-1:0]          array_active;

    // Input fifo interface
    logic [NPU_DATA_WIDTH-1:0]      push_act_data;
    logic                           push_data_last;
    logic [NUM_ARRAYS-1:0]          push_en;
    logic [NUM_ARRAYS-1:0]          push_af;

    // Output fifo Interface
    logic [NPU_DATA_WIDTH-1:0]      pop_data [NUM_ARRAYS-1:0];
    logic [NPU_DATA_WIDTH-1:0]      pop_data_mux;
    logic [NUM_ARRAYS-1:0]          pop_en;
    //logic [NUM_ARRAYS-1:0]          pop_empty;
    logic [NUM_ARRAYS-1:0]          pop_ae;
    logic [NUM_ARRAYS-1:0]          pop_full;

    // Weight sram writing
    logic [NUM_ARRAYS-1:0]          wt_sram_sel;
    logic [NPU_WT_ADDR_WIDTH-1:0]   wt_wr_addr;
    logic [NUM_ARRAYS-1:0]          wt_wr_en; 
    logic [NPU_DATA_WIDTH-1:0]      wt_wr_data;

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

    always_comb begin
        for(int array_i = 0; array_i < NUM_ARRAYS; array_i += 1) begin
            if(pop_en[array_i]) pop_data_mux = pop_data[array_i];
        end
    end

munchkin #(
    .CPU_ADDR_WIDTH    (CPU_ADDR_WIDTH),
    .CPU_DATA_WIDTH    (CPU_DATA_WIDTH),
    .NPU_ACT_ADDR_WIDTH(NPU_ACT_ADDR_WIDTH),
    .NPU_WT_ADDR_WIDTH (NPU_WT_ADDR_WIDTH),
    .NPU_DATA_WIDTH    (NPU_DATA_WIDTH),
    .DIM_WIDTH         (DIM_WIDTH),
    .MMIO_ADDR         (MMIO_ADDR),
    .MMIO_SIZE         (MMIO_SIZE)
) dut_munch (
    
    //this controller will have cpu, controller, mmu, axi_arbiter, comp_overseer/im2col_gen.
    //it will have ports that interface with mem_if, 8 SA slices, and abstracted off chip memory. 
    //so we need to think about the signals we need.
    .i_clk       (clk_sys),
    .o_clk_sel   (clk_sel),
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

    // ACT/OUTPUT SRAM interface - for the two banks and two ports.
    .o_b0_s0_cen  (b0_s0_cen   ),
    .o_b0_s0_wen  (b0_s0_wen   ),
    .i_b0_s0_rdata(b0_s0_rdata ), //we want this to be input so that this data could be fed into SA slice -> the input fifo.
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

    // Systolic array ports
    //   Top Slices
    //     Config
    .o_cdc_req   (cdc_req),
    .i_cdc_ack   (cdc_ack_arrays),
    .o_relu_en   (relu_en),
    .o_shift_by  (shift_by),
    .o_maxpool_en(maxpool_en),

    //     Input Fifos
    .o_push_act_data (push_act_data),
    .o_push_data_last(push_data_last),
    .o_push_en       (push_en),
    .i_push_af       (push_af),

    //      Weight SRAM ports
    .o_wt_sram_rd_addr(wt_rd_addr), 
    .o_wt_sram_rd_en  (wt_rd_en), 
    .o_wt_mem_wr_addr (wt_wr_addr), 
    .o_wt_mem_wr_data (wt_wr_data), 
    .o_wt_mem_wr_en   (wt_wr_en),
   
    // Output Fifo
    .i_pop_data         (pop_data_mux),
    .o_pop_en           (pop_en),
    // .i_pop_empty        (), 
    .i_pop_ae           (pop_ae),
    .i_pop_full         (pop_full)

);    

    genvar array_i;
    generate
        for (array_i = 0; array_i < NUM_ARRAYS; array_i = array_i + 1) begin : SYSTOLIC_ARRAYS
            sa_slice #(
                .PSUM_WIDTH         (PSUM_WIDTH),
                .SHIFT_WIDTH        (SHIFT_WIDTH),
                .WT_ADDR_WIDTH      (NPU_WT_ADDR_WIDTH),
                .WORD_SIZE          (NPU_DATA_WIDTH),
                .INPUT_FIFO_DEPTH   (INPUT_FIFO_DEPTH),
                .INPUT_FIFO_AF_LVL  (INPUT_FIFO_AF_LVL),
                .OUTPUT_FIFO_DEPTH  (OUTPUT_FIFO_DEPTH)
            ) dut_sa_slice (
                .i_clk_sys         (clk_sys),
                // .i_clk_sa          (clk_sa),
                .i_clk_sel         (clk_sel),
                .i_rst_n           (rstn_async),

                .i_cdc_req         (cdc_req),
                .o_cdc_ack         (cdc_ack_arrays[array_i]),
                .i_relu_en         (relu_en),
                .i_shift_by        (shift_by),
                .i_maxpool_en      (maxpool_en),

                .i_push_act_data   (push_act_data),
                .i_push_data_last  (push_data_last),
                .i_push_en         (push_en[array_i]),
                .o_push_af         (push_af[array_i]),
                .i_wt_sram_rd_addr (wt_rd_addr),
                .i_wt_sram_rd_en   (wt_rd_en[array_i]),

                .i_wt_sram_wr_addr (wt_wr_addr),
                .i_wt_sram_wr_en   (wt_wr_en[array_i]),
                .i_wt_sram_wr_data (wt_wr_data),

                .o_pop_data        (pop_data[array_i]),
                .i_pop_en          (pop_en[array_i]),
                .o_pop_empty       (),
                .o_pop_ae          (pop_ae[array_i]),
                .o_pop_full        (pop_full[array_i])

            );    
            initial begin
                $display("[%0t] SYN not defined, annotating clock gen only", $time);
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/Clock_Gen/IBM130/syn/clk_gen_mode.syn.sdf", dut_sa_slice.u_clk_gen);
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

    
    // `ifdef SYN
    // initial begin
    //     $display("[%0t] Applying SDF", $time);
    //     $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/picorv32/picorv32.syn.sdf", proc);
    //     $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/controller/controller.syn.sdf", controller_dut);
    //     $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/mmu/mmu.syn.sdf", mmu_dut);
    //     $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/axi/axi_arbiter.syn.sdf", arbiter_inst);
    //     $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/address_decoder/address_decoder.syn.sdf", addr_dec_dut);
    //     $display("[%0t] SDF annotation call finished", $time);
    // end
    // `else
    // initial begin
    //     $display("[%0t] SYN not defined, no SDF annotation", $time);
    // end
    // `endif
    
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

                // // mmio
                // (mem_addr >= MMIO_ADDR) && (mem_addr < MMIO_ADDR + MMIO_SIZE): begin
                //     if (|mem_wstrb) begin
                //         $write("MMIO ACCESS: @%h WR:%h\n", mem_addr, mem_wdata);
                //     end else begin
                //         $write("MMIO ACCESS: @%h RD\n", mem_addr);
                //     end
                    
                // end

                // cfg_addr
                (mem_addr >= CFG_ADDR) && (mem_addr < CFG_ADDR + CFG_SIZE): begin
                    adj_addr = mem_addr - CFG_ADDR;
                    if (!(|mem_wstrb)) begin
                        mem_rdata <= cfg_memory[adj_addr >> 2];
                    end else begin
                        $display("Just tried to write to cfg addr?");
                    end
                end


                // to the cnn memory
                (mem_addr >= CNN_ADDR): begin 
                    adj_addr = mem_addr - CNN_ADDR;
                    if (|mem_wstrb) begin
                        if (mem_wstrb[0]) cnn_memory[adj_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) cnn_memory[adj_addr >> 2][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) cnn_memory[adj_addr >> 2][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) cnn_memory[adj_addr >> 2][31:24] <= mem_wdata[31:24];
                    end else begin
                        mem_rdata <= cnn_memory[adj_addr >> 2];
                    end
                end

                default: $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
            endcase
        end
    end

    //file I/O and logger variables
    string program_memory_file;
    string cnn_memory_file;
    string cfg_file;
    string program_trace_file;
    string memory_access_file;
    integer trace_fd;
    integer mem_access_fd;
    integer cfg_fd;
    integer output_fd;
    integer retval;

    // Arg parsing and mem loading
    initial begin
        //dump for verdi
        $fsdbDumpfile("munchkin_integration_tb.fsdb");
        $fsdbDumpvars(0, munchkin_integration_tb);
        $fsdbDumpMDA();

        for (int j=0; j<MEM_WORDS; j++) prgm_memory[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) cnn_memory[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) cnn_memory_clean[j] = 0;
        for (int j=0; j<32; j++)        cfg_memory[j] = 0;
        
        //plusargs files
        if ($value$plusargs("PRGM_MEMORY=%s", program_memory_file)) begin
            $display("Loading main memory file: %s", program_memory_file);
        end else begin
            $display("Loading default memory file: program.mem");
            program_memory_file = "program.mem";
        end

        //plusargs files
        if ($value$plusargs("CNN_MEMORY=%s", cnn_memory_file)) begin
            $display("Loading cnn memory file: %s", cnn_memory_file);
        end else begin
            $display("Loading default cnn memory file: top_test.mem");
            cnn_memory_file = "top_test.mem";
        end
        
        //trace_file
        if ($value$plusargs("TRACE=%s", program_trace_file)) begin
            $display("Using trace output file: %s", program_trace_file);
        end else begin
            $display("Using default trace output file: trace.out");
            program_trace_file = "trace.out";
        end
        trace_fd = $fopen(program_trace_file, "w");
        
        //mem_access file
        if ($value$plusargs("MEMACCESS=%s", memory_access_file)) begin
            $display("Using memory access output file: %s", memory_access_file);
        end else begin
            $display("Using default memory access file: mem_access.out");
            memory_access_file = "mem_access.out";
        end
        mem_access_fd = $fopen(memory_access_file, "w");

        //config file
        if ($value$plusargs("CONFIG=%s", cfg_file)) begin
            $display("Using config output file: %s", cfg_file);
        end else begin
            $display("Using default config file: top_test.cfg");
            cfg_file = "top_test.cfg";
        end
        cfg_fd = $fopen(cfg_file, "r");

        // Load the mem files
        $readmemh(program_memory_file, prgm_memory);
        $readmemh(cnn_memory_file, cnn_memory_clean);
        $readmemh(cnn_memory_file, cnn_memory);

        // Load the cfg file
        retval = $fscanf(cfg_fd, "comp_Hi: %h", cfg_memory[`HI]);
        retval = $fscanf(cfg_fd, "comp_Wi: %h", cfg_memory[`WI]);
        retval = $fscanf(cfg_fd, "comp_Hf: %h", cfg_memory[`HF]);
        retval = $fscanf(cfg_fd, "comp_Wf: %h", cfg_memory[`WF]);
        retval = $fscanf(cfg_fd, "comp_Ho: %h", cfg_memory[`HO]);
        retval = $fscanf(cfg_fd, "comp_Wo: %h", cfg_memory[`WO]);
        retval = $fscanf(cfg_fd, "comp_Ci: %h", cfg_memory[`CI]);
        retval = $fscanf(cfg_fd, "comp_num_kernels: %h", cfg_memory[`NUM_KERNELS]);
        retval = $fscanf(cfg_fd, "words_needed_for_Ci: %h", cfg_memory[`WORDS_NEEDED_FOR_CI]);
        retval = $fscanf(cfg_fd, "words_needed_for_Co: %h", cfg_memory[`WORDS_NEEDED_FOR_CO]);
        retval = $fscanf(cfg_fd, "comp_stride: %b", cfg_memory[`STRIDE]);
        retval = $fscanf(cfg_fd, "comp_padding: %b", cfg_memory[`PADDING]);
        retval = $fscanf(cfg_fd, "comp_maxpool_en: %b", cfg_memory[`MAXPOOL_EN]);
        retval = $fscanf(cfg_fd, "comp_relu_en: %b", cfg_memory[`RELU_EN]);
        retval = $fscanf(cfg_fd, "comp_scale_amt: %b", cfg_memory[`SCALE_AMT]);
        retval = $fscanf(cfg_fd, "act_start_addr: %h", cfg_memory[`ACT_START_ADDR]);
        retval = $fscanf(cfg_fd, "act_end_addr: %h", cfg_memory[`ACT_END_ADDR]);
        retval = $fscanf(cfg_fd, "wt_start_addr: %h", cfg_memory[`WT_START_ADDR]);
        retval = $fscanf(cfg_fd, "wt_end_addr: %h", cfg_memory[`WT_END_ADDR]);
        retval = $fscanf(cfg_fd, "output_start_addr: %h", cfg_memory[`OUTPUT_START_ADDR]);
        retval = $fscanf(cfg_fd, "output_end_addr: %h", cfg_memory[`OUTPUT_END_ADDR]);

        // Clear the output portion of our dut cnn memory
        for (int j=(cfg_memory[`OUTPUT_START_ADDR] >> 2); j<(cfg_memory[`OUTPUT_END_ADDR] >> 2); j++) cnn_memory[j] = 0;
        $display("Act Start Line #: %d", cfg_memory[`ACT_START_ADDR]/4 + 1);
        $display("Wt Start Line #: %d", cfg_memory[`WT_START_ADDR]/4 + 1);
        $display("Output Start Line #: %d", cfg_memory[`OUTPUT_START_ADDR]/4 + 1);

        cfg_memory[`ACT_START_ADDR]     += CNN_ADDR;
        cfg_memory[`ACT_END_ADDR]       += CNN_ADDR;
        cfg_memory[`WT_START_ADDR]      += CNN_ADDR;
        cfg_memory[`WT_END_ADDR]        += CNN_ADDR;
        cfg_memory[`OUTPUT_START_ADDR]  += CNN_ADDR;
        cfg_memory[`OUTPUT_END_ADDR]    += CNN_ADDR;
        rstn_sync <= 0;
        rstn_async <= 0;
        repeat (100) @(posedge clk_sys);
        #1;
        rstn_sync <= 1;
        rstn_async <= 1;
    end

   
    // Flight Data Recorder (Trace)
    initial begin
        repeat (10) @(posedge clk_sys);
        while (!trap) begin
            @(posedge clk_sys);
            if (trace_valid)
                $fwrite(trace_fd, "%x\n", trace_data);
        end
        $fclose(trace_fd);
    end

    // Memory Access Logger
    initial begin
        repeat (10) @(posedge clk_sys);
        while (!trap) begin
            @(posedge clk_sys);
            if (mem_valid && mem_ready) begin
                if (|mem_wstrb) begin
                    $fwrite(mem_access_fd, "WRITE: Addr=%08x, Data=%08x, Strb=%b\n", mem_addr, mem_wdata, mem_wstrb);
                end else begin
                    $fwrite(mem_access_fd, "READ:  Addr=%08x, Data=%08x\n", mem_addr, mem_rdata);
                end
            end
        end
        $fclose(mem_access_fd);
    end

    int num_errors;

    always @(posedge clk_sys) begin
        if (rstn_sync && trap) begin
            $display("CPU TRAP HIT");
            $display("Checking memory...");
            output_fd = $fopen("top_test_dut.mem", "w");
            num_errors = 0;
            for(int word = 0; word < MEM_WORDS; word +=1 ) begin
                if(word < ((cfg_memory[`OUTPUT_END_ADDR] - CNN_ADDR) >> 2)) $fwrite(output_fd, "%h\n", cnn_memory[word]);
                if(cnn_memory[word] !== cnn_memory_clean[word]) begin
                    num_errors += 1;
                    $display("Mismatch @%h act: %h exp: %h", (word << 2) + CNN_ADDR, cnn_memory[word], cnn_memory_clean[word]);
    
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
        #50000000;
        $display("TIMEOUT ERROR: Simulation hung.");
        $finish;
    end


endmodule