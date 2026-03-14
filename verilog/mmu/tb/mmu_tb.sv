module mmu_tb;
    //this is relevant to axi
    parameter ADDR_WIDTH      = 32;
    parameter DATA_WIDTH      = 32;

    //this is the word size -> output into on-chip srams.
    parameter WORD_SIZE       = 64;

    //the write address
    parameter WT_AW           = 11;

    //the number of banks for sram select
    parameter WT_BANKS        = 8;

    //weight data width -> used to check on chip srams (8 srams)
    parameter WT_DW           = 64;

    //not being used/misleading
    // localparam int N_CFG      = 64;
    // localparam int H_CFG      = 16;
    // localparam int W_CFG      = 16;
    // localparam int CWORD_CFG  = 1;

    logic clk   = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;
    logic wmem_clk;// why do these timing violations exists
    assign #1 wmem_clk = clk;
    integer act_write_count;

    logic [63:0] act_sram [0:4095]; //the activation on chip sram (load tile data into), read tile data from and send to off chip memory
    logic [63:0] golden_act_sram [0:4095]; //this is the golden activation on chip sram to check data.
    logic [31:0] golden_store_beats [0:8191]; //goldenbrick output used to check store tile?
    // for (int i = 0; i < 4096; i = i + 1) act_sram[i] = 64'h0;

    //activation data base addr.
    localparam logic [ADDR_WIDTH-1:0] ACT_BASE = 32'h0000_1000;


    logic                   i_load_weights;
    logic                   i_load_tile;
    logic                   i_store_tile;
    logic [9:0]             i_N, i_W, i_H;
    logic [9:0]             i_words_per_channel;
    logic [ADDR_WIDTH-1:0]  i_addr;
    logic [9:0]             i_tile_stride;
    logic                   o_done;
    logic [10:0]            o_wgt_addr;
    logic                   o_wgt_wen;
    logic [WORD_SIZE-1:0]   o_wgt_wdata;
    logic [2:0]             o_wgt_sram_sel;
    logic [ADDR_WIDTH-1:0]  o_act_waddr;
    logic                   o_act_wen;
    logic [WORD_SIZE-1:0]   o_act_wdata;
    logic [ADDR_WIDTH-1:0]  o_act_raddr;
    logic                  o_act_ren;
    logic [WORD_SIZE-1:0]  i_act_rdata;
    logic [ADDR_WIDTH-1:0] o_npu_araddr;
    logic [7:0]            o_npu_arlen;
    logic [2:0]            o_npu_arsize;
    logic                  o_npu_arvalid;
    logic                  i_npu_arready;
    logic [DATA_WIDTH-1:0] i_npu_rdata;
    logic                  i_npu_rlast;
    logic                  i_npu_rvalid;
    logic                  o_npu_rready;
    logic [ADDR_WIDTH-1:0] o_npu_awaddr;
    logic [7:0]            o_npu_awlen;
    logic [2:0]            o_npu_awsize;
    logic                  o_npu_awvalid;
    logic                  i_npu_awready;
    logic [DATA_WIDTH-1:0] o_npu_wdata;
    logic [3:0]            o_npu_wstrb;
    logic                  o_npu_wlast;
    logic                  o_npu_wvalid;
    logic                  i_npu_wready;
    logic                  i_npu_bvalid;
    logic                  o_npu_bready;


    logic                  mem_valid;
    logic                  mem_ready;
    logic [ADDR_WIDTH-1:0] mem_addr;
    logic [DATA_WIDTH-1:0] mem_wdata;
    logic [3:0]            mem_wstrb;
    logic [DATA_WIDTH-1:0] mem_rdata;


    // Real weight SRAM wrapper
    logic [WT_BANKS*WT_AW-1:0] wt_mem_rd_addr;
    logic [WT_BANKS-1:0]       wt_mem_rd_en;
    logic [WT_BANKS*WT_DW-1:0] wt_mem_rd_data;
    logic [WT_AW-1:0]          wt_mem_wr_addr;
    logic [WT_BANKS-1:0]       wt_mem_wr_en;
    logic [WT_DW-1:0]          wt_mem_wr_data;

    assign wt_mem_wr_addr = o_wgt_addr;
    assign wt_mem_wr_data = o_wgt_wdata;
    assign wt_mem_wr_en   = (o_wgt_wen === 1'b1) ? (8'b0000_0001 << o_wgt_sram_sel) : 8'b0; //moves the write enable to the correct sram.

    localparam logic [ADDR_WIDTH-1:0] WGT_BASE = 32'h0000_0000; //base address of the off-chip memory weights 
    localparam logic [ADDR_WIDTH-1:0] STORE_BASE = 32'h0000_2000; //based address of the stores to off-chip memory
 
    // Scoreboard state
    integer errors; //counts the number of errors from goldenbrick
    integer write_count; //the number of writes done - used for debugging purposes
    integer timeout_count; //timed_out - used for debugging to check if deadlock
    logic   done_seen; //checks if done is set.

    mmu #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .WORD_SIZE(WORD_SIZE) //is 64 bits
    ) mmu_dut (
        .i_clk(clk),
        .i_rst_n(rst_n),

        .i_load_weights(i_load_weights),
        .i_load_tile(i_load_tile),
        .i_store_tile(i_store_tile),

        .i_N(i_N),
        .i_W(i_W),
        .i_H(i_H),
        .i_words_per_channel(i_words_per_channel),
        .i_addr(i_addr),
        .i_tile_stride(i_tile_stride),

        .o_done(o_done),
        .o_wgt_addr(o_wgt_addr),
        .o_wgt_wen(o_wgt_wen),
        .o_wgt_wdata(o_wgt_wdata),
        .o_wgt_sram_sel(o_wgt_sram_sel),

        .o_act_waddr(o_act_waddr),
        .o_act_wen(o_act_wen),
        .o_act_wdata(o_act_wdata),
        .o_act_raddr(o_act_raddr),
        .o_act_ren(o_act_ren),
        .i_act_rdata(i_act_rdata),

        .o_npu_araddr(o_npu_araddr),
        .o_npu_arlen(o_npu_arlen),
        .o_npu_arsize(o_npu_arsize),
        .o_npu_arvalid(o_npu_arvalid),
        .i_npu_arready(i_npu_arready),
        .i_npu_rdata(i_npu_rdata),
        .i_npu_rlast(i_npu_rlast),
        .i_npu_rvalid(i_npu_rvalid),
        .o_npu_rready(o_npu_rready),

        .o_npu_awaddr(o_npu_awaddr),
        .o_npu_awlen(o_npu_awlen),
        .o_npu_awsize(o_npu_awsize),
        .o_npu_awvalid(o_npu_awvalid),
        .i_npu_awready(i_npu_awready),
        .o_npu_wdata(o_npu_wdata),
        .o_npu_wstrb(o_npu_wstrb),
        .o_npu_wlast(o_npu_wlast),
        .o_npu_wvalid(o_npu_wvalid),
        .i_npu_wready(i_npu_wready),
        .i_npu_bvalid(i_npu_bvalid),
        .o_npu_bready(o_npu_bready)
    );    

    //the 8 srams
    weight_mem_8bank #(
        .WEIGHT_MEM_ADDR_WIDTH(WT_AW),
        .DATA_WIDTH(8),
        .WORD_SIZE(8),
        .NUM_BANKS(WT_BANKS)
    ) wmem (
        .clk(wmem_clk),
        .wt_mem_rd_addr(wt_mem_rd_addr),
        .wt_mem_rd_en(wt_mem_rd_en),
        .wt_mem_rd_data(wt_mem_rd_data),
        .wt_mem_wr_addr(wt_mem_wr_addr),
        .wt_mem_wr_en(wt_mem_wr_en),
        .wt_mem_wr_data(wt_mem_wr_data)
    );

    function automatic [2:0] expected_bank(input integer word_idx);
        integer kernel_words_local;
        integer kernel_idx;
        begin
            kernel_words_local = i_H * i_W * i_words_per_channel; // number of 64-bit words in one kernel
            kernel_idx = word_idx / kernel_words_local; //which word you're processing over kernel words local -> why division instead of %.
            expected_bank = (kernel_idx / 8) % 8; // which kernel it belongs to -> expected bank is what is returned in this function
        end
    endfunction

    //this returns the expected bank addr where we should look for data to check.
    function automatic [10:0] expected_bank_addr(input integer word_idx);
        integer kernel_words_local;
        integer kernel_idx;
        integer word_in_kernel;
        begin
            kernel_words_local = i_H * i_W * i_words_per_channel; // word’s offset within its own kernel
            kernel_idx = word_idx / kernel_words_local; 
            word_in_kernel = word_idx % kernel_words_local; //word’s offset within its own kernel
            expected_bank_addr = (kernel_idx % 8) * kernel_words_local + word_in_kernel; //8 kernels sequentially inside one bank
        end
    endfunction

    //create a local mem
    //this is taken from memory testbench
    localparam int MEM_SIZE_BYTES  = 1 * 1024 * 1024;
    localparam int MEM_WORDS= MEM_SIZE_BYTES / 4;

    //memory is off chip memory
    reg [31:0] memory [0:MEM_WORDS-1];



    function automatic [63:0] expected_word_data(input integer word_idx);
        //the low idx and high idx
        integer low_idx;
        integer high_idx;
        begin
            // each entry in the mmemory[] is one 32-bit word
            // wgt_base is WGT_BASE is a byte address
            // low_idx is byte addressable  so shift >> into 32 bit word index
            //base address of weight -> get the lower address + 2 * word_idx
            //the WGT_BASE -> translate byte addressable
            //since word index is based on 64-bit address, you have to do do 2 * word_idx
            //to get the index for 32 bit off-chip memory 
            low_idx  = (WGT_BASE >> 2) + (2 * word_idx);

            //low_idx is the 
            high_idx = low_idx + 1;
            expected_word_data = {memory[high_idx], memory[low_idx]};
        end
    endfunction

    // read function for the sram for checking after finish writing to the srams
    task automatic read_weight_word(
        input  integer bank, //bank we want to check
        input  integer addr, //addr
        output logic [63:0] data_out //the data we want to read from.
    );
        begin
            @(negedge clk);
            //setting up signals for read
            wt_mem_rd_addr = '0;
            wt_mem_rd_en   = '0;
            wt_mem_rd_addr[bank*WT_AW +: WT_AW] = addr[WT_AW-1:0];
            wt_mem_rd_en[bank] = 1'b1;

            //data out - read data
            @(posedge clk);
            @(negedge clk);
            data_out = wt_mem_rd_data[bank*WT_DW +: WT_DW];
            wt_mem_rd_en = '0;
        end
    endtask

    //print srams into output.txt for comparison with golden brick
    task automatic dump_act_sram(
        input integer fd,
        input integer num_words
    );
        integer k;
        begin
            $fdisplay(fd, "==== ACT SRAM DUMP ====");
            for (k = 0; k < num_words; k = k + 1) begin
                $fdisplay(fd, "addr=%0d data=%016h", k, act_sram[k]);
            end
        end
    endtask


    //print stores into output.txt for comparison with golden brick.
    task automatic dump_store_mem(
        input integer fd,
        input integer num_words
    );
        integer k;
        begin
            $fdisplay(fd, "==== STORE MEM DUMP ====");
            for (k = 0; k < num_words; k = k + 1) begin
                $fdisplay(fd, "word=%0d data=%016h", k, stored_word_at_base(k));
            end
        end
    endtask


    // waits for the 0__done to  go high and latches it in done_seen so we can check for timeouts
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            done_seen <= 1'b0;
        else if (o_done)
            done_seen <= 1'b1;
    end

    //wire in axi_arbiter
    axi_arbiter #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) arbiter_inst (
        .clk(clk),
        .rst_n(rst_n),

        .i_cpu_valid (1'b0), // noboddy cares about the pc here
        .o_cpu_ready (),
        .i_cpu_addr  ('0),
        .i_cpu_wdata ('0),
        .i_cpu_wstrb (4'b0000),
        .o_cpu_rdata (),

        .i_npu_araddr (o_npu_araddr),
        .i_npu_arlen  (o_npu_arlen),
        .i_npu_arsize (o_npu_arsize),
        .i_npu_arvalid(o_npu_arvalid),
        .o_npu_arready(i_npu_arready),
        .o_npu_rdata  (i_npu_rdata),
        .o_npu_rvalid (i_npu_rvalid),
        .o_npu_rlast  (i_npu_rlast),
        .i_npu_rready (o_npu_rready),

        .i_npu_awaddr (o_npu_awaddr),
        .i_npu_awlen  (o_npu_awlen),
        .i_npu_awsize (o_npu_awsize),
        .i_npu_awvalid(o_npu_awvalid),
        .o_npu_awready(i_npu_awready),
        .i_npu_wdata  (o_npu_wdata),
        .i_npu_wstrb  (o_npu_wstrb),
        .i_npu_wlast  (o_npu_wlast),
        .i_npu_wvalid (o_npu_wvalid),
        .o_npu_wready (i_npu_wready),
        .o_npu_bresp  (),
        .o_npu_bvalid (i_npu_bvalid),
        .i_npu_bready (o_npu_bready),

        .o_mem_valid(mem_valid),
        .i_mem_ready(mem_ready),
        .o_mem_addr (mem_addr),
        .o_mem_wdata(mem_wdata),
        .o_mem_wstrb(mem_wstrb),
        .i_mem_rdata(mem_rdata)
    );

    //this is simulating the read from on-chip mem srams inorder to conduct the off chip memory stores.
    always_comb begin
        if (o_act_ren)
            i_act_rdata = act_sram[o_act_raddr[11:0]];
        else
            i_act_rdata = 64'h0;
    end

    //this stored_word_at base 
    function automatic [63:0] stored_word_at_base (input integer word_idx);
        integer low_idx;
        integer high_idx;
    begin
        low_idx  = (32'h00002000 >> 2) + (2 * word_idx);
        high_idx = low_idx + 1;
        stored_word_at_base  = {memory[high_idx], memory[low_idx]};
    end
    endfunction

    //load the golden brick activation sram for comparison 
    task automatic load_golden_act_sram(input string path);
        integer idx;
        begin
            for (idx = 0; idx < 4096; idx = idx + 1)
                golden_act_sram[idx] = 64'h0;
            $readmemh(path, golden_act_sram);
        end
    endtask

    //load the golden brick store beats for comparison     
    task automatic load_golden_store_beats(input string path);
        integer idx;
        begin
            for (idx = 0; idx < 8192; idx = idx + 1)
                golden_store_beats[idx] = 32'h0;
            $readmemh(path, golden_store_beats);
        end
    endtask

    //load the test configation.
    //this takes in the configuration file and prints the parameters
    task automatic load_test_config(
        input  string path,
        output integer n_cfg,
        output integer h_cfg,
        output integer w_cfg,
        output integer c_cfg,
        output integer wpc_cfg
    );
        integer fd;
        integer n_tmp;
        integer row_beats_tmp;
        integer weight_words_tmp;
        integer rc;
        begin
            n_cfg = 0;
            h_cfg = 0;
            w_cfg = 0;
            c_cfg = 0;
            wpc_cfg = 0;

            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FAIL: could not open %s", path);
                $finish;
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

    always @(posedge clk) begin
        //if we're not resetting and the weight write enable is enabled.
        if (rst_n && o_wgt_wen) begin
            //if the sram_sel is not the expected bank, display an error
            if (o_wgt_sram_sel !== expected_bank(write_count)) begin
                $display("ERR write %0d: bank exp=%0d got=%0d",
                         write_count, expected_bank(write_count), o_wgt_sram_sel);
                errors = errors + 1;
            end

            //is the address for the bank not expected, then print an error
            if (o_wgt_addr !== expected_bank_addr(write_count)) begin
                $display("ERR write %0d: addr exp=%0d got=%0d",
                         write_count, expected_bank_addr(write_count), o_wgt_addr);
                errors = errors + 1;
            end

            //if the write data is not expected, then print an error,
            if (o_wgt_wdata !== expected_word_data(write_count)) begin
                $display("ERR write %0d: data exp=%h got=%h",
                         write_count, expected_word_data(write_count), o_wgt_wdata);
                errors = errors + 1;
            end

            write_count = write_count + 1;
        end
    end


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
        integer first_kernel;
        begin
            //one kernel number.
            kernel_words_local = h_cfg * w_cfg * wpc_cfg;

            //banks
            for (bank = 0; bank < WT_BANKS; bank = bank + 1) begin


                first_kernel = bank * 8;
                //calculate how many kernels will be in each bank.
                if (n_cfg > first_kernel)
                    kernels_in_bank = ((n_cfg - first_kernel) > 8) ? 8 : (n_cfg - first_kernel);
                else
                    kernels_in_bank = 0;

                //adds in all the kernels in the bank for debugging
                for (addr = 0; addr < (kernels_in_bank * kernel_words_local); addr = addr + 1) begin
                    read_weight_word(bank, addr, rd_back);
                    if ((^rd_back !== 1'bx) && (rd_back != 64'h0)) begin
                        $fdisplay(fd, "bank=%0d addr=%0d data=%016h", bank, addr, rd_back);
                    end
                end
            end
        end
    endtask

    //NOT USED
    // //expected act word data checks fake off chip memory to see if load into srams is correct?
    // function automatic [63:0] expected_act_word_data(input integer word_idx);
    //     integer low_idx;
    //     integer high_idx;
    //     begin
    //         low_idx  = (ACT_BASE >> 2) + (2 * word_idx);
    //         high_idx = low_idx + 1;
    //         expected_act_word_data = {memory[high_idx], memory[low_idx]};
    //     end
    // endfunction

    // fake act sram
    //async reset
    always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        //count keeps actual write count
        act_write_count <= 0;
    end else if (o_act_wen) begin
        //storing the load tile into on chip mem sram.
        act_sram[o_act_waddr[11:0]] <= o_act_wdata;
        act_write_count <= act_write_count + 1;
    end
    end
    //this is off chip memory write
    always @(posedge clk) begin
        mem_ready <= 1'b0;
        if (mem_valid && !mem_ready) begin
            mem_ready <= 1'b1;
            mem_rdata <= 'bx;
            if ((mem_addr >> 2) < MEM_WORDS) begin
                if (|mem_wstrb) begin
                    if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                    if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                    if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
                end else begin
                    mem_rdata <= memory[mem_addr >> 2];
                end
            end else begin
                $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
                errors = errors + 1;
            end
        end
    end

    initial begin
        integer i;
        integer test_idx;
        integer n_cfg;
        integer h_cfg;
        integer w_cfg;
        integer c_cfg;
        integer wpc_cfg;
        integer expected_words;
        integer stride_bytes;
        integer out_fd;
        integer weight_fd;
        string cfg_path;
        string wgt_hex_path;
        string weight_dump_path;
        string act_hex_path;
        string golden_hex_path;
        string golden_store_path;
        out_fd = $fopen("output.txt", "w");
        if (out_fd == 0) begin
            $display("FAIL: could not open output.txt");
            $finish;
        end
        i_load_weights      = 1'b0;
        i_load_tile         = 1'b0;
        i_store_tile        = 1'b0;
        i_N                 = '0;
        i_W                 = '0;
        i_H                 = '0;
        i_words_per_channel = '0;
        i_addr              = '0;
        i_tile_stride       = '0;

        mem_ready           = 1'b0;
        mem_rdata           = '0;

        wt_mem_rd_addr      = '0;
        wt_mem_rd_en        = '0;

        errors              = 0;
        write_count         = 0;
        timeout_count       = 0;
        for (test_idx = 0; test_idx <= 7; test_idx = test_idx + 1) begin
            cfg_path        = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/config.txt", test_idx);
            wgt_hex_path    = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/wgt_mem_axi32.hex", test_idx);
            weight_dump_path = $sformatf("rtl_weight_sram_dump_test%0d.txt", test_idx);
            act_hex_path    = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/act_mem_axi32.hex", test_idx);
            golden_hex_path = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_act_sram.hex", test_idx);
            golden_store_path = $sformatf("../../../goldenbrick/mmu_vectors/test%0d/golden_store_axi32.hex", test_idx);

            load_test_config(cfg_path, n_cfg, h_cfg, w_cfg, c_cfg, wpc_cfg);
            expected_words = h_cfg * w_cfg * wpc_cfg;

            //stride_bytes   = w_cfg * wpc_cfg * 8;
            // nanda: previous spec the above line was correct but now that the goldebrick changed 
            stride_bytes   = w_cfg;
            repeat (5) @(posedge clk);
            rst_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);

            errors        = 0;
            write_count   = 0;
            timeout_count = 0;

            for (i = 0; i < MEM_WORDS; i = i + 1)
                memory[i] = 32'h0;

            $readmemh(wgt_hex_path, memory, WGT_BASE >> 2);

            i_load_weights      = 1'b0;
            i_load_tile         = 1'b0;
            i_store_tile        = 1'b0;
            i_N                 = n_cfg[9:0];
            i_W                 = w_cfg[9:0];
            i_H                 = h_cfg[9:0];
            i_words_per_channel = wpc_cfg[9:0];
            i_addr              = WGT_BASE;
            i_tile_stride       = 10'd0;

            $display("Running load_weights test%0d: N=%0d H=%0d W=%0d C=%0d words_per_channel=%0d",
                     test_idx, n_cfg, h_cfg, w_cfg, c_cfg, wpc_cfg);

            i_load_weights = 1'b1;
            @(posedge clk);
            i_load_weights = 1'b0;

            while (!done_seen && timeout_count < 400000) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end

            if (!done_seen) begin
                $display("FAIL load_weights test%0d: timeout waiting for o_done", test_idx);
                $finish;
            end

            weight_fd = $fopen(weight_dump_path, "w");
            if (weight_fd == 0) begin
                $display("FAIL: could not open %s", weight_dump_path);
                $finish;
            end
            dump_weight_srams_python_format(weight_fd, n_cfg, h_cfg, w_cfg, wpc_cfg);
            $fclose(weight_fd);
            $display("Wrote %s", weight_dump_path);

            if (stride_bytes > 1023) begin
                $display("SKIP load_tile test%0d: stride_bytes=%0d exceeds 10-bit i_tile_stride limit",
                        test_idx, stride_bytes);
                continue;
            end
            repeat (5) @(posedge clk);
            rst_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);

            for (i = 0; i < 4096; i = i + 1)
                act_sram[i] = 64'h0;

            errors          = 0;
            timeout_count   = 0;
            act_write_count = 0;

            for (i = 0; i < MEM_WORDS; i = i + 1)
                memory[i] = 32'h0;

            $readmemh(act_hex_path, memory, ACT_BASE >> 2);
            load_golden_act_sram(golden_hex_path);
            load_golden_store_beats(golden_store_path);

            i_load_weights      = 1'b0;
            i_load_tile         = 1'b0;
            i_store_tile        = 1'b0;
            i_N                 = 10'd0;
            i_W                 = w_cfg[9:0];
            i_H                 = h_cfg[9:0];
            i_words_per_channel = wpc_cfg[9:0];
            i_addr              = ACT_BASE;
            i_tile_stride       = stride_bytes[9:0];

            $display("Running load_tile test%0d: H=%0d W=%0d C=%0d words_per_channel=%0d",
                     test_idx, h_cfg, w_cfg, c_cfg, wpc_cfg);

            i_load_tile = 1'b1;
            @(posedge clk);
            i_load_tile = 1'b0;

            timeout_count = 0;
            while (!done_seen && timeout_count < 400000) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end

            if (!done_seen) begin
                $display("FAIL load_tile test%0d: timeout waiting for o_done", test_idx);
                $finish;
            end

            @(posedge clk);

            if (act_write_count != expected_words) begin
                $display("FAIL load_tile test%0d: expected %0d writes, saw %0d",
                         test_idx, expected_words, act_write_count);
                $finish;
            end

            for (i = 0; i < expected_words; i = i + 1) begin
                if (act_sram[i] !== golden_act_sram[i]) begin
                    $display("FAIL load_tile test%0d word %0d", test_idx, i);
                    $finish;
                end
            end

            $display("PASS load_tile test%0d", test_idx);
            $fdisplay(out_fd, "==== test%0d ====", test_idx);
            dump_act_sram(out_fd, act_write_count);

            repeat (5) @(posedge clk);
            rst_n = 1'b0;
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);

            timeout_count = 0;

            for (i = 0; i < (expected_words * 2); i = i + 1)
                memory[(STORE_BASE >> 2) + i] = 32'h0;

            i_load_weights      = 1'b0;
            i_load_tile         = 1'b0;
            i_store_tile        = 1'b0;
            i_N                 = 10'd0;
            i_W                 = w_cfg[9:0];
            i_H                 = h_cfg[9:0];
            i_words_per_channel = wpc_cfg[9:0];
            i_addr              = STORE_BASE;
            i_tile_stride       = stride_bytes[9:0];

            $display("Running store_tile test%0d: H=%0d W=%0d C=%0d words_per_channel=%0d",
                     test_idx, h_cfg, w_cfg, c_cfg, wpc_cfg);

            i_store_tile = 1'b1;
            @(posedge clk);
            i_store_tile = 1'b0;

            timeout_count = 0;
            while (!done_seen && timeout_count < 400000) begin
                @(posedge clk);
                timeout_count = timeout_count + 1;
            end

            if (!done_seen) begin
                $display("FAIL store_tile test%0d: timeout waiting for o_done", test_idx);
                $finish;
            end

            @(posedge clk);

            //expected_words is count in on kernel -> check off chip memory write and golden brick stores.
            for (i = 0; i < (expected_words * 2); i = i + 1) begin
                if (memory[(STORE_BASE >> 2) + i] !== golden_store_beats[i]) begin
                    $display("FAIL store_tile test%0d beat %0d got=%08h exp=%08h",
                             test_idx, i, memory[(STORE_BASE >> 2) + i], golden_store_beats[i]);
                    $finish;
                end
            end

            $display("PASS store_tile test%0d", test_idx);
            dump_store_mem(out_fd, expected_words);
        end

        $fclose(out_fd);
        $finish;
    end
endmodule
