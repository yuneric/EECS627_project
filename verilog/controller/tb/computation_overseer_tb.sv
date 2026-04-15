`timescale 1ns/1ps

module computation_overseer_tb;

    //Parameters
    parameter DIM               = 8;
    parameter NUM_ARRAYS        = 8;
    parameter DIM_WIDTH         = 10;
    parameter MEM_IF_ADDR_WIDTH = 12;
    parameter WT_ADDR_WIDTH     = 11;
    parameter WORD_SIZE         = 64;
    parameter SHIFT_WIDTH       = 5;

    //Clock & Reset
    logic clk;
    logic rst_n;

    //DUT Signals
    // Controller inputs
    logic                   comp_compute_start;
    logic [1:0]             comp_stride;
    logic [1:0]             comp_padding;
    logic                   comp_maxpool_en;
    logic                   comp_relu_en;
    logic [SHIFT_WIDTH-1:0] comp_scale_amt;
    logic [DIM_WIDTH-1:0]   comp_Hi, comp_Wi;
    logic [DIM_WIDTH-1:0]   comp_Hf, comp_Wf;
    logic [DIM_WIDTH-1:0]   comp_Ho, comp_Wo;
    logic [DIM_WIDTH-1:0]   comp_words_per_channel;
    logic [DIM_WIDTH-1:0]   comp_num_kernels;
    
    // Outputs to Controller / Mem_IF
    logic                           comp_done;
    logic [MEM_IF_ADDR_WIDTH-1:0]   comp_waddr;
    logic                           comp_wen;
    logic [WORD_SIZE-1:0]           comp_wdata;
    logic [MEM_IF_ADDR_WIDTH-1:0]   comp_raddr;
    logic                           comp_ren;

    // SA Slice & Im2Col Signals
    logic                           cdc_req;
    logic                           cdc_ack;
    logic                           relu_en;
    logic [SHIFT_WIDTH-1:0]         shift_by;
    logic                           maxpool_en;
    logic                           push_en;
    logic                           data_last;
    logic [DIM-1:0]                 push_fifo_full;
    logic [WT_ADDR_WIDTH-1:0]       wt_sram_rd_addr;
    logic                           wt_sram_rd_en;
    logic [NUM_ARRAYS-1:0]          array_active;

    // FIFO Interface
    logic [WORD_SIZE-1:0]           pop_data;
    logic [NUM_ARRAYS-1:0]          pop_en;
    logic [NUM_ARRAYS-1:0]          pop_empty;
    logic [NUM_ARRAYS-1:0]          almost_empty;
    logic [NUM_ARRAYS-1:0]          pop_full;
    // logic [DIM-1:0]                 rd_empty;

    logic [WORD_SIZE-1:0]           pop_data_real;
    logic [WORD_SIZE-1:0]           dly_pop_data;
    // logic [NUM_ARRAYS-1:0]          dly_almost_empty;
    // logic [NUM_ARRAYS-1:0]          dly_pop_full;

    //Clock Generation
    initial clk = 0;
    always #`CLK_PERIOD_SYS_HALF clk = ~clk;

    // Automatically acknowledge CDC requests
    assign cdc_ack = cdc_req;
    assign push_fifo_full = '0; 

    assign pop_data_real = (array_active[0] & !(|array_active[7:1])) ? dly_pop_data : pop_data; 
    always_ff @(posedge clk) begin
        for (int i = 0; i < DIM; i++) begin       
            dly_pop_data        <= pop_data;
            // dly_almost_empty[i] <= almost_empty[i];
            // dly_pop_full[i]     <= pop_full[i];  
        end
    end

    computation_overseer #(
        .DIM(DIM), .NUM_ARRAYS(NUM_ARRAYS), .DIM_WIDTH(DIM_WIDTH),
        .MEM_IF_ADDR_WIDTH(MEM_IF_ADDR_WIDTH), .WT_ADDR_WIDTH(WT_ADDR_WIDTH),
        .WORD_SIZE(WORD_SIZE), .SHIFT_WIDTH(SHIFT_WIDTH)
    ) dut (
        .i_clk(clk), .i_rst_n(rst_n),
        .i_comp_compute_start(comp_compute_start),
        .i_comp_stride(comp_stride),
        .i_comp_padding(comp_padding),
        .i_comp_maxpool_en(comp_maxpool_en),
        .i_comp_relu_en(comp_relu_en),
        .i_comp_scale_amt(comp_scale_amt),
        .i_comp_Hi(comp_Hi), .i_comp_Wi(comp_Wi),
        .i_comp_Hf(comp_Hf), .i_comp_Wf(comp_Wf),
        .i_comp_Ho(comp_Ho), .i_comp_Wo(comp_Wo),
        .i_comp_words_per_channel(comp_words_per_channel),
        .i_comp_num_kernels(comp_num_kernels),
        .o_comp_done(comp_done),
        .o_comp_waddr(comp_waddr),
        .o_comp_wen(comp_wen),
        .o_comp_wdata(comp_wdata),
        .o_comp_raddr(comp_raddr),
        .o_comp_ren(comp_ren),
        .o_cdc_req(cdc_req),
        .i_cdc_ack(cdc_ack),
        .o_relu_en(relu_en),
        .o_shift_by(shift_by),
        .o_maxpool_en(maxpool_en),
        .o_push_en(push_en),
        .o_data_last(data_last),
        .i_push_fifo_full(push_fifo_full),
        .o_wt_sram_rd_addr(wt_sram_rd_addr),
        .o_wt_sram_rd_en(wt_sram_rd_en),
        .i_pop_data(pop_data_real),
        .o_pop_en(pop_en),
        //.i_pop_empty(pop_empty),
        .o_array_active(array_active),
        .i_pop_almost_empty(almost_empty),
        .i_pop_full(pop_full)
        // .i_rd_empty(rd_empty)
    );

    
    //Testbench Queues
    // To be accurate to the real fifos, sa_fifos holds all the data, and presents data at its output
    // pop is asserted to consume that data and load the next bit of data
    // DATA IN COMP OVERSEER SHOULD BE LATCHED IN THE POSEDGE AFTER IT ASSERTS POP_EN
    logic [(WORD_SIZE+MEM_IF_ADDR_WIDTH)-1:0]  sa_fifos [DIM] [$]; 

    // these queues are used to check that data is going to the right place
    logic [WORD_SIZE-1:0]               wr_data_queue [$]; 
    logic [MEM_IF_ADDR_WIDTH-1:0]           wr_addr_queue [$]; 
    
    // logic [(WORD_SIZE+WT_ADDR_WIDTH)-1:0]           sa_fifo_output [NUM_ARRAYS-1:0]; 
    logic [(WORD_SIZE+MEM_IF_ADDR_WIDTH)-1:0]           pop_data_full;
    logic [MEM_IF_ADDR_WIDTH-1:0]                       pop_dst_addr;

    //FIFO Status
    // logic [NUM_ARRAYS-1:0]                 pop_empty_neg;
    // logic [NUM_ARRAYS-1:0]                 almost_empty_neg;
    // logic [NUM_ARRAYS-1:0]                 pop_full_neg;
    // always_comb begin
    //     for (int i = 0; i < DIM; i++) begin
    //         pop_empty_neg[i]    = (sa_fifos[i].size() == 0);
    //         almost_empty_neg[i] = (sa_fifos[i].size() < 2);
    //         pop_full_neg[i]      = (sa_fifos[i].size() >= 8); 
    //     end
    // end
    // Sync fifo flags with posedge of clk

    always_ff @(posedge clk) begin
        for (int i = 0; i < DIM; i++) begin
            pop_empty[i]       <= (sa_fifos[i].size() == 0);        
            almost_empty[i]    <= (sa_fifos[i].size() < 2);
            pop_full[i]         <= (sa_fifos[i].size() >= 8);  
        end
    end

    //FIFO Pop Muxing Logic
    always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) pop_data_full <= '0;
        else begin
            for (int i = 0; i < NUM_ARRAYS; i++) begin
                if (pop_en[i] && sa_fifos[i].size() > 0) pop_data_full <= sa_fifos[i].pop_front(); 

            end
        end
    end

    assign pop_data = pop_data_full[75:12];
    assign pop_dst_addr = pop_data_full[11:0];


    // Error checking
    int num_tests_failed;
    int num_errors;
    int num_addr_mismatch;

    // Here we do our writeback checks for every write
    logic [WORD_SIZE-1:0] correct_data;
    logic [MEM_IF_ADDR_WIDTH-1:0] correct_dst_addr;
    logic [WORD_SIZE-1:0] last_wdata;
    logic [MEM_IF_ADDR_WIDTH-1:0] last_waddr;
    always @(posedge clk) begin
        // Add data to writeback queue when we pop from fifos (this data should appear in order at comp overseer output)
        if(|pop_en) begin
            wr_data_queue.push_back(pop_data);
            wr_addr_queue.push_back(pop_dst_addr);
        end

        // When we do a write, check the data and its destiation address
        if(comp_wen && (last_waddr !== comp_waddr)) begin

            last_waddr <= comp_waddr;
            last_wdata <= comp_wdata;
            correct_data = wr_data_queue.pop_front();
            correct_dst_addr = wr_addr_queue.pop_front();
            if(correct_dst_addr != comp_waddr) begin
                $display("wb ERROR: addr mismatch act: %d exp: %d", comp_waddr, correct_dst_addr);
                num_addr_mismatch += 1;
            end
            if(correct_data != comp_wdata) begin
                $display("wb ERROR: data mismatch act: %d exp: %d", comp_wdata, correct_data);
            end
        end
    end

    // Capture fifo writes
    int num_writes;
    logic [63:0] comp_over_out [4095:0];
    logic [63:0] golden_out [4095:0];
    always @(posedge clk) begin
        if(comp_wen) begin
            comp_over_out[comp_waddr] = comp_wdata;
            num_writes += 1;
        end
    end

    // --- File Readers & Parsers ---
    integer stim_fd;
    integer expect_fd;
    
    // Parsing variables
    int test;
    int real_Ho, real_Wo;
    int tmp1, tmp2, tmp3, tmp4;
    logic [WORD_SIZE-1:0]       fifo_data;
    logic [DIM_WIDTH-1:0]       y;
    logic [DIM_WIDTH-1:0]       x;
    logic [DIM_WIDTH-1:0]       ch_start;
    logic                       valid_ch;
    logic [MEM_IF_ADDR_WIDTH-1:0]   dst_addr;

    // Looping variables
    int lines_per_tile;
    int num_golden_lines;
    integer kernel_groups;
    integer tiles_x;
    integer tiles_y;
    integer num_drains;
    int num_words_per_Co; 

    //dump file
    initial begin
        $fsdbDumpfile("computation_overseer_tb.fsdb");
        $fsdbDumpvars(0, computation_overseer_tb, "+all");
        `ifdef SYN
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/computation_overseer/computation_overseer.syn.sdf", computation_overseer_tb.dut);
        `endif
    end

    initial begin
        rst_n = 1;
        comp_compute_start = 0;
        comp_scale_amt = 0;
        comp_relu_en   = 0;
        comp_Hi = '0;
        comp_Wi = '0;
        comp_Hf = '0;
        comp_Wf = '0;
        comp_Ho = '0;
        comp_Wo = '0;
        comp_words_per_channel = '0;
        comp_num_kernels = '0;
        comp_stride = '0;
        comp_padding = '0;
        comp_maxpool_en = '0;

        // Reset
        @(negedge clk);
        rst_n = 0;
        #1000;
        repeat(5) @(negedge clk);
        rst_n = 1;

        // Open both files
        stim_fd = $fopen("comp_over_test.in", "r");
        expect_fd = $fopen("comp_over_test.out", "r");

        
        if (!stim_fd || !expect_fd) begin
            $display("FATAL: Could not open one or both stim/expect files.");
            $system("pwd");
            $finish;
        end

        num_tests_failed = 0;

        // Main test loop
        while(!$feof(stim_fd)) begin
            // Reset vars
            num_errors = 0;
            num_addr_mismatch = 0;
            num_writes = 0;
            for(int i = 0; i < 4096; i +=1 ) begin
                comp_over_out[i] = '0;
                golden_out[i] = '0;
            end

            // Check the header
            $fscanf(stim_fd, "test: %d comp_Hi: %h comp_Wi: %h comp_Hf: %h comp_Wf: %h comp_Ho: %h comp_Wo: %h comp_words_per_channel: %h comp_num_kernels: %h comp_stride: %b comp_padding: %b comp_maxpool_en: %b",
                    test,
                    comp_Hi,
                    comp_Wi,
                    comp_Hf,
                    comp_Wf,
                    comp_Ho,
                    comp_Wo,
                    comp_words_per_channel,
                    comp_num_kernels,
                    comp_stride,
                    comp_padding,
                    comp_maxpool_en);
            $display("test: %0d comp_Hi: %h comp_Wi: %h comp_Hf: %h comp_Wf: %h comp_Ho: %h comp_Wo: %h comp_words_per_channel: %h comp_num_kernels: %h comp_stride: %b comp_padding: %b comp_maxpool_en: %b",
                    test,
                    comp_Hi,
                    comp_Wi,
                    comp_Hf,
                    comp_Wf,
                    comp_Ho,
                    comp_Wo,
                    comp_words_per_channel,
                    comp_num_kernels,
                    comp_stride,
                    comp_padding,
                    comp_maxpool_en);
            $display("Test: %0d", test);

            // Account for our 2x4 tiling
            real_Wo = ((comp_Wo + 3) >> 2) << 2;
            real_Ho = ((comp_Ho + 1) >> 1) << 1;
            if(comp_maxpool_en) begin
                real_Ho = real_Ho / 2;
                real_Wo = real_Wo / 2;
            end
            $display("Original: %0dx%0d, After Tiling & Maxpool: %0dx%0d", comp_Ho, comp_Wo, real_Ho, real_Wo);

            // Read in the golden output
            num_words_per_Co = ((comp_num_kernels-1) >> 3) + 1;
            $display("num_words_per_Co: %0d", num_words_per_Co);
            num_golden_lines = real_Ho * real_Wo * num_words_per_Co;
            $fscanf(expect_fd, "test: %d x y ch_start addrh\n", test);
            for(int i = 0; i < num_golden_lines; i += 1) begin
                $fscanf(expect_fd, "%h %h %h %h %h\n", golden_out[i], tmp1, tmp2, tmp3, tmp4);
            end

            // Now determine how many drains we need to do for this test
            kernel_groups = comp_num_kernels / 64;
            if(comp_num_kernels % 64 > 0) begin
                kernel_groups += 1;
            end
            tiles_x = (comp_Wo + 3) >> 2;
            tiles_y = (comp_Ho + 1) >> 1;
            num_drains = tiles_x * tiles_y * kernel_groups;
            $display("kernel_groups: %0d", kernel_groups);
            $display("tiles_x: %0d", tiles_x);
            $display("tiles_y: %0d", tiles_y);
            $display("num_drains: %0d", num_drains);

            // Start our computation !!!!!
            repeat (100) @(posedge clk);
            @(negedge clk);
            comp_compute_start = 1;
            @(negedge clk);
            comp_compute_start = 0;

            // Now we loop through all of our drains
            lines_per_tile = 8;
            if(comp_maxpool_en) begin
                lines_per_tile = 2;
            end
            for(int drain = 0; drain < num_drains; drain += 1) begin
                //repeat (20) @(posedge clk);
                for(int array = 0; array < 8; array += 1) begin
                    for(int line = 0; line < lines_per_tile; line += 1) begin
                        $fscanf(stim_fd, "%h %h %h %h %b %h\n", fifo_data, x, y, ch_start, valid_ch, dst_addr);
                        if(valid_ch) begin
                            $display("Writing SA: %0d, Line: %0d", array, line);
                            sa_fifos[array].push_back({fifo_data, dst_addr});
                            // foreach (sa_fifos[array][i])
    		                //     $display ("sa_fifos[%0d][%0d] = %s", array, i, sa_fifos[array][i]);
                            // $display("sa_fifos %p", sa_fifos);
                            // $display("sa_fifos size %0d", sa_fifos[0].size());
                        end
                    end
                end

                // Now that weve loaded this tile of data, wait for it to drain
                $display("%t Waiting for im2col...", $time);
                wait(data_last);
                $display("Waiting for drain...");
                // wait(&pop_empty);
                @(negedge comp_wen);

                //repeat (20) @(posedge clk);
            end
            // Let the data egress
            repeat (20) @(posedge clk);

            // --- Final Grading ---
            $display("Comparing Outputs");
            for(int word = 0; word < num_golden_lines; word +=1 ) begin
                if(comp_over_out[word] != golden_out[word]) begin
                    num_errors += 1;
                    $display("Mismatch at addr: %0d", word);
                    $display("act: %h exp: %h", comp_over_out[word], golden_out[word]);
                end
            end
            //if ((num_errors == 0) && (num_writes == num_golden_lines) && (num_addr_mismatch == 0)) begin
            if ((num_errors == 0) && (num_addr_mismatch == 0)) begin
                $display("========================================");
                $display("TEST %0d PASSED! ALL DRAIN WRITES MATCH!", test);
                $display("========================================");
            end else begin
                num_tests_failed += 1;
                $display("========================================");
                $display("TEST %0d FAILED WITH %0d DATA MISMATCHES & %0d ADDR MISMATCHES.", test, num_errors, num_addr_mismatch);
                $display("Num Writes act: %0d exp: %0d", num_writes, num_golden_lines);
                $display("========================================");
            end
        end
        
        if ((num_tests_failed == 0) ) begin
            $display("========================================");
            $display("ALL TESTS PASSED");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("# TESTS FAILED %0d", num_tests_failed);
            $display("========================================");
        end
        $finish;
    end

    // Timeout failsafe
    initial begin
        #500000000;
        $display("TIMEOUT ERROR: Simulation hung.");
        $finish;
    end

endmodule