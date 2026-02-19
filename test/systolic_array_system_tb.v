`timescale 1ns / 1ps

module systolic_array_system_tb;

    parameter ARRAY_SIZE   = 8;
    parameter DATA_WIDTH   = 8;
    parameter PSUM_WIDTH   = 32;
    parameter OUTPUT_WIDTH = 8;
    parameter SHIFT_WIDTH  = 5;
    parameter FIFO_DEPTH   = 4;
    parameter NUM_TESTS    = 8;
    parameter MAX_CYCLES   = 500;  // Timeout per test

    parameter ACT_VEC_W    = DATA_WIDTH * ARRAY_SIZE;
    parameter OUT_VEC_W    = OUTPUT_WIDTH * ARRAY_SIZE;

    reg clk, rst_n;
    initial clk = 0;
    always #5 clk = ~clk;  // 100 MHz

    reg  [ACT_VEC_W-1:0]    act_wr_data;
    reg  [ACT_VEC_W-1:0]    weight_wr_data;
    reg                      data_last;
    reg                      wr_en;
    wire                     fifo_full;

    reg                      relu_en;
    reg  [SHIFT_WIDTH-1:0]   shift_by;
    reg                      maxpool_en;

    wire [OUT_VEC_W-1:0]     final_out;
    wire                     final_valid;

    systolic_array_system #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SHIFT_WIDTH(SHIFT_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .act_wr_data(act_wr_data),
        .weight_wr_data(weight_wr_data),
        .data_last(data_last),
        .wr_en(wr_en),
        .fifo_full(fifo_full),
        .relu_en(relu_en),
        .shift_by(shift_by),
        .maxpool_en(maxpool_en),
        .final_out(final_out),
        .final_valid(final_valid)
    );

    reg [ACT_VEC_W-1:0] act_data   [0:ARRAY_SIZE-1];
    reg [ACT_VEC_W-1:0] weight_data[0:ARRAY_SIZE-1];
    reg [OUT_VEC_W-1:0] golden_out [0:ARRAY_SIZE-1];  // Max ARRAY_SIZE output rows
    reg [7:0]           config_data[0:4];

    // Captured outputs
    reg [OUT_VEC_W-1:0] captured_out [0:ARRAY_SIZE-1];
    integer             capture_idx;

    integer test_id;
    integer total_pass, total_fail;
    integer num_output_rows;
    integer cycle_count;
    integer write_idx;
    integer i, j;
    integer element_errors;

    reg signed [OUTPUT_WIDTH-1:0] got_elem, exp_elem;

    // For file loading
    reg [256*8-1:0] act_filename;
    reg [256*8-1:0] weight_filename;
    reg [256*8-1:0] golden_filename;
    reg [256*8-1:0] config_filename;

    initial begin
        $dumpfile("tb_systolic_system.vcd");
        $dumpvars(0, systolic_array_system_tb);

        total_pass = 0;
        total_fail = 0;

        // ---- Run all tests ----
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
            $sformat(config_filename, "../goldenbrick/test_vectors/test%0d_config.hex", tid);
            $sformat(act_filename,    "../goldenbrick/test_vectors/test%0d_act.hex",    tid);
            $sformat(weight_filename, "../goldenbrick/test_vectors/test%0d_weight.hex", tid);
            $sformat(golden_filename, "../goldenbrick/test_vectors/test%0d_golden.hex", tid);

            $readmemh(config_filename, config_data);
            $readmemh(act_filename,    act_data);
            $readmemh(weight_filename, weight_data);
            $readmemh(golden_filename, golden_out);

            // Parse config
            relu_en         = config_data[1][0];
            shift_by        = config_data[2][SHIFT_WIDTH-1:0];
            maxpool_en      = config_data[3][0];
            num_output_rows = config_data[4];

            $display("  Config: relu=%0d, shift=%0d, maxpool=%0d, expect %0d output rows",
                     relu_en, shift_by, maxpool_en, num_output_rows);

            // ---- Reset DUT ----
            rst_n        <= 0;
            wr_en        <= 0;
            act_wr_data  <= 0;
            weight_wr_data <= 0;
            data_last    <= 0;
            capture_idx  = 0;

            repeat (4) @(posedge clk);
            rst_n <= 1;
            repeat (2) @(posedge clk);

            // ---- Write stimulus into FIFOs ----
            write_idx = 0;
            while (write_idx < ARRAY_SIZE) begin
                @(posedge clk);
                if (!fifo_full) begin
                    act_wr_data    <= act_data[write_idx];
                    weight_wr_data <= weight_data[write_idx];
                    data_last      <= (write_idx == ARRAY_SIZE - 1) ? 1'b1 : 1'b0;
                    wr_en          <= 1;
                    $display("  [cycle %0t] FIFO write %0d: act=%h weight=%h last=%0b",
                             $time, write_idx, act_data[write_idx], weight_data[write_idx],
                             (write_idx == ARRAY_SIZE - 1));
                    write_idx = write_idx + 1;
                end else begin
                    wr_en <= 0;
                    $display("  [cycle %0t] FIFO full, stalling write %0d", $time, write_idx);
                end
            end
            @(posedge clk);
            wr_en <= 0;
            data_last <= 0;

            // ---- Wait for outputs ----
            cycle_count = 0;
            while (capture_idx < num_output_rows && cycle_count < MAX_CYCLES) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
                if (final_valid) begin
                    captured_out[capture_idx] = final_out;
                    $display("  [cycle %0t] Output %0d: %h",
                             $time, capture_idx, final_out);
                    capture_idx = capture_idx + 1;
                end
            end

            if (capture_idx < num_output_rows) begin
                $display("  ERROR: Timeout! Only captured %0d of %0d outputs",
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
                    // Dump full comparison for debug
                    for (i = 0; i < num_output_rows; i = i + 1) begin
                        $display("    Row %0d: got=%h  exp=%h", i,
                                 captured_out[i], golden_out[i]);
                    end
                    total_fail = total_fail + 1;
                end
            end

            // Let things settle before next test
            repeat (10) @(posedge clk);
        end
    endtask

endmodule