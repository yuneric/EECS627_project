`timescale 1ns/1ps

module relu_tb;

    parameter ARRAY_SIZE = 4;
    parameter PSUM_WIDTH = 16;

    reg relu_enable;
    reg signed [ARRAY_SIZE*PSUM_WIDTH-1:0] psum_in_vec;
    wire signed [ARRAY_SIZE*PSUM_WIDTH-1:0] relu_out_vec;

    integer i;
    integer pass;
    integer fail;
    integer test_fail;
    reg signed [PSUM_WIDTH-1:0] in_elem;
    reg signed [PSUM_WIDTH-1:0] out_elem;
    reg signed [PSUM_WIDTH-1:0] expected;

    relu #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .PSUM_WIDTH(PSUM_WIDTH)
    ) dut (
        // .clk(clk),
        // .rst_n(rst_n),
        .psum_in_vec(psum_in_vec),
        .en(relu_enable),
        .relu_out_vec(relu_out_vec)
    );


    task check_relu;
    begin
        test_fail = 0;
        if(relu_enable) begin
            for (i = 0; i < ARRAY_SIZE; i = i + 1) begin
                in_elem  = psum_in_vec[i*PSUM_WIDTH +: PSUM_WIDTH];
                out_elem = relu_out_vec[i*PSUM_WIDTH +: PSUM_WIDTH];
                if (in_elem < 0) begin
                    expected = {PSUM_WIDTH{1'b0}};
                end else begin
                    expected = in_elem;
                end

                if (out_elem !== expected) begin
                    test_fail = 1;
                    $display("  FAIL i=%0d in=%0d out=%0d exp=%0d", i, in_elem, out_elem, expected);
                end
            end
        end

        if (test_fail) begin
            fail = fail + 1;
        end else begin
            pass = pass + 1;
        end
    end
    endtask

    initial begin
        pass = 0;
        fail = 0;
        psum_in_vec = {ARRAY_SIZE*PSUM_WIDTH{1'b0}};
        #20;
        relu_enable = 1'b1;

        $display("Test1: Mixed");
        psum_in_vec[15:0]  =  16'sd4;
        psum_in_vec[31:16] = -16'sd3;
        psum_in_vec[47:32] =  16'sd1;
        psum_in_vec[63:48] = -16'sd9;
        #1;
        check_relu;

        $display("Test2: All zeros");
        psum_in_vec = {ARRAY_SIZE*PSUM_WIDTH{1'b0}};
        #1;
        check_relu;

        $display("Test3: All positive");
        psum_in_vec[15:0]  = 16'sd1;
        psum_in_vec[31:16] = 16'sd5;
        psum_in_vec[47:32] = 16'sd10;
        psum_in_vec[63:48] = 16'sd12;
        #1;
        check_relu;

        $display("Test4: All negative");
        psum_in_vec[15:0]  = -16'sd3;
        psum_in_vec[31:16] = -16'sd2;
        psum_in_vec[47:32] = -16'sd6;
        psum_in_vec[63:48] = -16'sd9;
        #1;
        check_relu;

        $display("Test5: Min signed");
        psum_in_vec[15:0]  = -16'sd32768;
        psum_in_vec[31:16] =  16'sd1;
        psum_in_vec[47:32] = -16'sd32768;
        psum_in_vec[63:48] =  16'sd1;
        #1;
        check_relu;

        $display("Test6: relu not enabled I guess");
        relu_enable = 1'b0;
        psum_in_vec[15:0]  = -16'sd5;
        psum_in_vec[31:16] =  16'sd10;
        psum_in_vec[47:32] = -16'sd3;
        psum_in_vec[63:48] =  16'sd7;
        #1;
        check_relu;
        relu_enable = 1'b1;

        $display("Summary: PASS=%0d FAIL=%0d", pass, fail);
        $finish;
    end

endmodule
