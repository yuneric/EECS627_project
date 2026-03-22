`timescale 1ns / 1ps
// `include "standard.vh"

module sa_slice_tb;

    parameter ARRAY_SIZE   = 8;
    parameter DATA_WIDTH   = 8;
    parameter WORD_SIZE   = 8;
    parameter PSUM_WIDTH   = 32;
    parameter OUTPUT_WIDTH = 8;
    parameter SHIFT_WIDTH  = 5;
    parameter FIFO_DEPTH   = 32; 
    parameter NUM_TESTS    = 14;
    parameter WT_ADDR_WIDTH = 11;
    localparam int DW = DATA_WIDTH * WORD_SIZE;
    localparam int ACT_VEC_W = DATA_WIDTH * ARRAY_SIZE;
    localparam int OUT_VEC_W = OUTPUT_WIDTH * ARRAY_SIZE;

    logic clk_sys, clk_sa, rst_n;

    logic [DATA_WIDTH*ARRAY_SIZE-1:0] push_act_data;
    logic                             push_data_last;
    logic                             push_en;
    logic                             push_full;

    logic                            cdc_req;
    logic                            cdc_ack;
    logic                            relu_en;
    logic [SHIFT_WIDTH-1:0]          shift_by;
    logic                            maxpool_en;

    // logic [ARRAY_SIZE*OUTPUT_WIDTH-1:0] output_wr_data;
    // logic                               output_valid;
    logic [OUT_VEC_W-1:0]               pop_data;
    logic                               pop_en;
    logic                               pop_empty;
    logic                               output_fifo_full;

    logic [WT_ADDR_WIDTH-1:0]         wt_rd_addr;
    logic                             wt_rd_en;

    logic [WT_ADDR_WIDTH-1:0]         wt_wr_addr;
    logic                             wt_wr_en;
    logic [DW-1:0]                    wt_wr_data;

    initial clk_sys = 0;
    always #`CLK_PERIOD_SYS_HALF clk_sys = ~clk_sys;

    initial clk_sa = 0;
    always #`CLK_PERIOD_SA_HALF clk_sa = ~clk_sa;

    sa_slice #(
        .ARRAY_SIZE   (ARRAY_SIZE),
        .DATA_WIDTH   (DATA_WIDTH),
        .WORD_SIZE    (WORD_SIZE),
        .PSUM_WIDTH   (PSUM_WIDTH),
        .OUTPUT_WIDTH (OUTPUT_WIDTH),
        .SHIFT_WIDTH  (SHIFT_WIDTH),
        .FIFO_DEPTH   (FIFO_DEPTH),
        .WT_ADDR_WIDTH (WT_ADDR_WIDTH)
    ) dut (
        .i_clk_sys         (clk_sys),
        .i_clk_sa          (clk_sa),
        .i_rst_n           (rst_n),
        .i_cdc_req         (cdc_req),
        .o_cdc_ack         (cdc_ack),
        .i_relu_en         (relu_en),
        .i_shift_by        (shift_by),
        .i_maxpool_en      (maxpool_en),
        .i_push_act_data   (push_act_data),
        .i_push_data_last  (push_data_last),
        .i_push_en         (push_en),
        .o_push_fifo_full  (push_full),
        .i_wt_sram_rd_addr (wt_rd_addr),
        .i_wt_sram_rd_en   (wt_rd_en),
        .i_wt_sram_wr_addr (wt_wr_addr),
        .i_wt_sram_wr_en   (wt_wr_en),
        .i_wt_sram_wr_data (wt_wr_data),
        .o_pop_data        (pop_data),
        .i_pop_en          (pop_en),
        .o_pop_empty       (pop_empty)

    );

    logic [ACT_VEC_W-1:0] act_data    [0:(ARRAY_SIZE*100)-1];
    logic [ACT_VEC_W-1:0] weight_data [0:(ARRAY_SIZE*100)-1];
    logic [OUT_VEC_W-1:0] golden_out  [0:ARRAY_SIZE-1];
    logic [31:0]          config_data [0:5];

    logic [OUT_VEC_W-1:0] captured_out [0:ARRAY_SIZE-1];
    int                   capture_idx;

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

    logic [256*8-1:0] act_filename;
    logic [256*8-1:0] weight_filename;
    logic [256*8-1:0] golden_filename;
    logic [256*8-1:0] config_filename;

    task  write_weight(input [WT_ADDR_WIDTH-1:0] addr, input [DW-1:0] data);
    begin
        @(negedge clk_sys);
        wt_wr_addr = addr;
        wt_wr_data = data;
        wt_wr_en   = 1'b1;
        @(posedge clk_sys);
        @(negedge clk_sys);
        wt_wr_en = 1'b0;
        wt_wr_addr = '0;
        wt_wr_data = '0;
    end
    endtask

    task run_test(input integer tid);
    begin
        $display("");
        $display("----------------------------------------------------");
        $display("  TEST %0d", tid);
        $display("----------------------------------------------------");

        $sformat(config_filename, "../../../../goldenbrick/test_vectors/test%0d_config.hex", tid);
        $sformat(act_filename,    "../../../../goldenbrick/test_vectors/test%0d_act.hex",    tid);
        $sformat(weight_filename, "../../../../goldenbrick/test_vectors/test%0d_weight.hex", tid);
        $sformat(golden_filename, "../../../../goldenbrick/test_vectors/test%0d_golden.hex", tid);

        $readmemh(config_filename, config_data);
        $readmemh(act_filename,    act_data);
        $readmemh(weight_filename, weight_data);
        $readmemh(golden_filename, golden_out);

        cdc_req         = 0;
        relu_en         = config_data[1][0];
        shift_by        = config_data[2][SHIFT_WIDTH-1:0];
        maxpool_en      = config_data[3][0];
        num_output_rows = config_data[4];
        data_len        = config_data[5];

        $display("  Config: relu=%0d, shift=%0d, maxpool=%0d, expect %0d output rows data_len=%0d",
                 relu_en, shift_by, maxpool_en, num_output_rows, data_len);

        rst_n       = 0;
        push_act_data = '0;
        push_data_last   = 0;
        push_en       = 0;
        pop_en      = 0;
        wt_rd_addr        = '0;
        wt_rd_en          = 0;
        wt_wr_addr        = '0;
        wt_wr_en          = 0;
        wt_wr_data        = '0;

        @(negedge clk_sys);
        repeat (10) @(negedge clk_sys);
        repeat (10) @(negedge clk_sa);
        rst_n = 1;
        @(posedge clk_sys);
        for (int r = 0; r < data_len; r++) begin
            @(negedge clk_sys);
            write_weight(r, {DW{1'b0}});
        end
        @(posedge clk_sys);
        for (int r = 0; r < data_len; r++) begin
            @(negedge clk_sys);
            write_weight(r, weight_data[r]);
        end
        @(negedge clk_sys);
        for (int r = 0; r < data_len ; r++) begin
            @(negedge clk_sys);
            wt_rd_en = 1'b1;
            wt_rd_addr = r;
            @(negedge clk_sys);
            @(negedge clk_sys);
            $display("SRAM[%0d] = %h  (wrote %h)", r, dut.weight_sram_rdata, weight_data[r]);
        end

        // Do the cdc handshake for the backend signals
        @(negedge clk_sys)
        cdc_req = 1;
        wait(cdc_ack);
        @(negedge clk_sys)
        cdc_req = 0;
        wait(~cdc_ack);

        @(negedge clk_sys);
        wt_rd_en = 1'b0;
        write_idx   = 0;
        capture_idx = 0;

        write_idx = 0;
        while (write_idx < data_len) begin
            if (write_idx % 100 == 0) begin
                push_en = 0;
                repeat (10) @(posedge clk_sys);
            end

            @(negedge clk_sys);
            wt_rd_en   = 1'b1;
            wt_rd_addr = write_idx;
            @(posedge clk_sys);

            @(negedge clk_sys);
            if (!push_full) begin
                push_act_data = act_data[write_idx];
                push_data_last   = (write_idx == data_len - 1) ? 1'b1 : 1'b0;
                push_en       = 1'b1;

                $display("  [cycle %0t] PUSH[%0d]: act=%h  wt_staged=%h",
                        $time, write_idx, act_data[write_idx], dut.staged_weight_data);


                @(posedge clk_sys);
                @(negedge clk_sys);
                push_en     = 1'b0;
                push_data_last = 1'b0;
                write_idx = write_idx + 1;
            end else begin
                push_en     = 1'b0;
                push_data_last = 1'b0;
                $display("  [cycle %0t] FIFO full, stalling write %0d", $time, write_idx);
            end
        end

        @(negedge clk_sys);
        push_en     = 1'b0;
        push_data_last = 1'b0;
        wt_rd_en        = 1'b0;

        cycle_count = 0;
        max_cycles  = data_len * 100;
        while (capture_idx < num_output_rows && cycle_count < max_cycles) begin
            @(posedge clk_sys);
            if (!pop_empty) begin
                pop_en = 1;
                captured_out[capture_idx] = pop_data;
                $display("  [cycle %0t] Output %0d: %h", $time, capture_idx, pop_data);
                capture_idx = capture_idx + 1;
                @(posedge clk_sys);
                pop_en = 0;
            end
            cycle_count = cycle_count + 1;
        end

        if (capture_idx < num_output_rows) begin
            $display("  ERROR: Timeout! Only captured %0d of %0d outputs",
                     capture_idx, num_output_rows);
            total_fail = total_fail + 1;
        end else begin
            element_errors = 0;
            for (i = 0; i < num_output_rows; i = i + 1) begin
                for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                    got_elem = captured_out[i][j*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                    exp_elem = golden_out[i][j*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                    if (got_elem !== exp_elem) begin
                        $display("  MISMATCH row=%0d col=%0d: got %0d (0x%h), expected %0d (0x%h)",
                                 i, j, got_elem, got_elem, exp_elem, exp_elem);
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
                for (i = 0; i < num_output_rows; i = i + 1) begin
                    $display("    Row %0d: got=%h  exp=%h", i,
                             captured_out[i], golden_out[i]);
                end
                total_fail = total_fail + 1;
            end
        end
        repeat (10) @(posedge clk_sys);
    end
    endtask

    `ifdef SYN
    initial begin
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", sa_slice_tb.dut);
    end
    `else
    initial begin
        $display("[%0t] SYN not defined, no SDF annotation", $time);
    end
    `endif

    initial begin
        $dumpfile("tb_sa_slice.vcd");
        $dumpvars(0, sa_slice_tb);

        total_pass = 0;
        total_fail = 0;

        // ---- Run all tests ----
        rst_n          = 0;
        push_en          = 0;
        push_act_data    = 0;
        push_data_last      = 0;
        pop_en         = 0;
        capture_idx    = 0;

        repeat (4) @(posedge clk_sys);
        rst_n = 1;
        repeat (2) @(posedge clk_sys);
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

endmodule
