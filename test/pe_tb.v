`timescale 1ns/1ps

module pe_tb;

    reg         clk;
    reg         rst_n;
    reg         weight_load;
    reg  [19:0] psum_in;
    reg  [7:0]  act_in;
    reg  [7:0]  weight_in;

    wire [19:0] psum_out;
    wire [7:0]  weight_out;
    wire [7:0]  act_out;

    pe #(
        .DATA_WIDTH(8),
        .PSUM_WIDTH(20) 
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .weight_load(weight_load),
        .psum_in(psum_in),      
        .act_in(act_in),         
        .weight_in(weight_in),
        .psum_out(psum_out),     
        .weight_out(weight_out),
        .act_out(act_out) 
    );

    initial clk = 0;
    always #5 clk = ~clk;

    // count the number of test passes
    integer pass = 0;
    integer fail = 0;

    initial begin
        rst_n = 0;
        weight_load = 0;
        weight_in = 0;
        act_in = 0;
        psum_in = 0;


        #20;
        rst_n = 1;

        #10;

        // --------- TEST 1: Weight Loading ---------
        $display("\n ========= TEST 1 ======");
        @(posedge clk);
        weight_load = 1;
        weight_in = 8'sd3;  // Load weight = 3
        
        @(posedge clk);
        weight_load = 0;

        @(posedge clk);
        weight_load = 1;
        weight_in = 8'sd8;

        
        @(posedge clk);
        if (weight_out == 8'sd8) begin
            pass = pass + 1;
        end else begin
            fail = fail + 1;
        end

        #10
        weight_load = 0;

        $display("\n ========= TEST 2 ======");
        /// weight loaded
        @(posedge clk);
        psum_in = 20'sd50;
        act_in = 8'sd10;
        // psum = 50 + (10 * 8) = 130

        @(posedge clk);
        // act passed to the right, psum passed to the bottom
        if ((act_out == 8'sd10) && (psum_out == 20'sd130)) begin
            pass = pass + 1;
        end else begin
            fail = fail + 1;
        end

        @(posedge clk);
        psum_in = 20'sd200;
        // psum = 200 + (6 * 8) = 248
        act_in = 8'sd6;


        @(posedge clk);
        // act passed to the right, psum passed to the bottom
        if ((act_out == 8'sd6) && (psum_out == 20'sd248)) begin
            pass = pass + 1;
        end else begin
            fail = fail + 1;
        end

        $display("\n=========== RESULT ========");
        $display("Number of Passed = %1d", pass);
        $display("Number of Failed = %1d", fail);

        #20;
        $finish;
    end

    initial begin
        $dumpfile("pe_tb.vcd");
        $dumpvars(0, pe_tb);
    end

endmodule
