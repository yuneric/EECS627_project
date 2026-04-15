module compute_tb;

    //Parameters
    parameter CPU_ADDR_WIDTH        = 32;
    parameter CPU_DATA_WIDTH        = 32;
    parameter NPU_ACT_ADDR_WIDTH    = 12;
    parameter NPU_WT_ADDR_WIDTH     = 11;
    parameter NPU_DATA_WIDTH        = 64;
    parameter DIM_WIDTH             = 10;
    parameter NUM_ARRAYS            = 8;

    parameter PSUM_WIDTH        = 32;
    parameter SHIFT_WIDTH       = 5;
    parameter INPUT_FIFO_DEPTH  = 16; 
    parameter INPUT_FIFO_AF_LVL = 5; // needs 4 pushes of headsup
    parameter OUTPUT_FIFO_DEPTH = 8; 

    //Clock & Reset
    logic clk_sys, clk_sa, rst_n;
    logic start_clocks;
    initial begin
        clk_sys = 0;
        // just added this because clk before reset was giving problems with gate_sim 
        wait(start_clocks);
        forever #`CLK_PERIOD_SYS_HALF clk_sys = ~clk_sys;
    end

    initial begin
        clk_sa = 0;
        wait(start_clocks);
        forever #`CLK_PERIOD_SA_HALF clk_sa = ~clk_sa;
    end

    //DUT Signals
    // Controller inputs
    logic                   comp_compute_start; //tb
    logic [1:0]             comp_stride;        //tb
    logic [1:0]             comp_padding;       //tb
    logic                   comp_maxpool_en;    //tb
    logic                   comp_relu_en;       //tb
    logic [SHIFT_WIDTH-1:0] comp_scale_amt;     //tb
    logic [DIM_WIDTH-1:0]   comp_Hi, comp_Wi;   //tb
    logic [DIM_WIDTH-1:0]   comp_Hf, comp_Wf;   //tb
    logic [DIM_WIDTH-1:0]   comp_Ho, comp_Wo;   //tb
    logic [DIM_WIDTH-1:0]   comp_words_per_channel;//tb
    logic [DIM_WIDTH-1:0]   comp_num_kernels;   //tb
    
    // Outputs to Controller / Mem_IF
    logic                           comp_done;
    logic [NPU_ACT_ADDR_WIDTH-1:0]  comp_waddr;
    logic                           comp_wen;
    logic [NPU_DATA_WIDTH-1:0]      comp_wdata;
    logic [NPU_ACT_ADDR_WIDTH-1:0]  comp_raddr;
    logic                           comp_ren;

    // SA Slice & Im2Col Signals
    logic                           cdc_req;
    logic                           cdc_ack;
    logic [NUM_ARRAYS-1:0]          cdc_ack_arrays;
    logic                           relu_en;
    logic [SHIFT_WIDTH-1:0]         shift_by;
    logic                           maxpool_en;
    logic [NPU_WT_ADDR_WIDTH-1:0]   wt_rd_addr;
    logic [NUM_ARRAYS-1:0]          wt_rd_en;
    logic [NUM_ARRAYS-1:0]          array_active;

    logic                           push_en;
    logic [NUM_ARRAYS-1:0]          push_af;
    logic [NPU_DATA_WIDTH-1:0]      push_act_data;
    logic                           push_data_last;

    // FIFO Interface
    logic [NPU_DATA_WIDTH-1:0]      pop_data [NUM_ARRAYS-1:0];
    logic [NPU_DATA_WIDTH-1:0]      pop_data_mux;
    logic [NUM_ARRAYS-1:0]          pop_en;
    //logic [NUM_ARRAYS-1:0]          pop_empty;
    logic [NUM_ARRAYS-1:0]          pop_ae;
    logic [NUM_ARRAYS-1:0]          pop_full;

    // Wt sram writing
    logic [NUM_ARRAYS-1:0]          wt_sram_sel;//tb
    logic [NPU_WT_ADDR_WIDTH-1:0]   wt_wr_addr; //tb
    logic                           wt_wr_en;   //tb
    logic [NPU_DATA_WIDTH-1:0]      wt_wr_data; //tb

    
    // Need a method to make sure data is aligned when entering the systolic array and going into the fifos
    // Takes the memorys into account, only issue is that wr_mem is accessed over a long wire
    logic                         push_data_last_d0, push_data_last_d1;
    logic                         push_en_d0, push_en_d1;
    logic [NPU_WT_ADDR_WIDTH-1:0] wt_rd_addr_d0;
    logic [NUM_ARRAYS-1:0]        wt_rd_en_d0;
    logic                         push_act_data_ren_d0;
    logic [NPU_DATA_WIDTH-1:0]    act_mem_out;             
    logic [NPU_DATA_WIDTH-1:0]    push_act_data_d1;

    always @(posedge clk_sys or negedge rst_n) begin
        if(!rst_n) begin
            push_data_last_d0 <= '0;
            push_data_last_d1 <= '0;

            push_en_d0 <= '0;
            push_en_d1 <= '0;

            wt_rd_addr_d0 <= #1 '0;
            wt_rd_en_d0   <= #1 '0;

            push_act_data_ren_d0 <= '0;
            push_act_data_d1 <= '0;
        end else begin
            push_data_last_d0 <= push_data_last;
            push_data_last_d1 <= push_data_last_d0;

            push_en_d0 <= push_en;
            push_en_d1 <= push_en_d0;

            wt_rd_addr_d0 <= wt_rd_addr;
            wt_rd_en_d0   <= wt_rd_en;

            push_act_data_ren_d0 <= comp_ren;
            push_act_data_d1     <= push_act_data_ren_d0 ? act_mem_out : '0;
        end
    end

    // logic                         dly_push_data_last_d1;
    // logic                         dly_push_en_d1;
    // logic [NPU_WT_ADDR_WIDTH-1:0] dly_wt_rd_addr_d0;
    // logic [NUM_ARRAYS-1:0]        dly_wt_rd_en_d0;
    // logic [NPU_DATA_WIDTH-1:0]    dly_push_act_data_d1;
    // logic [NPU_DATA_WIDTH-1:0]     dly_pop_data_mux;

    // always @(negedge clk_sys) begin
    //     dly_push_data_last_d1   <= push_data_last_d1;
    //     dly_push_en_d1          <= push_en_d1;
    //     dly_wt_rd_addr_d0       <= wt_rd_addr_d0;
    //     dly_wt_rd_en_d0         <= wt_rd_en_d0;
    //     dly_push_act_data_d1    <= push_act_data_d1;
    //     dly_pop_data_mux        <= pop_data_mux;
    // end


    

    always_comb begin
        pop_data_mux = pop_data[0];
        for(int array_i = 1; array_i < NUM_ARRAYS; array_i += 1) begin
            if(pop_en[array_i]) pop_data_mux = pop_data[array_i];
        end
    end

    computation_overseer #(
        .DIM(8), 
        .NUM_ARRAYS(8), 
        .DIM_WIDTH(DIM_WIDTH),
        .MEM_IF_ADDR_WIDTH(NPU_ACT_ADDR_WIDTH), 
        .WT_ADDR_WIDTH(NPU_WT_ADDR_WIDTH),
        .WORD_SIZE(NPU_DATA_WIDTH), 
        .SHIFT_WIDTH(5)
    ) dut_overseer (
        .i_clk(clk_sys), 
        .i_rst_n(rst_n),

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

        .o_cdc_req              (cdc_req),      // 1 BIT
        .i_cdc_ack              (&(cdc_ack_arrays | ~array_active)), // NUM_ARRAYS
        .o_relu_en              (relu_en),      // 1 BIT
        .o_shift_by             (shift_by),     // 5 BIT
        .o_maxpool_en           (maxpool_en),   // 1 BIT

        .o_push_en              (push_en),      // 1 BIT
        .i_push_fifo_full              (push_af),   // NUM_ARRAYS
        .o_data_last            (push_data_last),
        .o_wt_sram_rd_addr      (wt_rd_addr),  // 11 BITS
        .o_wt_sram_rd_en        (wt_rd_en),    // 1 BIT

        .i_pop_data             (pop_data_mux), 
        .o_pop_en               (pop_en),       // NUM_ARRAYS
        // .i_pop_empty            (pop_empty),    // NUM_ARRAYS
        .i_pop_almost_empty     (pop_ae),       // NUM_ARRAYS
        .i_pop_full             (pop_full),      // NUM_ARRAYS

        .o_array_active         (array_active) // NUM_ARRAYS
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
                .i_clk_sel         (3'b000),
                .i_rst_n           (rst_n),

                .i_cdc_req         (cdc_req),
                .o_cdc_ack         (cdc_ack_arrays[array_i]),
                .i_relu_en         (relu_en),
                .i_shift_by        (shift_by),
                .i_maxpool_en      (maxpool_en),

                .i_push_act_data   (push_act_data_d1     & {NPU_DATA_WIDTH{array_active[array_i]}}),
                .i_push_data_last  (push_data_last_d1    & array_active[array_i]),
                .i_push_en         (push_en_d1           & array_active[array_i]),
                .o_push_af         (push_af[array_i]),
                .i_wt_sram_rd_addr (wt_rd_addr_d0        & {NPU_WT_ADDR_WIDTH{array_active[array_i]}}),
                .i_wt_sram_rd_en   (wt_rd_en_d0[array_i] & array_active[array_i]),

                .i_wt_sram_wr_addr (wt_wr_addr & {NPU_WT_ADDR_WIDTH{wt_sram_sel[array_i]}}),
                .i_wt_sram_wr_en   (wt_wr_en   & wt_sram_sel[array_i]),
                .i_wt_sram_wr_data (wt_wr_data & {NPU_DATA_WIDTH{wt_sram_sel[array_i]}}),

                .o_pop_data        (pop_data[array_i]),
                .i_pop_en          (pop_en[array_i]),
//                .o_pop_empty       (pop_empty[array_i]),
                .o_pop_ae          (pop_ae[array_i]),
                .o_pop_full        (pop_full[array_i])

            );

            `ifdef SYN
            initial begin
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", dut_sa_slice, , "sa_slice_syn_compute_sdf.log");
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                dut_sa_slice.u_sa_sys_power_u_sa_sys, , "sa_sys_syn_compute_sdf.log");
            end
            `else
            initial begin 
                $display("[%0t] SYN not defined, annotating clock gen only", $time);
                $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/Clock_Gen/IBM130/syn/clk_gen_mode.syn.sdf", dut_sa_slice.u_clk_gen);
            end
            `endif    
        end
    endgenerate
    //FDASADAFDA
    // Error checking
    int num_tests_failed;
    int num_im2col_errors;
    int im2col_line_num;
    int num_tiling_errors;
    int num_output_writes;
    int num_output_errors;
    
    // test variables
    int test;
    int act_fd, wt_fd, im2col_fd, im2col_dut_fd, mat_fd, mat_dut_fd, tiles_fd, retval;
    int kernel_size;
    int real_Ho, real_Wo;
    int tiles_x, tiles_y;
    int num_kernel_groups;
    int num_drains;
    int num_lines_per_tile;
    int num_words_per_Co;
    int num_words_in_acts;
    int num_words_in_wts;
    int num_words_in_input;
    int num_words_in_output;

    // im2col test variables
    int                            tile_h;
    int                            tile_v;
    logic [NPU_ACT_ADDR_WIDTH-1:0] correct_act_addr ;
    logic                          correct_act_valid;
    logic [NPU_WT_ADDR_WIDTH-1:0]  correct_wt_addr  ;
    logic [NUM_ARRAYS-1:0]         correct_wt_valid ;
    logic                          correct_im2col_done;

    // sa/comp overseer test variables
    // these queues are used to check that data is going to the right place
    int                             tmp1, tmp2, tmp3, tmp4;
    logic [NPU_DATA_WIDTH-1:0]      fifo_data;
    logic [DIM_WIDTH-1:0]           y;
    logic [DIM_WIDTH-1:0]           x;
    logic [DIM_WIDTH-1:0]           ch_start;
    logic                           valid_ch;
    logic [NPU_ACT_ADDR_WIDTH-1:0]  dst_addr;

    logic [(NPU_DATA_WIDTH+NPU_ACT_ADDR_WIDTH)-1:0]  sa_fifos_correct [NUM_ARRAYS] [$]; 
    logic [NPU_DATA_WIDTH-1:0]           comp_wdata_correct_queue [$]; 
    logic [NPU_ACT_ADDR_WIDTH-1:0]       comp_wraddr_correct_queue [$]; 
    
    logic [(NPU_DATA_WIDTH+NPU_ACT_ADDR_WIDTH)-1:0]  pop_data_full_correct;
    logic [NPU_DATA_WIDTH-1:0]                       pop_data_correct;
    logic [NPU_ACT_ADDR_WIDTH-1:0]                   pop_dst_addr_correct;

    logic [NPU_DATA_WIDTH-1:0]     correct_data;
    logic [NPU_ACT_ADDR_WIDTH-1:0] correct_dst_addr;

    // memories
    logic [NPU_DATA_WIDTH-1:0] activation_mem     [4095:0];
    logic [NPU_DATA_WIDTH-1:0] golden_output_mem [4095:0];
    logic [NPU_DATA_WIDTH-1:0] output_mem        [4095:0];

    //dump file
    initial begin

        `ifdef SYN
        // $fsdbDumpfile("compute_tb.syn.fsdb");
        // $fsdbDumpvars(0, compute_tb, "+all");
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/computation_overseer/computation_overseer.syn.sdf", compute_tb.dut_overseer, , "comp_over_syn_compute_sdf.log");
            
            //sa slice
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[0].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[1].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[2].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[3].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[4].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[5].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[6].dut_sa_slice);
            // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", compute_tb.SYSTOLIC_ARRAYS[7].dut_sa_slice);
        `else
        $fsdbDumpfile("compute_tb.fsdb");
        $fsdbDumpvars(0, compute_tb, "+all");

        `endif
    end

    // Provide activation memory model 
    always @(posedge clk_sys) begin
        if(comp_ren) begin
            act_mem_out <= activation_mem[comp_raddr];
            if(comp_raddr > num_words_in_input) begin
                $display("HOUSTON WE HAVE A PROBLEM WHY IS THIS comp_raddr SO BIG");
            end
        end
    end

    // Provide output memory model 
    always @(posedge clk_sys) begin
        if(comp_wen) begin
            output_mem[comp_waddr] <= comp_wdata;
            num_output_writes += 1;
        end
    end

    //im2col checking
    always @(posedge clk_sys) begin
        if(push_en) begin
            im2col_line_num = im2col_line_num + 1;
            retval = $fscanf(im2col_fd, "%h %b %h %b %b\n",
                             correct_act_addr,
                             correct_act_valid,
                             correct_wt_addr,
                             correct_wt_valid,
                             correct_im2col_done
                            );
            if(comp_ren !== correct_act_valid) begin
                $display("IM2COL ERROR: Incorrect act valid @output # %d", im2col_line_num);
                $display("actual: %h expected: %h", comp_ren, correct_act_valid);
                num_im2col_errors += 1;
            end 
            if((comp_ren === 1) && (correct_act_valid === 1) && (comp_raddr !== correct_act_addr)) begin
                $display("IM2COL ERROR: Incorrect act addr @output # %d", im2col_line_num);
                $display("actual: %h expected: %h", comp_raddr, correct_act_addr);
                num_im2col_errors += 1;
            end
            if(wt_rd_en !== correct_wt_valid) begin
                $display("IM2COL ERROR: Incorrect wt valid @output # %d", im2col_line_num);
                $display("actual: %h expected: %h", wt_rd_en, correct_wt_valid);
                num_im2col_errors += 1;
            end 
            if((|wt_rd_en === 1) && (|correct_wt_valid === 1) && (wt_rd_addr !== correct_wt_addr)) begin
                $display("IM2COL ERROR: Incorrect wt addr @output # %d", im2col_line_num);
                $display("actual: %h expected: %h", wt_rd_addr, correct_wt_addr);
                num_im2col_errors += 1;
            end
            if(push_data_last !== correct_im2col_done) begin
                $display("IM2COL ERROR: Incorrect done assertion @output # %d", im2col_line_num);
                $display("actual: %h expected: %h", push_data_last, correct_im2col_done);
                num_im2col_errors += 1;
            end 
            $fwrite(im2col_dut_fd, "%h %b %h %b %b\n",
                             comp_raddr,
                             comp_ren,
                             wt_rd_addr,
                             wt_rd_en,
                             push_data_last
                            );
            // if(correct_im2col_done && !$feof(im2col_fd)) begin
            //     retval = $fscanf(im2col_fd, "tile: (%d,%d)", tile_v, tile_h);
            //     $fwrite(im2col_dut_fd, "tile: (%0d,%0d)\n", tile_v, tile_h);
            // end
        end
    end


    //FIFO Pop Muxing Logic
    always_ff @(negedge clk_sys or negedge rst_n) begin
        if (!rst_n) pop_data_full_correct <= '0;
        else begin
            for (int i = 0; i < NUM_ARRAYS; i++) begin
                if (pop_en[i] && sa_fifos_correct[i].size() > 0) pop_data_full_correct <= sa_fifos_correct[i].pop_front(); 

            end
        end
    end

    assign pop_data_correct = pop_data_full_correct[75:12];
    assign pop_dst_addr_correct = pop_data_full_correct[11:0];

    // Here we do sa/comp overseer checks on both data and destination address
        logic [NPU_DATA_WIDTH-1:0] last_wdata;
    logic [NPU_ACT_ADDR_WIDTH-1:0] last_waddr;
    always @(posedge clk_sys) begin
        // Add data to writeback queue when we pop from fifos (this data should appear in order at comp overseer output)
        if(|pop_en) begin
            comp_wdata_correct_queue.push_back(pop_data_correct);
            comp_wraddr_correct_queue.push_back(pop_dst_addr_correct);
        end

        // When we do a write, check the data and its destiation address
        if(comp_wen && (last_waddr !== comp_waddr)) begin
            // last_wdata <= comp_wdata;

            last_waddr <= comp_waddr;
            last_wdata <= comp_wdata;
            correct_data = comp_wdata_correct_queue.pop_front();
            correct_dst_addr = comp_wraddr_correct_queue.pop_front();
            if(correct_dst_addr !== comp_waddr) begin
                $display("OVERSEER ERROR: addr mismatch act: %d exp: %d", comp_waddr, correct_dst_addr);
                num_tiling_errors += 1;
            end
            if(correct_data !== comp_wdata) begin
                $display("OVERSEER ERROR: data mismatch act: %h exp: %h @dst_addr: %h", comp_wdata, correct_data, correct_dst_addr);
                num_tiling_errors += 1;
            end
        end
    end


    initial begin
        start_clocks = 0;
        rst_n = 0;
        comp_compute_start = 0;
        wt_sram_sel = 0;
        wt_wr_addr  = 0; 
        wt_wr_en    = 0;   
        wt_wr_data  = 0; 

        // comp_Hi <= '0;
        // comp_Wi <= '0;
        // comp_Hf <= '0;
        // comp_Wf <= '0;
        // comp_Ho <= '0;
        // comp_Wo <= '0;
        // comp_words_per_channel <= '0;
        // comp_num_kernels <= '0;
        // comp_stride <= '0;
        // comp_padding <= '0;
        // comp_maxpool_en <= '0;
        // comp_relu_en <= '0;
        // comp_scale_amt <= '0;

        // nanda
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
        comp_relu_en = '0;
        comp_scale_amt = '0;
        #1;
        start_clocks = 1;
        repeat(5) @(negedge clk_sys);
        rst_n = 1;

        // Open both files
        act_fd      = $fopen("comp_test_act.in", "r");
        wt_fd       = $fopen("comp_test_wt.in", "r");
        im2col_fd   = $fopen("comp_test_im2col.out", "r");
        im2col_dut_fd   = $fopen("comp_test_im2col_dut.out", "w");
        mat_fd      = $fopen("comp_test_mat.out", "r");
        mat_dut_fd  = $fopen("comp_test_mat_dut.out", "w");
        tiles_fd    = $fopen("comp_test_tiles.out", "r");

        
        if (!act_fd || !wt_fd || !im2col_fd || !mat_fd) begin
            $display("FATAL: Could not open one or all files.");
            $system("pwd");
            $finish;
        end

        num_tests_failed = 0;

        // Main test loop
        while(!$feof(act_fd)) begin
            @(negedge clk_sys);
            // Reset vars
            num_im2col_errors = 0;
            im2col_line_num   = 0;
            num_output_writes = 0;
            num_tiling_errors = 0;
            num_output_errors = 0;
            for(int i = 0; i < 4096; i +=1 ) begin
                output_mem[i] = '0;
                golden_output_mem[i] = '0;
            end

            // Check the header
            retval = $fscanf(act_fd,    "test: %d", test);
            retval = $fscanf(wt_fd,     "test: %d", test);
            retval = $fscanf(im2col_fd, "test: %d", test);
            //retval = $fscanf(im2col_fd, "tile: (%d,%d)", tile_v, tile_h);
            retval = $fscanf(mat_fd,    "test: %d", test);
            retval = $fscanf(tiles_fd,  "test: %d", test);

            retval = $fscanf(act_fd, "comp_Hi: %h comp_Wi: %h comp_Hf: %h comp_Wf: %h comp_Ho: %h comp_Wo: %h comp_words_per_channel: %h comp_num_kernels: %h comp_stride: %b comp_padding: %b comp_maxpool_en: %b comp_relu_en: %b comp_scale_amt: %b",
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
                    comp_maxpool_en,
                    comp_relu_en,
                    comp_scale_amt);
            
            $display("Test: %0d", test);

            $display("comp_Hi: %0d, comp_Wi: %0d", comp_Hi, comp_Wi);
            $display("comp_Hf: %0d, comp_Wf: %0d", comp_Hf, comp_Wf);
            $display("comp_Ho: %0d, comp_Wo: %0d", comp_Ho, comp_Wo);
            $display("comp_words_per_channel: %0d", comp_words_per_channel);
            $display("comp_num_kernels: %0d", comp_num_kernels);
            $display("comp_stride: %0d", comp_stride);
            $display("comp_padding: %0d", comp_padding);
            $display("comp_maxpool_en: %0d", comp_maxpool_en);
            $display("comp_relu_en: %0d", comp_relu_en);
            $display("comp_scale_amt: %0d", comp_scale_amt);


            // Calculate some necessary stuff 
            real_Wo = ((comp_Wo + 3) >> 2) << 2;
            real_Ho = ((comp_Ho + 1) >> 1) << 1;
            if(comp_maxpool_en) begin
                real_Ho = real_Ho / 2;
                real_Wo = real_Wo / 2;
            end
            $display("Original: %0dx%0d, After Tiling & Maxpool: %0dx%0d", comp_Ho, comp_Wo, real_Ho, real_Wo);

            // Read in the input activations
            num_words_in_input = comp_Hi * comp_Wi * comp_words_per_channel;
            for(int i = 0; i < num_words_in_input; i += 1) begin
                retval = $fscanf(act_fd, "%h\n", activation_mem[i]);
            end


            // Read in the weights
            num_kernel_groups = comp_num_kernels / 64;
            if(comp_num_kernels % 64 > 0) begin
                num_kernel_groups += 1;
            end
            kernel_size = comp_Hf * comp_Wf * comp_words_per_channel;
            for(int kernel_group = 0; kernel_group < num_kernel_groups; kernel_group += 1) begin
                for(int array = 0; array < NUM_ARRAYS; array += 1) begin
                    for(int word = 0; word < kernel_size*8; word += 1) begin
                        //@(posedge clk_sys); 
                        // nanda
                        @(negedge clk_sys); 
                        wt_sram_sel = '0;
                        wt_sram_sel[array] = 1;
                        wt_wr_addr  = word + 8 * kernel_size * kernel_group; 
                        wt_wr_en    = 1;   
                        retval = $fscanf(wt_fd, "%h\n", wt_wr_data);
                        // $display("wt_wr_addr: %0d", wt_wr_addr);
                        // $display("wt_wr_data: %0h", wt_wr_data);
                    end
                end
            end
            //@(posedge clk_sys); 
            @(negedge clk_sys); 
            wt_sram_sel = '0;
            wt_wr_addr  = '0; 
            wt_wr_en    = '0;   
            wt_wr_data  = '0;

            // Read in the outputs
            num_words_per_Co = ((comp_num_kernels-1) >> 3) + 1;
            $display("num_words_per_Co: %0d", num_words_per_Co);
            num_words_in_output = real_Ho * real_Wo * num_words_per_Co;
            $display("num_words_in_output: %0d", num_words_in_output);
            for(int i = 0; i < num_words_in_output; i += 1) begin
                retval = $fscanf(mat_fd, "%h\n", golden_output_mem[i]);
            end

            // Do some of the setup for output checking
            tiles_x = (comp_Wo + 3) >> 2;
            tiles_y = (comp_Ho + 1) >> 1;
            num_drains = tiles_x * tiles_y * num_kernel_groups;
            $display("num_kernel_groups: %0d", num_kernel_groups);
            $display("tiles_x: %0d", tiles_x);
            $display("tiles_y: %0d", tiles_y);
            $display("num_drains: %0d", num_drains);

            // Start our computation !!!!!
            repeat (100) @(posedge clk_sys);
            @(negedge clk_sys);
            comp_compute_start = 1;
            @(negedge clk_sys);
            comp_compute_start = 0;

            // Now we loop through all of our drains so we can check comp overseer and our sa drains
            num_lines_per_tile = 8;
            if(comp_maxpool_en) begin
                num_lines_per_tile = 2;
            end
            for(int drain = 0; drain < num_drains; drain += 1) begin
                for(int array = 0; array < 8; array += 1) begin
                    for(int line = 0; line < num_lines_per_tile; line += 1) begin
                        retval = $fscanf(tiles_fd, "%h %h %h %h %b %h", fifo_data, x, y, ch_start, valid_ch, dst_addr);
                        if(valid_ch) begin
                            //$display("SA: %0d, Line: %0d correct_data: %h", array, line, fifo_data);
                            sa_fifos_correct[array].push_back({fifo_data, dst_addr});
                        end
                    end
                end

                // Now that weve loaded this tile of data, wait for it to drain
                //$display("%t Waiting for im2col...", $time);
                wait(push_data_last);
                //$display("Waiting for drain to finish...");
                @(negedge comp_wen);
            end

            // Let the data egress Fully before we do any checking
            repeat (20) @(posedge clk_sys);

            // Final output checking
            $display("COMPARING OUTPUT MATRICES");
            $fwrite(mat_dut_fd, "test: %0d\n", test);
            for(int word = 0; word < num_words_in_output; word +=1 ) begin
                $fwrite(mat_dut_fd, "%h\n", output_mem[word]);
                if(output_mem[word] !== golden_output_mem[word]) begin
                    num_output_errors += 1;
                    $display("Mismatch at addr: %0d", word);
                    $display("act: %h exp: %h", output_mem[word], golden_output_mem[word]);
                end
            end
            //if ((num_output_errors == 0) && (num_output_writes == num_words_in_output) && (num_im2col_errors == 0) && (num_tiling_errors == 0)) begin
            if ((num_output_errors == 0) && (num_im2col_errors == 0) && (num_tiling_errors == 0)) begin
                $display("========================================");
                $display("TEST %0d PASSED! ALL DRAIN WRITES MATCH!", test);
                $display("========================================");
            end else begin
                num_tests_failed += 1;
                $display("========================================");
                $display("TEST %0d FAILED WITH", test) ;
                $display("%0d OUTPUT MISMATCHES", num_output_errors);
                $display("%0d IM2COL ERRORS", num_im2col_errors);
                $display("%0d TILING SA/COMP_OVER ERRORS", num_tiling_errors);
                $display("Num Writes act: %0d exp: %0d", num_output_writes, num_words_in_output);
                $display("========================================");
                $finish; // CALLS FINISH ON FIRST TEST THAT FAILS FOR NOW
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
        #500000000000;
        $display("TIMEOUT ERROR: Simulation hung.");
        $finish;
    end

endmodule
