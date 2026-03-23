`timescale 1ns/1ps
module im2col_gen_tb;

    parameter DIM                = 8 ;       // systolic array dimension
    parameter NUM_ARRAYS         = 8 ;       // number of systolic arrays
    parameter DIM_WIDTH          = 10;       // bit-width of dimension fields (Updated to 10 bits)
    parameter MEM_IF_ADDR_WIDTH  = 12;       // activation SRAM address width (Updated to 12 bits)
    parameter WT_ADDR_WIDTH      = 11;       // weight SRAM address width (Updated to 11 bits)
    parameter WORD_SIZE          = 64;       // data word size


    logic                         clk                         ;
    logic                         rst_n                       ;
    logic [DIM_WIDTH-1:0]         cfg_tile_H                  ;
    logic [DIM_WIDTH-1:0]         cfg_tile_W                  ;
    logic [DIM_WIDTH-1:0]         cfg_Hf                      ;
    logic [DIM_WIDTH-1:0]         cfg_Wf                      ;
    logic [1:0]                   cfg_stride                  ;
    logic [1:0]                   cfg_padding                 ;
    logic [DIM_WIDTH-1:0]         cfg_words_ci                ;
    logic [DIM_WIDTH-1:0]         cfg_curr_kernel_group       ;
    logic [DIM_WIDTH-1:0]         cfg_num_kernels_per_group   ;
    logic [DIM_WIDTH-1:0]         cfg_sub_tile_x              ;
    logic [DIM_WIDTH-1:0]         cfg_sub_tile_y              ;
    logic [1:0]                   cfg_x_bound                 ;
    logic                         cfg_y_bound                 ;
    logic                         im2col_start                ;
    logic                         fifo_full                   ;
    logic [MEM_IF_ADDR_WIDTH-1:0] act_addr                    ;
    logic                         act_valid                   ;
    logic [WT_ADDR_WIDTH-1:0]     wt_addr                     ;
    logic [NUM_ARRAYS-1:0]        wt_valid                    ;
    logic                         push_en                     ;
    logic                         im2col_done                 ;

    initial clk = 0;
    always #`CLK_PERIOD_SYS_HALF clk = ~clk;

    im2col_gen #(
        .DIM                (DIM              ),       // systolic array dimension
        .NUM_ARRAYS         (NUM_ARRAYS       ),       // number of systolic arrays
        .DIM_WIDTH          (DIM_WIDTH        ),       // bit-width of dimension fields (Updated to 10 bits)
        .MEM_IF_ADDR_WIDTH  (MEM_IF_ADDR_WIDTH),       // activation SRAM address width (Updated to 12 bits)
        .WT_ADDR_WIDTH      (WT_ADDR_WIDTH    )        // weight SRAM address width (Updated to 11 bits)
    )
    dut (
        .i_clk                      (clk                      ),
        .i_rst_n                    (rst_n                    ),
        .i_cfg_tile_H               (cfg_tile_H               ),
        .i_cfg_tile_W               (cfg_tile_W               ),
        .i_cfg_Hf                   (cfg_Hf                   ),
        .i_cfg_Wf                   (cfg_Wf                   ),
        .i_cfg_stride               (cfg_stride               ),
        .i_cfg_padding              (cfg_padding              ),
        .i_cfg_words_ci             (cfg_words_ci             ),
        .i_cfg_curr_kernel_group    (cfg_curr_kernel_group    ),
        .i_cfg_num_kernels_per_group(cfg_num_kernels_per_group),
        .i_cfg_sub_tile_x           (cfg_sub_tile_x           ),
        .i_cfg_sub_tile_y           (cfg_sub_tile_y           ),
        .i_cfg_x_bound              (cfg_x_bound              ),
        .i_cfg_y_bound              (cfg_y_bound              ),
        .i_im2col_start             (im2col_start             ),
        .i_fifo_full                (fifo_full                ),
        .o_act_addr                 (act_addr                 ),
        .o_act_valid                (act_valid                ),
        .o_wt_addr                  (wt_addr                  ),
        .o_wt_valid                 (wt_valid                 ),
        .o_push_en                  (push_en                  ),
        .o_im2col_done              (im2col_done              )
    );

    integer stim_fd, out_fd;
    integer total, correct_total;
    integer line_num, num_errs;

    
    initial begin
        $fsdbDumpfile("im2col_gen_tb.fsdb");
        $fsdbDumpvars(0, im2col_gen_tb, "+all");
        stim_fd = $fopen("im2col_test.txt", "r");
        out_fd = $fopen("im2col_test.out", "w");
        `ifdef SYN
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/im2col/im2col_gen.syn.sdf", im2col_gen_tb.dut);
        `endif
    end

    initial begin
        rst_n        = 1;
        fifo_full    = 0;
        im2col_start = 0;
        line_num = 0;
        num_errs = 0;
        @(negedge clk);
        rst_n = 0;

        while(!$feof(stim_fd)) begin
            // Read the tile header
            total = 0;
            line_num = line_num + 1;
            $fscanf(stim_fd, "cfg_tile_H: %h cfg_tile_W: %h cfg_Hf: %h cfg_Wf: %h cfg_stride: %b cfg_padding: %b cfg_words_ci: %h cfg_curr_kernel_group: %h cfg_num_kernels_per_group: %h cfg_sub_tile_x: %h cfg_sub_tile_y: %h cfg_x_bound: %b cfg_y_bound: %b total: %d\n",
                             cfg_tile_H,
                             cfg_tile_W,
                             cfg_Hf,
                             cfg_Wf,
                             cfg_stride, 
                             cfg_padding, 
                             cfg_words_ci,
                             cfg_curr_kernel_group,
                             cfg_num_kernels_per_group,
                             cfg_sub_tile_x,
                             cfg_sub_tile_y,
                             cfg_x_bound,
                             cfg_y_bound,
                             correct_total
                            );
            $fwrite(out_fd, "cfg_tile_H: %h cfg_tile_W: %h cfg_Hf: %h cfg_Wf: %h cfg_stride: %b cfg_padding: %b cfg_words_ci: %h cfg_curr_kernel_group: %h cfg_num_kernels_per_group: %h cfg_sub_tile_x: %h cfg_sub_tile_y: %h cfg_x_bound: %b cfg_y_bound: %b total: %d\n",
                             cfg_tile_H,
                             cfg_tile_W,
                             cfg_Hf,
                             cfg_Wf,
                             cfg_stride, 
                             cfg_padding, 
                             cfg_words_ci,
                             cfg_curr_kernel_group,
                             cfg_num_kernels_per_group,
                             cfg_sub_tile_x,
                             cfg_sub_tile_y,
                             cfg_x_bound,
                             cfg_y_bound,
                             correct_total
                            );
            @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            im2col_start = 1;
            @(negedge clk);
            im2col_start = 0;
            wait(im2col_done);
            repeat(5) @(negedge clk);
            if(total != correct_total) begin
                $display("ERROR: Incorrect number of valid outputs");
                $display("actual: %d expected: %d", total, correct_total);
            end
        end
        $display("NUM_ERRS: %d", num_errs);
        if(num_errs == 0) begin
            $display("Passed!!!!!!!");
        end
        $finish;
    end

    logic [MEM_IF_ADDR_WIDTH-1:0] correct_act_addr ;
    logic                         correct_act_valid;
    logic [MEM_IF_ADDR_WIDTH-1:0] correct_wt_addr  ;
    logic [NUM_ARRAYS-1:0]        correct_wt_valid ;
    logic                         correct_im2col_done;

    always @(posedge clk) begin
        if(push_en) begin
            total = total + 1;
            line_num = line_num + 1;
            $fscanf(stim_fd, "%h %b %h %b %b\n",
                             correct_act_addr,
                             correct_act_valid,
                             correct_wt_addr,
                             correct_wt_valid,
                             correct_im2col_done
                            );
            if(act_valid != correct_act_valid) begin
                $display("ERROR: Incorrect act valid @output # %d", line_num);
                $display("actual: %h expected: %h", act_valid, correct_act_valid);
                num_errs += 1;
            end 
            if((act_valid == 1) && (correct_act_valid == 1) && (act_addr != correct_act_addr)) begin
                $display("ERROR: Incorrect act addr @output # %d", line_num);
                $display("actual: %h expected: %h", act_addr, correct_act_addr);
                num_errs += 1;
            end
            if(wt_valid != correct_wt_valid) begin
                $display("ERROR: Incorrect wt valid @output # %d", line_num);
                $display("actual: %h expected: %h", wt_valid, correct_wt_valid);
                num_errs += 1;
            end 
            if((wt_valid == 1) && (correct_wt_valid == 1) && (wt_addr != correct_wt_addr[WT_ADDR_WIDTH-1:0])) begin
                $display("ERROR: Incorrect wt addr @output # %d", line_num);
                $display("actual: %h expected: %h", wt_addr, correct_wt_addr);
                num_errs += 1;
            end
            if(im2col_done != correct_im2col_done) begin
                $display("ERROR: Incorrect done assertion @output # %d", line_num);
                $display("actual: %h expected: %h", im2col_done, correct_im2col_done);
                num_errs += 1;
            end 
            $fwrite(out_fd, "%h %b %h %b %b\n",
                             act_addr,
                             act_valid,
                             wt_addr,
                             wt_valid,
                             im2col_done
                            );
        end
    end

    initial begin #30000000; $display("TIMEOUT"); $finish; end

endmodule
