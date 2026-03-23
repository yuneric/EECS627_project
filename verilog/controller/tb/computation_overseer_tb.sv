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

    //Testbench Queues
    logic [WORD_SIZE-1:0]           sa_fifos [DIM] [$];     
    logic [WORD_SIZE-1:0]           expected_data_q [$];    
    logic [MEM_IF_ADDR_WIDTH-1:0]   expected_waddr_q [$];
    int                             expected_x_q [$];
    int                             expected_y_q [$];
    int                             expected_ch_q [$];

    logic [WORD_SIZE-1:0]           exp_data;
    logic [MEM_IF_ADDR_WIDTH-1:0]   exp_addr;
    int                             exp_x_val;
    int                             exp_y_val;
    int                             exp_ch_val;
    
    // FIX: Removed the "= 0" initialization to prevent driver conflict
    int num_errors;

    //Clock Generation
    initial clk = 0;
    always #5 clk = ~clk;

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
        .i_push_fifo_full(push_fifo_full),
        .o_wt_sram_rd_addr(wt_sram_rd_addr),
        .o_wt_sram_rd_en(wt_sram_rd_en),
        .i_pop_data(pop_data),
        .o_pop_en(pop_en),
        .i_pop_empty(pop_empty),
        .o_array_active(array_active),
        .i_almost_empty(almost_empty),
        .i_rd_full(rd_full),
        .i_rd_empty(rd_empty)
    );

    //FIFO Status
    always_comb begin
        for (int i = 0; i < DIM; i++) begin
            pop_empty[i]    = (sa_fifos[i].size() == 0);
            rd_empty[i]     = (sa_fifos[i].size() == 0);
            almost_empty[i] = (sa_fifos[i].size() <= 2);
            rd_full[i]      = (sa_fifos[i].size() >= 8); 
        end
    end

    //FIFO Pop Muxing Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) pop_data <= '0;
        else begin
            for (int i = 0; i < DIM; i++) begin
                if (pop_en[i] && sa_fifos[i].size() > 0) pop_data <= sa_fifos[i].pop_front(); 
            end
        end
    end

    //The Automated Checker
    // FIX: Added negedge rst_n to sensitivity list
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            num_errors <= 0;
        end else if (comp_wen) begin
            if (expected_data_q.size() > 0) begin
                //pop what should be at the address.
                exp_data   = expected_data_q.pop_front();
                exp_addr   = expected_waddr_q.pop_front();
                exp_x_val  = expected_x_q.pop_front();
                exp_y_val  = expected_y_q.pop_front();
                exp_ch_val = expected_ch_q.pop_front();
                
                if (comp_waddr !== exp_addr) begin
                    $display("ERROR @ time %0t: Address Mismatch! Expected: %03x, Got: %03x [Pixel: (%0d, %0d), Ch: %0h]", $time, exp_addr, comp_waddr, exp_x_val, exp_y_val, exp_ch_val);
                    num_errors++;
                end
                
                if (comp_wdata !== exp_data) begin
                    $display("ERROR @ time %0t: Data Mismatch! Expected: %16x, Got: %16x [Pixel: (%0d, %0d), Ch: %0h]", $time, exp_data, comp_wdata, exp_x_val, exp_y_val, exp_ch_val);
                    num_errors++;
                end
                
                if (comp_waddr === exp_addr && comp_wdata === exp_data) begin
                    $display("SUCCESS: Wrote Data %16x to Addr %03x", comp_wdata, comp_waddr);
                end
            end else begin
                $display("ERROR @ time %0t: Overseer wrote to memory, but EXPECT queue is empty!", $time);
                num_errors++;
            end
        end
    end

    // --- Task to execute test sequence ---
    task run_test();
        $display("----------------------------------------");
        $display("Starting Test execution...");
        @(negedge clk);
        comp_compute_start = 1;
        @(negedge clk);
        comp_compute_start = 0;
        
        wait(dut.state == 3'b000 && comp_done == 1'b1); 
        repeat(5) @(posedge clk);
        $display("DUT Finished Test execution.");
    endtask

    // --- File Readers & Parsers ---
    integer stim_fd;
    integer expect_fd;
    string token;
    string dummy_str;
    
    // Parsing variables
    int test_id;
    logic [WORD_SIZE-1:0] parsed_data, exp_d;
    int parsed_x, parsed_y, parsed_ch, parsed_valid;
    int exp_x, exp_y, exp_ch;
    string parsed_addr_str;
    logic [MEM_IF_ADDR_WIDTH-1:0] exp_a;
    int fifo_idx;
    
    bit test_loaded = 0;

    initial begin
        rst_n = 1;
        comp_compute_start = 0;
        comp_scale_amt = 0;

        @(negedge clk);
        rst_n = 0;
        @(negedge clk);
        rst_n = 1;

        // Open both files
        stim_fd = $fopen("comp_over_test.in", "r");
        expect_fd = $fopen("comp_over_test.out", "r");
        // stim_fd = $fopen("verilog/controller/tb/comp_over_test.in", "r");
        // expect_fd = $fopen("verilog/controller/tb/comp_over_test.out", "r");
        
        if (!stim_fd || !expect_fd) begin
            $display("FATAL: Could not open one or both stim/expect files.");
            $finish;
        end

        //Load ALL expected memory writes into the Checker Queue
        $display("Loading Expected Outputs...");
        while (!$feof(expect_fd)) begin
            int r = $fscanf(expect_fd, "%s", token);
            if (r <= 0) break;
            
            if (token == "test:") begin
                // Consume the header row: "00 x y ch_start addr"
                void'($fscanf(expect_fd, "%h %s %s %s %s", test_id, dummy_str, dummy_str, dummy_str, dummy_str));
            end else begin
                // Parse the expectation data line
                void'($sscanf(token, "%h", exp_d));
                void'($fscanf(expect_fd, "%h %h %h %h", exp_x, exp_y, exp_ch, exp_a));
                
                expected_data_q.push_back(exp_d);
                expected_waddr_q.push_back(exp_a);
                expected_x_q.push_back(exp_x);
                expected_y_q.push_back(exp_y);
                expected_ch_q.push_back(exp_ch);
            end
        end
        $display("Loaded %0d expected writes.", expected_data_q.size());

        //Stream Stimulus into FIFOs and run the DUT
        while (!$feof(stim_fd)) begin
            int r = $fscanf(stim_fd, "%s", token);
            if (r <= 0) break;
            
            if (token == "test:") begin
                // If we hit a new "test:" block but already loaded data, run the loaded test first
                if (test_loaded) begin
                    run_test();
                    test_loaded = 0;
                end
                
                // Parse the config line
                void'($fscanf(stim_fd, "%h comp_Hi: %h comp_Wi: %h comp_Hf: %h comp_Wf: %h comp_Ho: %h comp_Wo: %h comp_words_per_channel: %h comp_num_kernels: %h comp_stride: %h comp_padding: %h comp_maxpool_en: %h comp_relu_en: %h",
                    test_id, comp_Hi, comp_Wi, comp_Hf, comp_Wf, comp_Ho, comp_Wo, comp_words_per_channel, comp_num_kernels, comp_stride, comp_padding, comp_maxpool_en, comp_relu_en));
                
                $display("Parsed CONFIG: Ho=%0h, Wo=%0h, Co=%0h", comp_Ho, comp_Wo, comp_num_kernels);
                
            end else begin
                // Parse the FIFO stimulus data line
                void'($sscanf(token, "%h", parsed_data));
                void'($fscanf(stim_fd, "%h %h %h %d %s", parsed_x, parsed_y, parsed_ch, parsed_valid, parsed_addr_str));
                
                // Only push to FIFOs if valid
                if (parsed_valid == 1) begin
                    fifo_idx = (parsed_ch / 8) % NUM_ARRAYS;
                    sa_fifos[fifo_idx].push_back(parsed_data);
                    test_loaded = 1;
                end
            end
        end
        
        // Execute the final test loaded from the file
        if (test_loaded) begin
            run_test();
        end
        
        // --- Final Grading ---
        if (num_errors == 0 && expected_waddr_q.size() == 0) begin
            $display("========================================");
            $display("TEST PASSED! ALL DRAIN WRITES MATCH!");
            $display("========================================");
        end else begin
            $display("========================================");
            $display("TEST FAILED WITH %0d ERRORS.", num_errors);
            if (expected_waddr_q.size() > 0) begin
                $display("WARNING: Leftover EXPECTs in queue that were never written: %0d", expected_waddr_q.size());
            end
            $display("========================================");
        end
        
        $finish;
    end

    // Timeout failsafe
    initial begin
        #500000;
        $display("TIMEOUT ERROR: Simulation hung. Check state machine logic.");
        $finish;
    end

endmodule