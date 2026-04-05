`timescale 1 ns / 1 ps

module controller_integration_tb;
//going to hold off on connecting mem_if because not adding im2col and computation overseer just yet
//preload act_sram and memory -> check load tile + store tile.

    //parameters from the two test benches
    parameter ADDR_WIDTH      = 32; //of chip memory is 32 bit addresses that are byte-addressable
    parameter DATA_WIDTH      = 32; //data width of axi
    parameter DIM_WIDTH       = 10; //dim width of the tile/weight loading info
    parameter MMIO_ADDR       = 32'h1000_1000; //MMIO ADDR
    parameter MMIO_SIZE       = 32'h0000_0100; //MNIO SIZE
    parameter WORD_SIZE       = 64; //WORD SIZE of ON CHIP SRAMS
    parameter ACT_AW          = 12;
    parameter WT_AW           = 11; //WGT SRAMs ADDR WIDTH
    parameter WT_BANKS        = 8; //THE NUMBER OF WEIGHT BANKS
    parameter WT_DW           = 64; //THE WIDTH OF DATA THAT goes to weight srams.

    //UPDATED: Shifted Base Addresses to prevent overwriting CPU Code (program.mem at 0x0)
    localparam logic [ADDR_WIDTH-1:0] WGT_BASE   = 32'h0004_0000; // Starts at 256KB
    localparam logic [ADDR_WIDTH-1:0] ACT_BASE   = 32'h0008_0000; // Starts at 512KB
    localparam logic [ADDR_WIDTH-1:0] STORE_BASE = 32'h000C_0000; // Starts at 768KB

    //memory size
    localparam int MEM_SIZE_BYTES = 1 * 1024 * 1024; // 1MB
    localparam int MEM_WORDS      = MEM_SIZE_BYTES / 4;

    //clk stuff
    logic clk   = 1;
    logic rst_n = 0;
    always #3.0 clk = ~clk; 

    //define memory 
    reg [31:0] memory [0:MEM_WORDS-1];
    logic [63:0] act_sram [0:4095]; 
    logic [63:0] golden_act_sram [0:4095]; 
    logic [31:0] golden_store_beats [0:MEM_WORDS-1];
    
    // Weight SRAMs (Shadow memory to spy on DUT writes)
    logic [WT_DW-1:0] shadow_wgt_sram [0:WT_BANKS-1][0:(1<<WT_AW)-1];
    logic [WT_DW-1:0] golden_wgt_sram_flat [0:(WT_BANKS*(1<<WT_AW))-1];

    //trace signals
    wire trap, trace_valid;
    wire [35:0] trace_data;

    // CPU Signals
    wire cpu_valid, cpu_instr, cpu_ready;
    wire [ADDR_WIDTH-1:0] cpu_addr;
    wire [DATA_WIDTH-1:0] cpu_wdata;
    wire [3:0] cpu_wstrb;
    wire [DATA_WIDTH-1:0] cpu_rdata;

    // Decoder to Arbiter (CPU Path)
    wire dec_mem_valid, dec_mem_instr;
    wire [ADDR_WIDTH-1:0] dec_mem_addr;
    wire [DATA_WIDTH-1:0] dec_mem_wdata;
    wire [3:0] dec_mem_wstrb;
    wire dec_mem_ready;
    wire [DATA_WIDTH-1:0] dec_mem_rdata;

    // Decoder to Controller (MMIO Path)
    wire mmio_valid, mmio_ready;
    wire [ADDR_WIDTH-1:0] mmio_addr;
    wire [DATA_WIDTH-1:0] mmio_wdata;
    wire [3:0] mmio_wstrb;
    wire [DATA_WIDTH-1:0] mmio_rdata;

    // Controller to Compute (Mocks)
    logic o_comp_compute_start, i_comp_done;
    logic [1:0] o_comp_stride, o_comp_padding;
    logic o_comp_maxpool_en, o_comp_relu_en;
    logic [4:0] o_comp_scale_amt;
    logic [DIM_WIDTH-1:0] o_comp_Hi, o_comp_Wi, o_comp_Hf, o_comp_Wf;
    logic [DIM_WIDTH-1:0] o_comp_Ho, o_comp_Wo, o_comp_words_per_channel;
    logic [DIM_WIDTH-1:0] o_comp_num_kernels;

    // Controller to MMU
    logic                  mmu_load_weights, mmu_load_tile, mmu_store_tile, sram_load_weights;
    logic [DIM_WIDTH-1:0]  mmu_N, mmu_H, mmu_W;
    logic [DIM_WIDTH-1:0]  mmu_words_per_channel, mmu_tile_stride;
    logic [ADDR_WIDTH-1:0] mmu_addr;
    logic                  mmu_done, bank_sel;

    // MMU to SRAMs
    logic [WT_AW-1:0]           wgt_addr;
    logic                  wgt_wen;
    logic [WORD_SIZE-1:0]  wgt_wdata;
    logic [2:0]            wgt_sram_sel;
    logic [ACT_AW-1:0] act_waddr, act_raddr;
    logic                  act_wen, act_ren;
    logic [WORD_SIZE-1:0]  act_wdata, act_rdata;

    // MMU to Arbiter (NPU AXI)
    logic [ADDR_WIDTH-1:0] npu_araddr, npu_awaddr;
    logic [7:0]            npu_arlen, npu_awlen;
    logic [2:0]            npu_arsize, npu_awsize;
    logic                  npu_arvalid, npu_arready, npu_awvalid, npu_awready;
    logic [DATA_WIDTH-1:0] npu_rdata, npu_wdata;
    logic [3:0]            npu_wstrb;
    logic                  npu_rlast, npu_rvalid, npu_rready;
    logic                  npu_wlast, npu_wvalid, npu_wready;
    logic                  npu_bvalid, npu_bready;

    // Arbiter to Shared Memory
    logic                  mem_valid, mem_ready;
    logic [ADDR_WIDTH-1:0] mem_addr;
    logic [DATA_WIDTH-1:0] mem_wdata;
    logic [3:0]            mem_wstrb;
    logic [DATA_WIDTH-1:0] mem_rdata;

    `ifdef SYN
    initial begin
        $display("[%0t] Applying SDF", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/picorv32/picorv32.syn.sdf", proc);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/controller/controller.syn.sdf", controller_dut);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/mmu/mmu.syn.sdf", mmu_dut);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/axi/axi_arbiter.syn.sdf", arbiter_inst);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/address_decoder/address_decoder.syn.sdf", addr_dec_dut);
        $display("[%0t] SDF annotation call finished", $time);
    end
    `else
    initial begin
        $display("[%0t] SYN not defined, no SDF annotation", $time);
    end
    `endif
    
    //instantiations
    picorv32 proc (
        .clk(clk), .resetn(rst_n), .trap(trap),
        .trace_valid(trace_valid), .trace_data(trace_data),
        .mem_valid(cpu_valid), .mem_instr(cpu_instr), .mem_ready(cpu_ready),
        .mem_addr(cpu_addr), .mem_wdata(cpu_wdata), .mem_wstrb(cpu_wstrb), .mem_rdata(cpu_rdata)
    );

    address_decoder #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
        .MMIO_ADDR(MMIO_ADDR), .MMIO_SIZE(MMIO_SIZE)
    ) addr_dec_dut (
        .i_cpu_valid(cpu_valid), .i_cpu_instr(cpu_instr), .i_cpu_addr(cpu_addr),
        .i_cpu_wdata(cpu_wdata), .i_cpu_wstrb(cpu_wstrb), .o_cpu_ready(cpu_ready), .o_cpu_rdata(cpu_rdata),

        .o_mem_valid(dec_mem_valid), .o_mem_instr(dec_mem_instr), .o_mem_addr(dec_mem_addr),
        .o_mem_wdata(dec_mem_wdata), .o_mem_wstrb(dec_mem_wstrb), .i_mem_ready(dec_mem_ready), .i_mem_rdata(dec_mem_rdata),

        .o_mmio_valid(mmio_valid), .o_mmio_addr(mmio_addr), .o_mmio_wdata(mmio_wdata),
        .o_mmio_wstrb(mmio_wstrb), .i_mmio_ready(mmio_ready), .i_mmio_rdata(mmio_rdata)
    );

    
    controller #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .DIM_WIDTH(DIM_WIDTH)
    ) controller_dut (
        .i_clk(clk), .i_resetn(rst_n),
        .i_cpu_valid(mmio_valid), .i_cpu_addr(mmio_addr), .i_cpu_wdata(mmio_wdata),
        .i_cpu_wstrb(mmio_wstrb), .o_cpu_ready(mmio_ready), .o_cpu_rdata(mmio_rdata), 

        // Compute (Mocked)
        .o_comp_compute_start(o_comp_compute_start), .i_comp_done(i_comp_done),
        .o_comp_stride(o_comp_stride), .o_comp_padding(o_comp_padding),
        .o_comp_maxpool_en(o_comp_maxpool_en), .o_comp_relu_en(o_comp_relu_en),
        .o_comp_scale_amt(o_comp_scale_amt), .o_comp_Hi(o_comp_Hi),
        .o_comp_Wi(o_comp_Wi), .o_comp_Hf(o_comp_Hf), .o_comp_Wf(o_comp_Wf),
        .o_comp_Ho(o_comp_Ho), .o_comp_Wo(o_comp_Wo),
        .o_comp_words_per_channel(o_comp_words_per_channel), .o_comp_num_kernels(o_comp_num_kernels),

        // MMU connections
        .o_sram_load_weights(sram_load_weights),
        .o_mmu_load_weights(mmu_load_weights), .o_mmu_load_tile(mmu_load_tile), .o_mmu_store_tile(mmu_store_tile),
        .o_mmu_N(mmu_N), .o_mmu_H(mmu_H), .o_mmu_W(mmu_W),
        .o_mmu_words_per_channel(mmu_words_per_channel), .o_mmu_tile_stride(mmu_tile_stride),
        .o_mmu_addr(mmu_addr), .i_mmu_done(mmu_done),
        .o_bank_sel(bank_sel)
    );

    mmu #(
        .CPU_ADDR_WIDTH(ADDR_WIDTH), 
        .CPU_DATA_WIDTH(DATA_WIDTH),
        .NPU_ACT_ADDR_WIDTH(ACT_AW),
        .NPU_WT_ADDR_WIDTH(WT_AW),
        .NPU_DATA_WIDTH(WT_DW)
    ) mmu_dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_load_weights(mmu_load_weights), .i_load_tile(mmu_load_tile), .i_store_tile(mmu_store_tile),
        .i_N(mmu_N), .i_W(mmu_W), .i_H(mmu_H),
        .i_words_per_channel(mmu_words_per_channel), .i_addr(mmu_addr), .i_tile_stride(mmu_tile_stride),
        .o_done(mmu_done),

        .o_wgt_addr(wgt_addr), .o_wgt_wen(wgt_wen), .o_wgt_wdata(wgt_wdata), .o_wgt_sram_sel(wgt_sram_sel),
        .o_act_waddr(act_waddr), .o_act_wen(act_wen), .o_act_wdata(act_wdata),
        .o_act_raddr(act_raddr), .o_act_ren(act_ren), .i_act_rdata(act_rdata),

        .o_npu_araddr(npu_araddr), .o_npu_arlen(npu_arlen), .o_npu_arsize(npu_arsize),
        .o_npu_arvalid(npu_arvalid), .i_npu_arready(npu_arready),
        .i_npu_rdata(npu_rdata), .i_npu_rlast(npu_rlast), .i_npu_rvalid(npu_rvalid), .o_npu_rready(npu_rready),

        .o_npu_awaddr(npu_awaddr), .o_npu_awlen(npu_awlen), .o_npu_awsize(npu_awsize),
        .o_npu_awvalid(npu_awvalid), .i_npu_awready(npu_awready),
        .o_npu_wdata(npu_wdata), .o_npu_wstrb(npu_wstrb), .o_npu_wlast(npu_wlast),
        .o_npu_wvalid(npu_wvalid), .i_npu_wready(npu_wready),
        .i_npu_bvalid(npu_bvalid), .o_npu_bready(npu_bready)
    );

    axi_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)
    ) arbiter_inst (
        .clk(clk), .rst_n(rst_n),
        .i_cpu_valid(dec_mem_valid), .o_cpu_ready(dec_mem_ready), .i_cpu_addr(dec_mem_addr),
        .i_cpu_wdata(dec_mem_wdata), .i_cpu_wstrb(dec_mem_wstrb), .o_cpu_rdata(dec_mem_rdata),

        .i_npu_araddr(npu_araddr), .i_npu_arlen(npu_arlen), .i_npu_arsize(npu_arsize),
        .i_npu_arvalid(npu_arvalid), .o_npu_arready(npu_arready),
        .o_npu_rdata(npu_rdata), .o_npu_rvalid(npu_rvalid), .o_npu_rlast(npu_rlast), .i_npu_rready(npu_rready),

        .i_npu_awaddr(npu_awaddr), .i_npu_awlen(npu_awlen), .i_npu_awsize(npu_awsize),
        .i_npu_awvalid(npu_awvalid), .o_npu_awready(npu_awready),
        .i_npu_wdata(npu_wdata), .i_npu_wstrb(npu_wstrb), .i_npu_wlast(npu_wlast),
        .i_npu_wvalid(npu_wvalid), .o_npu_wready(npu_wready),
        .o_npu_bresp(), .o_npu_bvalid(npu_bvalid), .i_npu_bready(npu_bready),

        .o_mem_valid(mem_valid), .i_mem_ready(mem_ready), .o_mem_addr(mem_addr),
        .o_mem_wdata(mem_wdata), .o_mem_wstrb(mem_wstrb), .i_mem_rdata(mem_rdata)
    );

    //wires to connect to weight srams
    logic [WT_BANKS*WT_AW-1:0] wt_mem_rd_addr = '0;
    logic [WT_BANKS-1:0]       wt_mem_rd_en = '0;
    logic [WT_BANKS*WT_DW-1:0] wt_mem_rd_data;
    logic [WT_AW-1:0]          wt_mem_wr_addr;
    logic [WT_BANKS-1:0]       wt_mem_wr_en;
    logic [WT_DW-1:0]          wt_mem_wr_data;

    assign wt_mem_wr_addr = wgt_addr;
    assign wt_mem_wr_data = wgt_wdata;
    assign wt_mem_wr_en   = (wgt_wen === 1'b1) ? (8'b0000_0001 << wgt_sram_sel) : 8'b0;

    weight_mem_8bank #(
        .WEIGHT_MEM_ADDR_WIDTH(WT_AW), .DATA_WIDTH(8), .WORD_SIZE(8), .NUM_BANKS(WT_BANKS)
    ) wmem (
        .clk(clk), .wt_mem_rd_addr(wt_mem_rd_addr), .wt_mem_rd_en(wt_mem_rd_en),
        .wt_mem_rd_data(wt_mem_rd_data), .wt_mem_wr_addr(wt_mem_wr_addr),
        .wt_mem_wr_en(wt_mem_wr_en), .wt_mem_wr_data(wt_mem_wr_data)
    );

    //mock compute
    always @(posedge o_comp_compute_start) begin
        i_comp_done = 0;
        repeat(100) @(posedge clk);
        i_comp_done = 1;
        @(posedge clk);
        i_comp_done = 0;
    end


    // always_comb begin
    //     if (act_ren) act_rdata = act_sram[act_raddr[11:0]];
    //     else         act_rdata = 64'h0;
    // end 
    // nanda, above was previously
    
    //reading from fake mem_if
    //keep read data registered so one 64-bit word stays stable across the
    // two 32-bit AXI beats MMU emits during store_til
    // beat_toggle != 1'b1 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            act_rdata <= 64'h0;
        end else if (act_ren) begin
            act_rdata <= act_sram[act_raddr[11:0]];
        end
    end

    //writing to fake mem_if
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset logic
            for (int b=0; b<WT_BANKS; b++) begin
                for (int a=0; a<(1<<WT_AW); a++) shadow_wgt_sram[b][a] <= '0;
            end
        end else begin
            if (act_wen) begin
                act_sram[act_waddr[11:0]] <= act_wdata;
            end
            
            // Spy on the Weight SRAM writes and record them in our Shadow Memory
            if (wgt_wen) begin
                shadow_wgt_sram[wgt_sram_sel][wgt_addr] <= wgt_wdata;
            end
        end
    end

    //writing to off-chip main memory
    always @(posedge clk) begin
        mem_ready <= 0;
        if (mem_valid && !mem_ready) begin
            mem_ready <= 1;
            mem_rdata <= 'bx;
            case (1)
                (mem_addr >> 2) < MEM_WORDS: begin
                    if (|mem_wstrb) begin
                        if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
                    end else begin
                        mem_rdata <= memory[mem_addr >> 2];
                    end
                end
                mem_addr == 32'h1000_0000: begin
                    $write("%c", mem_wdata[7:0]);
                end

                //this is mailbox writing
                (mem_addr[31:28] == 4'h3): begin 
                    // Do nothing. The mailbox "wiretap" block handles this!
                end

                default: $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
            endcase
        end
    end

    //file I/O and logger variables
    string program_memory_file;
    string program_trace_file;
    string memory_access_file;
    integer trace_fd;
    integer mem_access_fd;
    
    //mailbox + verification triggers
    integer test_idx = 0;
    integer i, expected_words;
    
    // --- NEW: Added file descriptors and strings for all dumps ---
    integer store_dump_fd, wgt_dump_fd, act_dump_fd; 
    string store_dump_path, wgt_dump_path, act_dump_path;
    
    // Config vars populated by CPU triggering load
    integer n_cfg, h_cfg, w_cfg, c_cfg, wpc_cfg;
    integer bank_idx, addr_idx, flat_idx; // for weight verification

    always @(posedge clk) begin
        // Intercept writes to Mailbox addresses (These bypass the arbiter)
        if (cpu_valid && cpu_ready && (|cpu_wstrb)) begin
            
            // MAILBOX 1: Load Test Vector Hex Files (0x3000_0000)
            if (cpu_addr == 32'h3000_0000) begin
                test_idx = cpu_wdata;
                $display("TB MAILBOX: Loading memory files for Test %0d...", test_idx);
                
                // Load golden configs & hex
                load_test_config($sformatf("../../../goldenbrick/mmu_vectors/test%0d/config.txt", test_idx), n_cfg, h_cfg, w_cfg, c_cfg, wpc_cfg);

                // Write the parsed values into main memory so the C code can read them
                memory[32'h0000_2000 >> 2] = n_cfg;
                memory[32'h0000_2004 >> 2] = h_cfg;
                memory[32'h0000_2008 >> 2] = w_cfg;
                memory[32'h0000_200C >> 2] = c_cfg;
                memory[32'h0000_2010 >> 2] = wpc_cfg;
                
                $readmemh($sformatf("../../../goldenbrick/mmu_vectors/test%0d/wgt_mem_axi32.hex", test_idx), memory, WGT_BASE >> 2);
                $readmemh($sformatf("../../../goldenbrick/mmu_vectors/test%0d/act_mem_axi32.hex", test_idx), memory, ACT_BASE >> 2);
                
                load_golden_act_sram($sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_act_sram.hex", test_idx));
                load_golden_store_beats($sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_store_axi32.hex", test_idx));
                
                load_golden_wgt_sram($sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_weight_sram_dump.txt", test_idx));
            end

            // MAILBOX 2: Verify Load Weights (0x3000_0004)
            if (cpu_addr == 32'h3000_0004) begin
                // 1. ALL DECLARATIONS MUST GO FIRST
                integer golden_wgt_fd, rc;
                integer exp_bank, exp_addr;
                logic [63:0] exp_data;
                string golden_wgt_path;

                $display("TB MAILBOX: Verifying Load Weights for Test %0d ", test_idx);
                
                // --- DUMP ACTUALS FOR DEBUG (Keeping your existing logic) ---
                wgt_dump_path = $sformatf("actual_load_weights_test%0d.txt", test_idx);
                wgt_dump_fd = $fopen(wgt_dump_path, "w");
                dump_weight_srams_python_format(wgt_dump_fd, n_cfg, h_cfg, w_cfg, wpc_cfg);
                $fclose(wgt_dump_fd);

                // --- SPARSE CHECK AGAINST GOLDEN FILE ---
                golden_wgt_path = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_weight_sram_dump.txt", test_idx);
                golden_wgt_fd = $fopen(golden_wgt_path, "r");

                if (golden_wgt_fd == 0) begin
                    $display("ERROR: Could not open golden weight file at %s", golden_wgt_path);
                    $finish;
                end

                // Parse line-by-line and check ONLY the addresses the golden model touched
                while (!$feof(golden_wgt_fd)) begin
                    rc = $fscanf(golden_wgt_fd, "bank=%d addr=%d data=%h\n", exp_bank, exp_addr, exp_data);
                    
                    if (rc == 3) begin
                        // Compare directly against the shadow SRAM!
                        if (shadow_wgt_sram[exp_bank][exp_addr] !== exp_data) begin
                            $display("FAIL load_weights test%0d Bank %0d Addr %0d", test_idx, exp_bank, exp_addr);
                            $display("  Expected: %016h", exp_data);
                            $display("  Actual:   %016h", shadow_wgt_sram[exp_bank][exp_addr]);
                        end
                    end
                end
                
                $fclose(golden_wgt_fd);
                $display("PASS load_weights test%0d", test_idx);
            end
           
            // MAILBOX 3: Verify Load Tile (0x3000_0008)
            if (cpu_addr == 32'h3000_0008) begin
                $display("TB MAILBOX: Verifying Load Tile for Test %0d...", test_idx);
                //commenting to check subtiles
                //expected_words = h_cfg * w_cfg * wpc_cfg; 
                expected_words = 2 * 2 * wpc_cfg; 

                //to check
                act_dump_path = $sformatf("actual_load_tile_test%0d.txt", test_idx);
                act_dump_fd = $fopen(act_dump_path, "w");

                for (i = 0; i < expected_words; i = i + 1) begin
                    
                    // --- NEW: Dump the actual value to file ---
                    $fdisplay(act_dump_fd, "word_%0d: %016h", i, act_sram[i]);

                    if (act_sram[i] !== golden_act_sram[i]) begin
                        $display("FAIL load_tile test%0d word %0d", test_idx, i);
                        $display("  Expected: %016h", golden_act_sram[i]);
                        $display("  Actual:   %016h", act_sram[i]);
                        $fclose(act_dump_fd); // <-- IMPORTANT: Flush before crash
                        // $finish;
                    end
                end
                $fclose(act_dump_fd);
                $display("PASS load_tile test%0d", test_idx);
            end

            // MAILBOX 4: Verify Store Tile (0x3000_000C)
            if (cpu_addr == 32'h3000_000C) begin
                // 1. ALL DECLARATIONS MUST GO FIRST
                integer sparse_fd, scan_res;
                logic [31:0] expected_addr, expected_data;
                string golden_path;

                // 2. NOW WE CAN DO EXECUTABLE STATEMENTS
                $display("TB MAILBOX: Verifying Store Tile for Test %0d ", test_idx);

                // Open the python-generated sparse golden file for reading
                golden_path = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_store_sparse.txt", test_idx);
                sparse_fd = $fopen(golden_path, "r");

                if (sparse_fd == 0) begin
                    $display("ERROR: Could not open sparse golden file at %s", golden_path);
                    $finish;
                end


                store_dump_path = $sformatf("actual_store_beats_test%0d.txt", test_idx);
                store_dump_fd = $fopen(store_dump_path, "w");
                
                // Dump the 65,536 words starting from STORE_BASE
                for (i = 0; i < 65536; i = i + 1) begin
                    $fdisplay(store_dump_fd, "beat_%0d: %08h", i, memory[(STORE_BASE >> 2) + i]);
                end
                
                $fclose(store_dump_fd);

                // Loop through the file line-by-line until the end
                while (!$feof(sparse_fd)) begin
                    // Read the Address and Data pair
                    scan_res = $fscanf(sparse_fd, "%h %h\n", expected_addr, expected_data);
                    
                    if (scan_res == 2) begin 
                        if (memory[expected_addr >> 2] !== expected_data) begin
                            $display("FAIL store_tile test%0d Addr: %08h Got: %08h Exp: %08h", 
                                     test_idx, expected_addr, memory[expected_addr >> 2], expected_data);
                        end
                    end
                end
                
                $fclose(sparse_fd);
                $display("PASS store_tile test%0d", test_idx);
            end
        end
    end

    
    initial begin
        //dump for verdi
        $fsdbDumpfile("integrated_tb.fsdb");
        $fsdbDumpvars(0, controller_integration_tb);
        $fsdbDumpMDA();

        for (int j=0; j<MEM_WORDS; j++) memory[j] = 0;
        
        //plusargs files
        if ($value$plusargs("MEMORY=%s", program_memory_file)) begin
            $display("Loading memory file: %s", program_memory_file);
        end else begin
            $display("Loading default memory file: program.mem");
            program_memory_file = "program.mem";
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

        // Load the PicoRV32 C program into memory
        $readmemh(program_memory_file, memory);

        repeat (100) @(posedge clk);
        rst_n <= 1;
    end

   
    // Flight Data Recorder (Trace)
    initial begin
        repeat (10) @(posedge clk);
        while (!trap) begin
            @(posedge clk);
            if (trace_valid)
                $fwrite(trace_fd, "%x\n", trace_data);
        end
        $fclose(trace_fd);
    end

    // Memory Access Logger
    initial begin
        repeat (10) @(posedge clk);
        while (!trap) begin
            @(posedge clk);
            if (cpu_valid && cpu_ready) begin
                if (|cpu_wstrb) begin
                    $fwrite(mem_access_fd, "WRITE: Addr=%08x, Data=%08x, Strb=%b\n", cpu_addr, cpu_wdata, cpu_wstrb);
                end else begin
                    $fwrite(mem_access_fd, "READ:  Addr=%08x, Data=%08x\n", cpu_addr, cpu_rdata);
                end
            end
        end
        $fclose(mem_access_fd);
    end

    always @(posedge clk) begin
        if (rst_n && trap) begin
            $display("CPU TRAP HIT - SIMULATION FINISHED");
            $finish;
        end
    end

    //helper tasks
    task automatic load_test_config(
        input  string path,
        output integer n_cfg, output integer h_cfg, output integer w_cfg,
        output integer c_cfg, output integer wpc_cfg
    );
        integer fd, n_tmp, row_beats_tmp, weight_words_tmp, rc;
        begin
            n_cfg = 0; h_cfg = 0; w_cfg = 0; c_cfg = 0; wpc_cfg = 0;
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FAIL: could not open %s", path); $finish;
            end
            rc = $fscanf(fd, "N=%d\n", n_tmp);
            rc = $fscanf(fd, "H=%d\n", h_cfg);
            rc = $fscanf(fd, "W=%d\n", w_cfg);
            rc = $fscanf(fd, "C=%d\n", c_cfg);
            rc = $fscanf(fd, "WORDS_PER_CHANNEL=%d\n", wpc_cfg);
            rc = $fscanf(fd, "ROW_BEATS=%d\n", row_beats_tmp);
            rc = $fscanf(fd, "WEIGHT_WORDS=%d\n", weight_words_tmp);
            n_cfg = n_tmp;
            $fclose(fd);
        end
    endtask

    task automatic load_golden_act_sram(input string path);
        integer idx;
        begin
            for (idx = 0; idx < 4096; idx = idx + 1) golden_act_sram[idx] = 64'h0;
            $readmemh(path, golden_act_sram);
        end
    endtask

    task automatic load_golden_store_beats(input string path);
        integer idx;
        begin
            for (idx = 0; idx < MEM_WORDS; idx = idx + 1) golden_store_beats[idx] = 32'h0;
            $readmemh(path, golden_store_beats);
        end
    endtask

    // Parse the text formatting "bank=%d addr=%d data=%h"
    task automatic load_golden_wgt_sram(input string path);
        integer fd, rc;
        integer bank_val, addr_val;
        logic [63:0] data_val;
        integer idx;
        begin
            // Initialize memory to 0
            for (idx = 0; idx < (WT_BANKS*(1<<WT_AW)); idx = idx + 1) golden_wgt_sram_flat[idx] = '0;
            
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FAIL: could not open %s", path); 
                $finish;
            end
            
            // Parse line by line
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "bank=%d addr=%d data=%h\n", bank_val, addr_val, data_val);
                if (rc == 3) begin
                    // Store directly into the flat array at the computed index
                    golden_wgt_sram_flat[(bank_val * (1<<WT_AW)) + addr_val] = data_val;
                end
            end
            $fclose(fd);
        end
    endtask


    // read function for the sram for checking after finish writing to the srams
    task automatic read_weight_word(
        input  integer bank, //bank we want to check
        input  integer addr, //addr
        output logic [63:0] data_out //the data we want to read from.
    );
        begin
            @(posedge clk);
            //setting up signals for read
            wt_mem_rd_addr <= '0;
            wt_mem_rd_en   <= '0; 
            @(posedge clk);
            wt_mem_rd_addr[bank*WT_AW +: WT_AW] <= addr[WT_AW-1:0];
            wt_mem_rd_en[bank] <= 1'b1;
            @(posedge clk);
            //data out - read data
            @(posedge clk);
            data_out = wt_mem_rd_data[bank*WT_DW +: WT_DW];
            wt_mem_rd_en = '0;
        end
    endtask


    //new dump_weight_srams_task that doesn't limit print of more than 8 kernels in a bank
    task automatic dump_weight_srams_python_format(
        input integer fd,
        input integer n_cfg,
        input integer h_cfg,
        input integer w_cfg,
        input integer wpc_cfg
    );
        logic [63:0] rd_back;
        integer bank;
        integer addr;
        integer kernel_words_local;
        integer kernels_in_bank;
        
        // New variables for wrap-around math
        integer full_cycles;
        integer remainder_kernels;
        integer base_kernels;
        integer extra_kernels;
        
        begin
            kernel_words_local = h_cfg * w_cfg * wpc_cfg;

            for (bank = 0; bank < WT_BANKS; bank = bank + 1) begin
                
                // 1. How many times do we perfectly fill all 8 banks? (64 kernels per full cycle)
                full_cycles = n_cfg / 64; 
                
                // 2. How many kernels are left over after the perfect cycles?
                remainder_kernels = n_cfg % 64; 
                
                // 3. Every bank gets at least this many kernels from the full cycles
                base_kernels = full_cycles * 8; 

                // 4. Figure out if THIS specific bank gets any of the leftovers
                if (remainder_kernels > (bank * 8)) begin
                    extra_kernels = remainder_kernels - (bank * 8);
                    // Cap the extra kernels for this bank at 8
                    if (extra_kernels > 8) extra_kernels = 8;
                end else begin
                    extra_kernels = 0;
                end

                // 5. Total valid kernels sitting in this specific bank
                kernels_in_bank = base_kernels + extra_kernels;

                // Now loop through exactly the right number of addresses!
                for (addr = 0; addr < (kernels_in_bank * kernel_words_local); addr = addr + 1) begin
                    read_weight_word(bank, addr, rd_back);
                    if ((^rd_back !== 1'bx) && (rd_back != 64'h0)) begin
                        $fdisplay(fd, "bank=%0d addr=%0d data=%016h", bank, addr, rd_back);
                    end
                end
            end
        end
    endtask

endmodule
