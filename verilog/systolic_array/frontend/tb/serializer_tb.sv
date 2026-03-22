module serializer_tb;

    parameter DIM = 4;
    parameter DATA_WIDTH = 4;

    logic                       clk    ;
    logic                       rst_n  ;
    logic                       load   ;
    logic                       shift  ;
    logic [DIM*DATA_WIDTH-1:0]  par_in ;
    logic [DATA_WIDTH-1:0]      ser_out;

    serializer #(
        .DIM(DIM),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .i_clk    (clk    ),
        .i_rst_n  (rst_n  ),
        .i_load   (load   ),
        .i_shift  (shift  ),
        .i_par_in (par_in ),
        .o_ser_out(ser_out)
    );

    initial begin
        clk = 0;
        forever clk = #(`CLK_PERIOD_HALF) ~clk;
    end

    initial begin
        $monitor("time %t, rst_n %b, load: %b, shift: %b, par_in: %h, ser_out: %h\n",
        $time,
        rst_n,
        load,
        shift,
        par_in,
        ser_out);

        rst_n = 0;
        load = 0;
        shift = 0;
        par_in = '0;

        @(negedge clk);
        rst_n = 1;
        par_in = 16'h1234;
        load = 1;
        @(negedge clk);
        load = 0;
        shift = 1;
        repeat (4) @(negedge clk);
        load = 1;
        shift = 0;
        par_in = 16'h5678;
        @(negedge clk);
        load = 0;
        shift = 1;
        repeat (2) @(negedge clk);
        shift = 0;
        repeat (2) @(negedge clk);
        shift = 1;
        repeat (2) @(negedge clk);
        $finish;
    end
endmodule