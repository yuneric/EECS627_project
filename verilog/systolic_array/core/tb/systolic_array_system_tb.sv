`timescale 1ns / 1ps

module systolic_array_system_tb;

    parameter ARRAY_SIZE   = 8;
    parameter DATA_WIDTH   = 8;
    parameter PSUM_WIDTH   = 32;
    parameter OUTPUT_WIDTH = 8;
    parameter SHIFT_WIDTH  = 5;
    parameter FIFO_DEPTH   = 32; 
    parameter NUM_TESTS    = 14;
    // parameter MAX_CYCLES   = 500;

    parameter ACT_VEC_W    = DATA_WIDTH * ARRAY_SIZE;
    parameter OUT_VEC_W    = OUTPUT_WIDTH * ARRAY_SIZE;

    // For the tb
    reg clk_tb, clk_sa, rst_n;
    reg clk_en; 
    
    initial clk_en = 0;
    initial clk_tb = 0;
    initial clk_sa = 0;
    
    always #(`CLK_PERIOD_SYS_HALF) if (clk_en) clk_tb = ~clk_tb;  
    always #(`CLK_PERIOD_SA_HALF) if (clk_en) clk_sa = ~clk_sa;

    logic  [ACT_VEC_W-1:0]    input_act_wr_data;
    logic  [ACT_VEC_W-1:0]    input_weight_wr_data;
    logic                     input_data_last;
    logic                     input_wr_en;
    logic                     input_fifo_full;
    logic                     act_fifo_full, weight_fifo_full, info_fifo_full;
    assign input_fifo_full    = act_fifo_full | weight_fifo_full | info_fifo_full;

    logic  [ACT_VEC_W-1:0]    output_rd_data;
    logic                     output_rd_en;
    logic                     output_rd_empty;

    logic                      relu_en;
    logic  [SHIFT_WIDTH-1:0]   shift_by;
    logic                      maxpool_en;

    // fifo to sa_system
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] act_rd_data;
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] weight_rd_data;
    logic                             info_rd_data;
    logic [DATA_WIDTH*ARRAY_SIZE-1:0] output_wr_data;
    logic                             output_valid;

    logic act_fifo_empty, weight_fifo_empty, info_fifo_empty, output_fifo_full;
    logic data_rd_en;
    logic data_available;
    assign data_available = !act_fifo_empty && !weight_fifo_empty && !info_fifo_empty;

    // SYN TARGETS
    `ifdef SYN
    initial begin
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf", systolic_array_system_tb.dut);
    end
    `else
    initial begin
        $display("[%0t] SYN not defined, no SDF annotation", $time);
    end
    `endif

    //// APR targets
    `ifdef APR
    initial begin
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/apr/systolic_array_system/systolic_array_system.apr.sdf", systolic_array_system_tb.dut,,,"TYPICAL");
    end
    `else
    initial begin
        $display("[%0t] no SDF APR annotation", $time);
    end
    `endif
    /////// 


    systolic_array_system #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SHIFT_WIDTH(SHIFT_WIDTH)
    ) dut (
        .i_clk(clk_sa),
        .i_rst_n(rst_n),
        .i_fifo_act_data        (act_rd_data      ),
        .i_fifo_weight_data     (weight_rd_data   ),
        .i_fifo_info_data       (info_rd_data     ),
        .i_fifo_data_available  (data_available),
        .o_fifo_rd_en           (data_rd_en         ),
        .i_relu_en                (relu_en            ),
        .i_shift_by               (shift_by           ),
        .i_maxpool_en             (maxpool_en         ),
        .o_final_out              (output_wr_data     ),
        .o_final_valid            (output_valid        )
    );



    async_fifo #(.WIDTH(DATA_WIDTH*ARRAY_SIZE), .DEPTH(FIFO_DEPTH)) u_act_fifo (
        .i_rst_n   (rst_n),
        .i_wr_clk  (clk_tb),
        .i_wr_data (input_act_wr_data),
        .i_wr_en   (input_wr_en),
        .o_wr_almost_full(act_fifo_full),  // use almost full so we dont have overrun
        .i_rd_clk  (clk_sa),
        .o_rd_data (act_rd_data),
        .i_rd_en   (data_rd_en),
        .o_rd_almost_empty(act_fifo_empty) // use almost ready so we dont underrun
    );

    async_fifo #(.WIDTH(DATA_WIDTH*ARRAY_SIZE), .DEPTH(FIFO_DEPTH)) u_weight_fifo (
        .i_rst_n   (rst_n),
        .i_wr_clk  (clk_tb),
        .i_wr_data (input_weight_wr_data),
        .i_wr_en   (input_wr_en),
        .o_wr_almost_full(weight_fifo_full),
        .i_rd_clk  (clk_sa),
        .o_rd_data (weight_rd_data),
        .i_rd_en   (data_rd_en),
        .o_rd_almost_empty(weight_fifo_empty)
    );

    async_fifo #(.WIDTH(1), .DEPTH(FIFO_DEPTH)) u_info_fifo (
        .i_rst_n   (rst_n),
        .i_wr_clk  (clk_tb),
        .i_wr_data (input_data_last),
        .i_wr_en   (input_wr_en),
        .o_wr_almost_full(info_fifo_full),
        .i_rd_clk  (clk_sa),
        .o_rd_data (info_rd_data),
        .i_rd_en   (data_rd_en),
        .o_rd_almost_empty(info_fifo_empty)
    );

    async_fifo #(.WIDTH(DATA_WIDTH*ARRAY_SIZE), .DEPTH(FIFO_DEPTH)) u_output_fifo (
        .i_rst_n   (rst_n),
        .i_wr_clk  (clk_sa),
        .i_wr_data (output_wr_data),
        .i_wr_en   (output_valid),
        .o_wr_almost_full(output_fifo_full),
        .i_rd_clk  (clk_tb),
        .o_rd_data (output_rd_data),
        .i_rd_en   (output_rd_en),
        .o_rd_empty(output_rd_empty)
    );

    reg [ACT_VEC_W-1:0] act_data   [0:(ARRAY_SIZE*100)-1];
    reg [ACT_VEC_W-1:0] weight_data[0:(ARRAY_SIZE*100)-1];
    reg [OUT_VEC_W-1:0] golden_out [0:ARRAY_SIZE-1]; 
    reg [31:0]          config_data[0:5];

    // Captured outputs
    reg [OUT_VEC_W-1:0] captured_out [0:ARRAY_SIZE-1];
    integer             capture_idx;

    integer test_id;
    integer total_pass, total_fail;
    integer num_output_rows;
    integer data_len;
    integer cycle_count;
    integer write_idx;
    integer i, j;
    integer element_errors;
    integer max_cycles;
    reg signed [OUTPUT_WIDTH-1:0] got_elem, exp_elem;

    // For file loading
    reg [256*8-1:0] act_filename;
    reg [256*8-1:0] weight_filename;
    reg [256*8-1:0] golden_filename;
    reg [256*8-1:0] config_filename;



    initial begin
        $dumpfile("tb_systolic_system.vcd");
        $dumpvars(0, systolic_array_system_tb);
        $display("clk_tb: %f ns", `CLK_PERIOD_SYS_HALF);
        $display("clk_sa: %f ns", `CLK_PERIOD_SA_HALF);

        //$sdf_annotate("systolic_array_system.apr.sdf", dut);

        total_pass = 0;
        total_fail = 0;

        // ---- Run all tests ----
        rst_n                = 0;
        input_wr_en          = 0;
        input_act_wr_data    = 0;
        input_weight_wr_data = 0;
        input_data_last      = 0;
        capture_idx          = 0;
        
        // --- NEW CLOCK-DELAYED RESET SEQUENCE ---
        #50;          // Wait 50ns with clocks completely dead
        rst_n = 1;    // De-assert reset
        #50;          // Wait another 50ns (massively satisfies the 1ns fake limit)
        clk_en = 1;   // NOW start the clocks!
        
        repeat (2) @(negedge clk_tb); // Wait a couple cycles before starting tests
        // ----------------------------------------
        
        for (test_id = 0; test_id < NUM_TESTS; test_id = test_id + 1) begin
            run_test(test_id);
        end

        $display("");
        $display("====================================================");
        $display("  FINAL RESULTS: %0d PASSED, %0d FAILED out of %0d",
                 total_pass, total_fail, NUM_TESTS);
        $display("====================================================");

        if (total_fail > 0)
            $display("*** SOME TESTS FAILED ***");
        else
            $display("*** ALL TESTS PASSED ***");

        $finish;
    end
    
    task run_test(input integer tid);
        begin
            $display("");
            $display("----------------------------------------------------");
            $display("  TEST %0d", tid);
            $display("----------------------------------------------------");

            // ---- Load test files ----
            $sformat(config_filename, "../../../../goldenbrick/test_vectors/test%0d_config.hex", tid);
            $sformat(act_filename,    "../../../../goldenbrick/test_vectors/test%0d_act.hex",    tid);
            $sformat(weight_filename, "../../../../goldenbrick/test_vectors/test%0d_weight.hex", tid);
            $sformat(golden_filename, "../../../../goldenbrick/test_vectors/test%0d_golden.hex", tid);

            $readmemh(config_filename, config_data);
            $readmemh(act_filename,    act_data);
            $readmemh(weight_filename, weight_data);
            $readmemh(golden_filename, golden_out);

            // Parse config
            @(posedge clk_sa);
            relu_en         = config_data[1][0];
            shift_by        = config_data[2][SHIFT_WIDTH-1:0];
            maxpool_en      = config_data[3][0];
            num_output_rows = config_data[4];
            data_len        = config_data[5];

            $display("  Config: relu=%0d, shift=%0d, maxpool=%0d, expect %0d output rows data_len=%0d",
                     relu_en, shift_by, maxpool_en, num_output_rows, data_len);

            // ---- Reset DUT ----
            input_wr_en           = 0;
            input_act_wr_data     = 0;
            input_weight_wr_data  = 0;
            input_data_last       = 0;
            capture_idx     = 0;


            // ---- Write stimulus into FIFOs ----
            write_idx = 0;
            while (write_idx < data_len) begin
                @(negedge clk_tb);
                if(write_idx % 100 == 0) begin
                    // Simulate a long delay
                    input_wr_en           = 0;
                    repeat (10) @(negedge clk_tb);
                end
                if (!input_fifo_full) begin
                    input_act_wr_data    <= act_data[write_idx];
                    input_weight_wr_data <= weight_data[write_idx];
                    input_data_last      <= (write_idx == data_len - 1) ? 1'b1 : 1'b0;
                    input_wr_en          <= 1;
                    // $display("  [cycle %0t] FIFO write %0d: act=%h weight=%h last=%0b",
                    //         $time, write_idx, act_data[write_idx], weight_data[write_idx],
                    //         (write_idx == data_len - 1));
                    write_idx = write_idx + 1;
                end else begin
                    input_wr_en <= 0;
                    // $display("  [cycle %0t] FIFO full, stalling write %0d", $time, write_idx);
                end
                // Insert a long wait
            end
            @(negedge clk_tb);
            input_wr_en <= 0;
            input_data_last <= 0;

            // ---- Wait for outputs ----
            cycle_count = 0;
            max_cycles  = data_len * 100;
            output_rd_en = 0;
            while (capture_idx < num_output_rows && cycle_count < max_cycles) begin
                @(negedge clk_tb);
                if(!output_rd_empty) begin
                    output_rd_en = 1;
                    captured_out[capture_idx] = output_rd_data;
                    $display("  [cycle %0t] Output %0d: %h",
                             $time, capture_idx, output_rd_data);
                    capture_idx = capture_idx + 1;
                    @(negedge clk_tb);
                    output_rd_en = 0;
                end
                cycle_count = cycle_count + 1;
            end
            if (capture_idx < num_output_rows) begin
                $display("  ERROR: Timeout! %0t Only captured %0d of %0d outputs,", $time,
                         capture_idx, num_output_rows);
                total_fail = total_fail + 1;
            end else begin
                // ---- Compare outputs ----
                element_errors = 0;
                for (i = 0; i < num_output_rows; i = i + 1) begin
                    for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                        got_elem = captured_out[i][j*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                        exp_elem = golden_out[i][j*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                        if (got_elem !== exp_elem) begin
                            // $display("  MISMATCH row=%0d col=%0d: got %0d (0x%h), expected %0d (0x%h)",
                            //          i, j, got_elem, got_elem, exp_elem, exp_elem);
                            element_errors = element_errors + 1;
                        end
                    end
                end

                if (element_errors == 0) begin
                    $display("  PASSED (all %0d output elements match)",
                             num_output_rows * ARRAY_SIZE);
                    total_pass = total_pass + 1;
                end else begin
                    $display("  FAILED (%0d element mismatches)", element_errors);
                    // Dump full comparison for debug
                    for (i = 0; i < num_output_rows; i = i + 1) begin
                        $display("    Row %0d: got=%h  exp=%h", i,
                                 captured_out[i], golden_out[i]);
                    end
                    total_fail = total_fail + 1;
                end
            end

            // Let things settle before next test
            repeat (10) @(negedge clk_tb);
        end
    endtask

endmodule
