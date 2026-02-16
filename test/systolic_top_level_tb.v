`timescale 1ns/1ps

module systolic_backend_tb;

    parameter ARRAY_SIZE   = 8;
    parameter PSUM_WIDTH   = 32;
    parameter OUTPUT_WIDTH = 8;
    parameter SHIFT_WIDTH  = 5;
    parameter TEST_LEN     = 48;

    parameter FILE_IN    = "tb_in_data.hex";
    parameter FILE_SCALE = "tb_exp_scale.hex";
    parameter FILE_OUT   = "tb_results.txt";

    reg clk;
    reg rst_n;
    
    reg  [ARRAY_SIZE*PSUM_WIDTH-1:0]  data_in_flat;
    reg                               valid_in;
    reg                               relu_en;
    reg                               maxpool_en;
    reg  [SHIFT_WIDTH-1:0]            shift_by;

    wire [ARRAY_SIZE*PSUM_WIDTH-1:0]   relu_res;
    wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0] scale_res;
    reg  [ARRAY_SIZE*OUTPUT_WIDTH-1:0] scale_res_reg;
    reg                                scale_val;
    wire [ARRAY_SIZE*OUTPUT_WIDTH-1:0] pool_res;
    wire                               pool_val;

    reg [PSUM_WIDTH-1:0]   mem_in      [0:TEST_LEN-1][0:ARRAY_SIZE-1];
    reg [OUTPUT_WIDTH-1:0] mem_exp_scl [0:TEST_LEN-1][0:ARRAY_SIZE-1];
    
    integer i, j;
    integer err_count = 0;
    integer fd;
    
    relu #(
        .ARRAY_SIZE(ARRAY_SIZE), 
        .PSUM_WIDTH(PSUM_WIDTH)
    ) u_relu (
        .en(relu_en),
        .psum_in_vec(data_in_flat),
        .relu_out_vec(relu_res)
    );

    scale_clip #(
        .ARRAY_SIZE(ARRAY_SIZE), 
        .PSUM_WIDTH(PSUM_WIDTH), 
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .SHIFT_WIDTH(SHIFT_WIDTH)
    ) u_scale (
        .shift_by(shift_by),
        .psum_in_vec(relu_res),
        .scaled_vec(scale_res)
    );
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scale_res_reg <= 0;
            scale_val     <= 0;
        end else begin
            scale_res_reg <= scale_res;
            scale_val     <= valid_in;
        end
    end

    maxpooling #(
        .ARRAY_SIZE(ARRAY_SIZE), 
        .OUTPUT_WIDTH(OUTPUT_WIDTH)
    ) u_pool (
        .clk(clk), 
        .rst_n(rst_n),
        .en(maxpool_en),
        .data_in(scale_res_reg),
        .valid_in(scale_val),
        .data_out(pool_res),
        .valid_out(pool_val)
    );

    always #5 clk = ~clk;

    // =========================================================================
    // Golden Brick Test Configuration
    // =========================================================================
    // Test 0: Idx  0- 7, relu=0, shift=0
    // Test 1: Idx  8-15, relu=1, shift=0
    // Test 2: Idx 16-23, relu=0, shift=0
    // Test 3: Idx 24-31, relu=1, shift=0
    // Test 4: Idx 32-39, relu=0, shift=0
    // Test 5: Idx 40-47, relu=1, shift=0
    // =========================================================================
    
    task set_test_config;
        input integer idx;
        begin
            // Determine which test group this index belongs to
            if (idx < 8) begin
                // Test 0: relu=0, shift=0
                relu_en  = 0;
                shift_by = 0;
            end else if (idx < 16) begin
                // Test 1: relu=1, shift=0
                relu_en  = 1;
                shift_by = 0;
            end else if (idx < 24) begin
                // Test 2: relu=0, shift=0
                relu_en  = 0;
                shift_by = 0;
            end else if (idx < 32) begin
                // Test 3: relu=1, shift=0
                relu_en  = 1;
                shift_by = 0;
            end else if (idx < 40) begin
                // Test 4: relu=0, shift=0
                relu_en  = 0;
                shift_by = 0;
            end else begin
                // Test 5: relu=1, shift=0
                relu_en  = 1;
                shift_by = 0;
            end
            
            maxpool_en = 1;
        end
    endtask

    initial begin
        $dumpfile("backend_verify.vcd");
        $dumpvars(0, systolic_backend_tb);

        fd = $fopen(FILE_OUT, "w");
        if (fd == 0) begin
            $display("ERROR: Could not open output file %s", FILE_OUT);
            $finish;
        end

        $readmemh(FILE_IN, mem_in);
        $readmemh(FILE_SCALE, mem_exp_scl);

        clk = 0;
        rst_n = 0;
        valid_in = 0;
        data_in_flat = 0;
        relu_en = 0;
        maxpool_en = 0;
        shift_by = 0;

        #20 rst_n = 1;

        $display("=== Starting Backend Verification ===");
        $display("(ReLU enabled/disabled per test group to match golden brick)");
        $display("");
        $display("Idx | ReLU | DUT Output                       | Golden Brick Expected            | Match");
        $display("----|------|----------------------------------|----------------------------------|------");
        
        $fwrite(fd, "=== Backend Verification Results ===\n\n");
        $fwrite(fd, "Idx | ReLU | DUT Output                       | Golden Brick Expected            | Match\n");
        $fwrite(fd, "----|------|----------------------------------|----------------------------------|------\n");

        for (i = 0; i < TEST_LEN; i = i + 1) begin
            
            set_test_config(i);
            
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin
                data_in_flat[j*PSUM_WIDTH +: PSUM_WIDTH] = mem_in[i][j];
            end
            
            valid_in = 1; 
            @(posedge clk);
            #1; 
            valid_in = 0; 
            
            display_and_check(i);
        end

        $display("");
        $display("=== Test Complete. Total Errors: %0d / %0d ===", err_count, TEST_LEN * ARRAY_SIZE);
        
        $fwrite(fd, "\n=== Test Complete. Total Errors: %0d / %0d ===\n", err_count, TEST_LEN * ARRAY_SIZE);
        
        $fclose(fd);
        $finish;
    end

    task display_and_check;
        input integer idx;
        reg [OUTPUT_WIDTH-1:0] dut_val;
        reg [OUTPUT_WIDTH-1:0] exp_val;
        reg signed [OUTPUT_WIDTH-1:0] dut_signed;
        reg signed [OUTPUT_WIDTH-1:0] exp_signed;
        integer b;
        integer match;
        begin
            match = 1;
            
            if (scale_val !== 1) begin
                $display("Error at Index %0d: Valid signal missing", idx);
                $fwrite(fd, "Error at Index %0d: Valid signal missing\n", idx);
                err_count = err_count + 1;
            end
            
            $write("%3d |  %0d   | ", idx, relu_en);
            $fwrite(fd, "%3d |  %0d   | ", idx, relu_en);
            
            for (b = 0; b < ARRAY_SIZE; b = b + 1) begin
                dut_val = scale_res_reg[b*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                dut_signed = dut_val;
                $write("%4d ", dut_signed);
                $fwrite(fd, "%4d ", dut_signed);
            end
            
            $write("| ");
            $fwrite(fd, "| ");
            
            for (b = 0; b < ARRAY_SIZE; b = b + 1) begin
                exp_val = mem_exp_scl[idx][b];
                exp_signed = exp_val;
                $write("%4d ", exp_signed);
                $fwrite(fd, "%4d ", exp_signed);
                
                dut_val = scale_res_reg[b*OUTPUT_WIDTH +: OUTPUT_WIDTH];
                if (dut_val !== exp_val) begin
                    match = 0;
                    err_count = err_count + 1;
                end
            end
            
            if (match) begin
                $write("| PASS");
                $fwrite(fd, "| PASS");
            end else begin
                $write("| FAIL <--");
                $fwrite(fd, "| FAIL <--");
            end
            
            $write("\n");
            $fwrite(fd, "\n");
        end
    endtask

endmodule