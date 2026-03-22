module skew_buffer_tb;

    parameter ARRAY_SIZE = 4;
    parameter DATA_WIDTH = 4;

    logic                               clk     ;
    logic                               rst_n   ;
    logic                               clear   ;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0]   data_in ;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0]   data_in_dut ;
    logic [ARRAY_SIZE*DATA_WIDTH-1:0]   data_out;

    skew_buffer #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .i_clk    (clk    ),
        .i_rst_n  (rst_n  ),
        .i_clear   (clear   ),
        .i_data_in  (data_in_dut  ),
        .o_data_out (data_out )
    );

    initial begin
        clk = 0;
        forever clk = #(`CLK_PERIOD_HALF) ~clk;
    end

    always_ff @(posedge clk) begin
        data_in_dut <= data_in;
    end

    initial begin
        $monitor("time %t, rst_n %b, clear: %b, data_in: %h, data_out: %h\n",
        $time,
        rst_n,
        clear,
        data_in_dut,
        data_out);

        rst_n = 0;
        clear = 0;
        data_in = '0;

        @(negedge clk);
        rst_n = 1;
        data_in = 16'h1111;
        @(negedge clk);
        data_in = 16'h2222;
        @(negedge clk);
        data_in = 16'h3333;
        @(negedge clk);
        data_in = 16'h4444;
        @(negedge clk);

        repeat (4) @(negedge clk);

        
        $finish;
    end
endmodule