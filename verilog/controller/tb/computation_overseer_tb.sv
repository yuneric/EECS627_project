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
    logic [NUM_ARRAYS-1:0]          rd_full;
    // logic [DIM-1:0]                 rd_empty;


    //Clock Generation
    initial clk = 0;
    always #`CLK_PERIOD_SYS_HALF clk = ~clk;

    // Automatically acknowledge CDC requests
    assign cdc_ack = cdc_req;
    assign push_fifo_full = '0; 

    
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
        .i_pop_data(pop_data),
        .o_pop_en(pop_en),
        .i_pop_empty(pop_empty),
        .o_array_active(array_active),
        .i_almost_empty(almost_empty),
        .i_rd_full(rd_full)
        // .i_rd_empty(rd_empty)
    );

    
    //Testbench Queues
    // To be accurate to the real fifos, sa_fifos holds all the data, and presents data at its output
    // pop is asserted to consume that data and load the next bit of data
    // DATA IN COMP OVERSEER SHOULD BE LATCHED IN THE POSEDGE AFTER IT ASSERTS POP_EN
    logic [(WORD_SIZE+WT_ADDR_WIDTH)-1:0]  sa_fifos [DIM] [$]; 

    // these queues are used to check that data is going to the right place
    logic [WORD_SIZE-1:0]               wr_data_queue [$]; 
    logic [WT_ADDR_WIDTH-1:0]           wr_addr_queue [$]; 
    
    // logic [(WORD_SIZE+WT_ADDR_WIDTH)-1:0]           sa_fifo_output [NUM_ARRAYS-1:0]; 
    logic [(WORD_SIZE+WT_ADDR_WIDTH)-1:0]           pop_data_full;
    logic [WT_ADDR_WIDTH-1:0]                       pop_dst_addr;

    //FIFO Status
    // logic [NUM_ARRAYS-1:0]                 pop_empty_neg;
    // logic [NUM_ARRAYS-1:0]                 almost_empty_neg;
    // logic [NUM_ARRAYS-1:0]                 rd_full_neg;
    // always_comb begin
    //     for (int i = 0; i < DIM; i++) begin
    //         pop_empty_neg[i]    = (sa_fifos[i].size() == 0);
    //         almost_empty_neg[i] = (sa_fifos[i].size() < 2);
    //         rd_full_neg[i]      = (sa_fifos[i].size() >= 8); 
    //     end
    // end
    // Sync fifo flags with posedge of clk
    always_ff @(posedge clk) begin
        for (int i = 0; i < DIM; i++) begin
            pop_empty[i]       <= (sa_fifos[i].size() == 0);        
            almost_empty[i]    <= (sa_fifos[i].size() < 2);
            rd_full[i]         <= (sa_fifos[i].size() >= 8);  
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

    assign pop_data = pop_data_full[74:11];
    assign pop_dst_addr = pop_data_full[10:0];


    // Here we do our writeback checks for every write
    logic [WORD_SIZE-1:0] correct_data;
    logic [WT_ADDR_WIDTH-1:0] correct_dst_addr;
    always @(posedge clk) begin
        // Add data to writeback queue when we pop from fifos (this data should appear in order at comp overseer output)
        if(|pop_en) begin
            wr_data_queue.push_back(pop_data);
            wr_addr_queue.push_back(pop_dst_addr);
        end

        // When we do a write, check the data and its destiation address
        if(comp_wen) begin
            correct_data = wr_data_queue.pop_front();
            correct_dst_addr = wr_addr_queue.pop_front();
            if(correct_dst_addr != comp_waddr) begin
                $display("wb ERROR: addr mismatch act: %h exp: %h", comp_waddr, correct_dst_addr);
            end
            if(correct_data != comp_wdata) begin
                $display("wb ERROR: data mismatch act: %h exp: %h", comp_wdata, correct_data);
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

    // Error checking
    int num_tests_failed;
    int num_errors;
    
    // Parsing variables
    int test;
    int real_Ho, real_Wo;
    int tmp1, tmp2, tmp3, tmp4;
    logic [WORD_SIZE-1:0]       fifo_data;
    logic [DIM_WIDTH-1:0]       y;
    logic [DIM_WIDTH-1:0]       x;
    logic [DIM_WIDTH-1:0]       ch_start;
    logic                       valid_ch;
    logic [WT_ADDR_WIDTH-1:0]   dst_addr;

    // Looping variables
    int lines_per_tile;
    int num_golden_lines;
    integer kernel_groups;
    integer tiles_x;
    integer tiles_y;
    integer num_drains;


    initial begin
        rst_n = 1;
        comp_compute_start = 0;
        comp_scale_amt = 0;
        comp_relu_en   = 0;

        // Reset
        @(negedge clk);
        rst_n = 0;
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
            num_writes = 0;
            for(int i = 0; i < 4096; i +=1 ) begin
                comp_over_out[i] = '0;
                golden_out[i] = '0;
            end

            // Check the header
            $fscanf(stim_fd, "test: %h comp_Hi: %h comp_Wi: %h comp_Hf: %h comp_Wf: %h comp_Ho: %h comp_Wo: %h comp_words_per_channel: %h comp_num_kernels: %h comp_stride: %b comp_padding: %b comp_maxpool_en: %b",
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
            real_Ho = comp_Ho + (2 - comp_Ho % 2);
            real_Wo = comp_Wo + (4 - comp_Wo % 4);
            if(comp_maxpool_en) begin
                real_Ho = real_Ho / 2;
                real_Wo = real_Wo / 2;
            end
            //$display("Original: %dx%d, After Tiling: %dx%d", comp_Ho, comp_Wo, real_Ho, real_Wo);

            // Read in the golden output
            num_golden_lines = real_Ho * real_Wo;
            $fscanf(expect_fd, "test: %h x y ch_start addrh\n", test);
            for(int i = 0; i < num_golden_lines; i += 1) begin
                $fscanf(expect_fd, "%h %h %h %h %h\n", golden_out[i], tmp1, tmp2, tmp3, tmp4);
            end

            // Now determine how many drains we need to do for this test
            kernel_groups = comp_num_kernels / 64;
            if(comp_num_kernels % 64 > 0) begin
                kernel_groups += 1;
            end
            tiles_x = real_Wo / 4;
            tiles_y = real_Ho / 2;
            num_drains = tiles_x * tiles_y * kernel_groups;
            $display("kernel_groups: %0d", kernel_groups);
            $display("tiles_x: %0d", tiles_x);
            $display("tiles_y: %0d", tiles_y);
            $display("num_drains: %0d", num_drains);

            // Start our computation !!!!!
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
                repeat (20) @(posedge clk);
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
                $display("Waiting for im2col...");
                wait(data_last);
                $display("Waiting for drain...");
                wait(&pop_empty);
            end

            // --- Final Grading ---
            $display("Comparing Outputs");
            for(int word = 0; word < num_golden_lines; word +=1 ) begin
                if(comp_over_out[word] != golden_out[word]) begin
                    num_errors += 1;
                    $display("Mismatch at addr: %0d", word);
                    $display("act: %h exp: %h", comp_over_out[word], golden_out[word]);
                end
            end
            if ((num_errors == 0) && (num_writes == num_golden_lines)) begin
                $display("========================================");
                $display("TEST %0d PASSED! ALL DRAIN WRITES MATCH!", test);
                $display("========================================");
            end else begin
                num_tests_failed += 1;
                $display("========================================");
                $display("TEST %0d FAILED WITH %0d MISMATCHES.", test, num_errors);
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
        #500000;
        $display("TIMEOUT ERROR: Simulation hung.");
        $finish;
    end

endmodule