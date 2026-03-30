`timescale 1ns / 1ps

module systolic_array_tb;

    parameter ARRAY_SIZE = 8;
    parameter DATA_WIDTH = 8;
    parameter PSUM_WIDTH = 32;
    parameter GOLDEN_WIDTH = 8; 
    parameter CLK_PERIOD = 10;
    parameter NUM_TESTS = 8;
    integer test_idx;
    reg [256*8-1:0] file_weights, file_inputs, file_outputs;
    // File Names
    // todo: add a loo
    // loop trhough test_vectors/test*/_
    reg clk;
    reg rst_n;
    // reg weight_load;
    reg clear;
    reg compute_en;
    reg drain;
    wire [ARRAY_SIZE-1:0] out_valid_vec;

    // Hardware Interface
    reg signed [DATA_WIDTH*ARRAY_SIZE-1:0] act_in_vec;
    reg signed [DATA_WIDTH*ARRAY_SIZE-1:0] weight_in_vec;
    wire signed [PSUM_WIDTH*ARRAY_SIZE-1:0] psum_out_vec;

    reg signed [DATA_WIDTH-1:0] act_elem;
    reg signed [DATA_WIDTH-1:0] weight_elem;

    // one row of the 8×8 weight matrix B
    reg [DATA_WIDTH*ARRAY_SIZE-1:0] mem_weights [0:ARRAY_SIZE-1];
    reg [DATA_WIDTH*ARRAY_SIZE-1:0] mem_inputs [0:ARRAY_SIZE-1];

    // one row of the expected 8×8 result C = A×B
    reg [PSUM_WIDTH*ARRAY_SIZE-1:0] mem_golden [0:ARRAY_SIZE-1];  

    // Loop variables
    integer i, j, t;
    integer errors = 0;
    integer t_passed = 0;

    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .compute_en(compute_en),
        .drain(drain),
        .act_in_vec(act_in_vec),
        .weight_in_vec(weight_in_vec),
        .psum_out_vec(psum_out_vec),
        .out_valid_vec(out_valid_vec)
    );

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    initial begin
        $display("\n--- [INIT] Loading Test Vectors ---");
        for (test_idx = 0; test_idx < NUM_TESTS; test_idx = test_idx + 1) begin
            errors = 0;
            $display("\n--- Test %0d ---", test_idx);
            $sformat(file_weights, "../../../../goldenbrick/test_vectors/test%0d_weight.hex", test_idx);
            $sformat(file_inputs,  "../../../../goldenbrick/test_vectors/test%0d_act.hex", test_idx);
            $sformat(file_outputs, "../../../../goldenbrick/test_vectors/test%0d_psum_golden.hex", test_idx);

            $readmemh(file_weights, mem_weights);
            $readmemh(file_inputs, mem_inputs);
            $readmemh(file_outputs, mem_golden);
            $display("Loaded Input Vec: %h %h %h %h", mem_inputs[0], mem_inputs[1], mem_inputs[2], mem_inputs[3]);
            $display("Loaded Expected:  %h %h %h %h", mem_golden[0], mem_golden[1], mem_golden[2], mem_golden[3]);

            rst_n = 0;
            //weight_load = 0;
            act_in_vec = 0;
            weight_in_vec = 0;

            #(CLK_PERIOD*2);
            rst_n = 1;
            
            $display("\n--- [PHASE 1] Clear Accumulators ---");

            @(negedge clk);
            rst_n = 1;
            clear = 1;
            act_in_vec = 0;
            weight_in_vec = 0;

            @(posedge clk);
            @(negedge clk);
            clear = 0;

            #(CLK_PERIOD);

            $display("\n--- [PHASE 2] Streaming Inputs & Checking ---");

            fork
                begin
                    // 23 cycles for ther computation 8*3 - 1
                    for (t = 0; t < (3*ARRAY_SIZE - 1); t = t + 1) begin
                        @(negedge clk);
                        // loading into the registers so ignore hte first cycle
                        compute_en = (t != 0);
                        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                            if ((t >= i) && ((t - i) < ARRAY_SIZE))
                                act_in_vec[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] = mem_inputs[i][(t - i)*DATA_WIDTH +: DATA_WIDTH];
                            else
                                act_in_vec[(i+1)*DATA_WIDTH-1 -: DATA_WIDTH] = 0;
                        end

                        for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                            if ((t >= j) && ((t - j) < ARRAY_SIZE))
                                weight_in_vec[(j+1)*DATA_WIDTH-1 -: DATA_WIDTH] = mem_weights[j][(t - j)*DATA_WIDTH +: DATA_WIDTH];
                            else
                                weight_in_vec[(j+1)*DATA_WIDTH-1 -: DATA_WIDTH] = 0;
                        end
                    end

                    @(negedge clk);
                    compute_en = 0;
                    act_in_vec = 0;
                    weight_in_vec = 0;

                    end

                begin
                    wait_cycles(3*ARRAY_SIZE);

                    @(negedge clk);
                    drain = 1;
                    #1;
                    check_row(0, mem_golden[0]);

                    for (j = 1; j < ARRAY_SIZE-1; j = j + 1) begin
                        @(posedge clk);
                        #1;
                        check_row(j, mem_golden[j]);
                    end

                    @(negedge clk);
                    drain = 0;
                end
            join

            #(CLK_PERIOD * 5);
            if (errors == 0) begin
                $display("\n[SUCCESS] All checks passed! Hardware matches Python Golden Brick.");
                t_passed = t_passed + 1;
            end else
                $display("\n[FAILURE] Found %0d mismatches.", errors);
        end

        $display("\n========== SUMMARY: %0d / %0d tests passed ==========", t_passed, NUM_TESTS);
        $finish;
    end

    task wait_cycles(input integer n);
        repeat(n) @(posedge clk);
    endtask

    task check_row;
        input integer row_idx;
        input [PSUM_WIDTH*ARRAY_SIZE-1:0] expected_val;
        begin
            if (psum_out_vec !== expected_val) begin
                $display("[FAIL] Row %0d", row_idx);
                errors = errors + 1;
                $display("Expected: %h", expected_val);
                $display("Got: %h", psum_out_vec);
            end else begin
                $display("[PASS] Row %0d | %h", row_idx, psum_out_vec);
            end
        end
    endtask

endmodule
