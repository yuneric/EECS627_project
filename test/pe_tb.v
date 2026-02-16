`timescale 1ns/1ps

module pe_tb;

    reg         clk;
    reg         rst_n;
    reg         clear;
    reg         compute_en;
    reg         drain;
    reg  signed [7:0]  act_in;
    reg  signed [7:0]  weight_in;

    wire signed [15:0] psum_out;
    wire signed [7:0]  weight_out;
    wire signed [7:0]  act_out;
    wire               out_valid;

    pe #(
        .DATA_WIDTH(8),
        .PSUM_WIDTH(16)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .act_in(act_in),
        .weight_in(weight_in),
        .clear(clear),
        .compute_en(compute_en),
        .drain(drain),
        .weight_out(weight_out),
        .act_out(act_out),
        .psum_out(psum_out),
        .out_valid(out_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass = 0;
    integer fail = 0;

    initial begin
        rst_n = 0;
        clear = 0;
        compute_en = 0;
        drain = 0;
        weight_in = 0;
        act_in = 0;

        #20;
        rst_n = 1;
        #10;

        // ---- Test 1: 10*3 + 5*3 = 45 
        @(posedge clk);
        clear = 1;
        weight_in = 8'sd3;
        act_in = 8'sd10;

        @(posedge clk);
        clear = 0;
        compute_en = 1;
        weight_in = 8'sd3;
        act_in = 8'sd5;
        // adds 10*3=30
        drain = 1;

        @(posedge clk); @(posedge clk);
        if (psum_out == 16'sd45 && out_valid == 1) begin
            pass = pass + 1;
        end else begin
            fail = fail + 1;
        end

        @(posedge clk);
        drain = 0;

        // ---- Test 2: 2*4 + 8*4 = 40
        @(posedge clk);
        clear = 1;
        weight_in = 8'sd4;
        act_in = 8'sd2;

        @(posedge clk);
        clear = 0;
        compute_en = 1;
        weight_in = 8'sd4;
        act_in = 8'sd8;
        // adds 2*4=8

        @(posedge clk);
        compute_en = 1;
        weight_in = 8'sd4;
        act_in = 0;
        // adds 8*4=32, psum=40

        @(posedge clk);
        compute_en = 0;
        drain = 1;
        weight_in = 8'sd4;
        act_in = 0;

        @(posedge clk);
        if (psum_out == 16'sd40 && out_valid == 1) begin
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

endmodule
