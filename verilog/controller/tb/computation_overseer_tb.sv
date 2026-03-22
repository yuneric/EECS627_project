`timescale 1ns/1ps
// computation_overseer_tb.sv
// Verifies comp overseer + im2col against golden addr dumps from im2col_gen.py

module computation_overseer_tb;

    parameter DIM = 8, NUM_ARRAYS = 8, DIM_FIELD_WIDTH = 8;
    parameter ACT_ADDR_WIDTH = 15, WT_ADDR_WIDTH = 14, OUT_ADDR_WIDTH = 15;
    parameter WORD_IDX_WIDTH = 8, DATA_WIDTH = 32;

    reg clk, rst_n;
    initial clk = 0;
    always #5 clk = ~clk;

    reg start;
    reg [DIM_FIELD_WIDTH-1:0] cfg_tile_H, cfg_tile_W, cfg_Hf, cfg_Wf;
    reg [DIM_FIELD_WIDTH-1:0] cfg_stride, cfg_padding, cfg_Co, cfg_Ho, cfg_Wo;
    reg [WORD_IDX_WIDTH-1:0]  cfg_words_ci;
    reg cfg_relu_en, cfg_maxpool_en;

    wire [ACT_ADDR_WIDTH-1:0]           act_rd_addr;
    wire                                act_rd_en;
    reg  [DATA_WIDTH-1:0]              act_rd_data;
    wire [WT_ADDR_WIDTH*NUM_ARRAYS-1:0] wt_rd_addr;
    wire [NUM_ARRAYS-1:0]               wt_rd_en;
    reg  [DATA_WIDTH*NUM_ARRAYS-1:0]   wt_rd_data;

    wire [NUM_ARRAYS-1:0]               sa_wr_en;
    wire [DATA_WIDTH-1:0]              sa_wr_act_data;
    wire [DATA_WIDTH*NUM_ARRAYS-1:0]   sa_wr_wt_data;
    wire [NUM_ARRAYS-1:0]               sa_wr_data_last;
    reg  [NUM_ARRAYS-1:0]              sa_fifo_full;

    reg  [NUM_ARRAYS-1:0]              sa_valid_out;
    reg  [DATA_WIDTH*NUM_ARRAYS-1:0]   sa_data_out;
    reg  [NUM_ARRAYS-1:0]              sa_flush_done;

    wire [OUT_ADDR_WIDTH-1:0] out_wr_addr;
    wire                      out_wr_en;
    wire [DATA_WIDTH-1:0]    out_wr_data;
    wire [NUM_ARRAYS-1:0]    array_active;
    wire                      dut_busy, dut_done;

    computation_overseer #(
        .DIM(DIM), .NUM_ARRAYS(NUM_ARRAYS), .DIM_FIELD_WIDTH(DIM_FIELD_WIDTH),
        .ACT_ADDR_WIDTH(ACT_ADDR_WIDTH), .WT_ADDR_WIDTH(WT_ADDR_WIDTH),
        .OUT_ADDR_WIDTH(OUT_ADDR_WIDTH), .WORD_IDX_WIDTH(WORD_IDX_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .i_clk                          (clk            ),
        .i_rst_n                        (rst_n          ),
        .i_start                        (start          ),
        .i_cfg_tile_H                   (cfg_tile_H     ), 
        .i_cfg_tile_W                   (cfg_tile_W     ),
        .i_cfg_Hf                       (cfg_Hf         ), 
        .i_cfg_Wf                       (cfg_Wf         ),
        .i_cfg_stride                   (cfg_stride     ), 
        .i_cfg_padding                  (cfg_padding    ),
        .i_cfg_words_ci                 (cfg_words_ci   ),  
        .i_cfg_Co                       (cfg_Co         ), 
        .i_cfg_Ho                       (cfg_Ho         ), 
        .i_cfg_Wo                       (cfg_Wo         ),
        .i_cfg_relu_en                  (cfg_relu_en    ),
        .i_cfg_maxpool_en               (cfg_maxpool_en ),
        .o_act_rd_addr                  (act_rd_addr    ),
        .o_act_rd_en                    (act_rd_en      ),
        .i_act_rd_data                  (act_rd_data    ),
        .o_wt_rd_addr                   (wt_rd_addr     ),
        .o_wt_rd_en                     (wt_rd_en       ),
        .i_wt_rd_data                   (wt_rd_data     ),
        .o_sa_wr_en                     (sa_wr_en       ),
        .o_sa_wr_act_data               (sa_wr_act_data ),
        .o_sa_wr_wt_data                (sa_wr_wt_data  ),
        .o_sa_wr_data_last              (sa_wr_data_last),
        .i_sa_fifo_full                 (sa_fifo_full   ),
        .i_sa_valid_out                 (sa_valid_out   ),
        .i_sa_data_out                  (sa_data_out    ),
        .i_sa_flush_done                (sa_flush_done  ),
        .o_out_wr_addr                  (out_wr_addr    ),
        .o_out_wr_en                    (out_wr_en      ),
        .o_out_wr_data                  (out_wr_data    ),
        .o_array_active                 (array_active   ),
        .o_busy                         (dut_busy       ), 
        .o_done                         (dut_done       )
    );

    always @(posedge clk)
        act_rd_data <= act_rd_en ? {{(DATA_WIDTH-ACT_ADDR_WIDTH){1'b0}}, act_rd_addr} : 0;

    integer wi;
    always @(posedge clk)
        for (wi = 0; wi < NUM_ARRAYS; wi = wi + 1)
            wt_rd_data[wi*DATA_WIDTH +: DATA_WIDTH] <=
                wt_rd_en[wi] ? {wi[15:0], wt_rd_addr[wi*WT_ADDR_WIDTH +: 16]} : 0;

    // fake SA to just count pushes and spit out dummy results so the FSM can drain
    localparam SA_DELAY = 20;
    reg [NUM_ARRAYS-1:0] computing;
    reg [7:0] delay_cnt [0:NUM_ARRAYS-1];
    reg [3:0] out_cnt   [0:NUM_ARRAYS-1];
    integer si;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sa_valid_out <= 0; sa_data_out <= 0;
            sa_flush_done <= 0; computing <= 0;
            for (si = 0; si < NUM_ARRAYS; si = si + 1) begin
                delay_cnt[si] <= 0; out_cnt[si] <= 0;
            end
        end else begin
            for (si = 0; si < NUM_ARRAYS; si = si + 1) begin
                if (sa_wr_en[si] && sa_wr_data_last[si]) begin
                    computing[si] <= 1; delay_cnt[si] <= 0; out_cnt[si] <= 0;
                end
                if (computing[si]) begin
                    delay_cnt[si] <= delay_cnt[si] + 1;
                    if (delay_cnt[si] >= SA_DELAY) begin
                        if (out_cnt[si] < DIM) begin
                            sa_valid_out[si] <= 1;
                            sa_data_out[si*DATA_WIDTH +: DATA_WIDTH] <=
                                {si[7:0], 4'b0, out_cnt[si], 16'hCAFE};
                            out_cnt[si] <= out_cnt[si] + 1;
                        end else begin
                            sa_valid_out[si] <= 0;
                            sa_flush_done[si] <= 1;
                            computing[si] <= 0;
                        end
                    end
                end
                if (dut.state == 4'd3) begin // KG_SETUP resets everything
                    computing[si] <= 0; sa_valid_out[si] <= 0;
                    sa_flush_done[si] <= 0; delay_cnt[si] <= 0; out_cnt[si] <= 0;
                end
            end
        end
    end

    // golden brick comparison stuff
    integer fd, rc;
    integer g_aa, g_av, g_wa, g_wv, g_dl;  // golden values per line
    integer hdr_Hi, hdr_Wi, hdr_Hf, hdr_Wf, hdr_s, hdr_p, hdr_wci, hdr_Co;
    integer hdr_th, hdr_tv, hdr_xb, hdr_yb, hdr_total;
    integer total_errs, total_feeds_ok;
    integer aerr, werr, lerr;
    integer f_idx, tmo, kn, ksz, exp_wt_base;
    reg [8*128-1:0] fpath;

    // open a tile file, read every golden line, compare against RTL
    task check_tile(input reg [8*128-1:0] fname, input integer tidx);
        begin
            fd = $fopen(fname, "r");
            if (!fd) begin
                $display("  cant open %0s", fname);
                aerr = aerr + 1;
            end else begin
                rc = $fscanf(fd, "# %d %d %d %d %d %d %d %d %d %d %d %d %d",
                    hdr_Hi, hdr_Wi, hdr_Hf, hdr_Wf, hdr_s, hdr_p, hdr_wci, hdr_Co,
                    hdr_th, hdr_tv, hdr_xb, hdr_yb, hdr_total);
                ksz = hdr_Hf * hdr_Wf * hdr_wci;

                for (f_idx = 0; f_idx < hdr_total; f_idx = f_idx + 1) begin
                    // wait for a fifo push
                    tmo = 0;
                    while (tmo < 50000) begin
                        @(posedge clk); #1;
                        if (sa_wr_en[0]) tmo = 99999;
                        tmo = tmo + 1;
                    end

                    if (tmo == 50000) begin
                        $display("  TIMEOUT tile%0d feed%0d", tidx, f_idx);
                        aerr = aerr + 1;
                    end else begin
                        rc = $fscanf(fd, "%d %d %d %d %d", g_aa, g_av, g_wa, g_wv, g_dl);
                        kn = f_idx % DIM;
                        exp_wt_base = g_wa - kn * ksz;

                        // act addr
                        if (g_av && act_rd_addr !== g_aa[ACT_ADDR_WIDTH-1:0]) begin
                            if (aerr < 10)
                                $display("  ACT tile%0d f%0d: got %0d exp %0d", tidx, f_idx, act_rd_addr, g_aa);
                            aerr = aerr + 1;
                        end

                        // wt addr
                        if (g_wv && kn == 0 &&
                            wt_rd_addr[0 +: WT_ADDR_WIDTH] !== exp_wt_base[WT_ADDR_WIDTH-1:0]) begin
                            if (werr < 10)
                                $display("  WT tile%0d f%0d: got %0d exp %0d", tidx, f_idx,
                                    wt_rd_addr[0 +: WT_ADDR_WIDTH], exp_wt_base);
                            werr = werr + 1;
                        end

                        // data_last
                        if (sa_wr_data_last[0] !== g_dl[0]) begin
                            if (lerr < 5)
                                $display("  LAST tile%0d f%0d: got %0b exp %0b",
                                    tidx, f_idx, sa_wr_data_last[0], g_dl[0]);
                            lerr = lerr + 1;
                        end

                        total_feeds_ok = total_feeds_ok + 1;
                    end
                end
                $fclose(fd);
            end
        end
    endtask

    // configure, kick off, iterate through all tile golden files, wait for done
    task run_test(
        input [DIM_FIELD_WIDTH-1:0] tH, tW, fH, fW, s, p,
        input [WORD_IDX_WIDTH-1:0]  wci,
        input [DIM_FIELD_WIDTH-1:0] co, ho, wo,
        input integer ntiles,
        input reg [8*128-1:0] dir
    );
        integer ti, w;
        begin
            cfg_tile_H = tH; cfg_tile_W = tW;
            cfg_Hf = fH; cfg_Wf = fW;
            cfg_stride = s; cfg_padding = p;
            cfg_words_ci = wci; cfg_Co = co;
            cfg_Ho = ho; cfg_Wo = wo;
            cfg_relu_en = 0; cfg_maxpool_en = 0;
            aerr = 0; werr = 0; lerr = 0;

            @(posedge clk); start = 1;
            @(posedge clk); start = 0;
            while (!dut_busy) @(posedge clk);

            for (ti = 0; ti < ntiles; ti = ti + 1) begin
                $sformat(fpath, "%0s/tile%0d.txt", dir, ti);
                check_tile(fpath, ti);
            end

            w = 0;
            while (dut_busy && w < 500000) begin @(posedge clk); w = w + 1; end
            if (w >= 500000) begin $display("  TIMEOUT waiting for done"); aerr = aerr + 1; end

            if (aerr + werr + lerr == 0)
                $display("  PASSED");
            else
                $display("  FAILED (%0d act / %0d wt / %0d last)", aerr, werr, lerr);

            total_errs = total_errs + aerr + werr + lerr;
            rst_n = 0; repeat(3) @(posedge clk); rst_n = 1; @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("computation_overseer_tb.vcd");
        $dumpvars(0, computation_overseer_tb);
        total_errs = 0; total_feeds_ok = 0;
        rst_n = 0; start = 0; sa_fifo_full = 0;
        cfg_tile_H = 0; cfg_tile_W = 0; cfg_Hf = 0; cfg_Wf = 0;
        cfg_stride = 0; cfg_padding = 0; cfg_words_ci = 0; cfg_Co = 0;
        cfg_Ho = 0; cfg_Wo = 0; cfg_relu_en = 0; cfg_maxpool_en = 0;
        repeat(5) @(posedge clk); rst_n = 1; @(posedge clk);

        //                        tH tW fH fW  s  p wci co ho wo ntiles
        $display("\n--- default: 4x4 f=2x2 s2 p1 Co=8 ---");
        run_test(                  4, 4, 2, 2, 2, 1, 1, 8, 3, 3, 1, "co_golden_txt/default");

        $display("\n--- no_pad: 8x8 f=3x3 s1 p0 Co=4 ---");
        run_test(                  8, 8, 3, 3, 1, 0, 1, 4, 6, 6, 6, "co_golden_txt/no_pad");

        $display("\n--- stride2: 6x6 f=3x3 s2 p1 wci=2 Co=8 ---");
        run_test(                  6, 6, 3, 3, 2, 1, 2, 8, 3, 3, 2, "co_golden_txt/stride2");

        $display("\n--- big: 10x10 f=3x3 s1 p1 Co=8 ---");
        run_test(                 10,10, 3, 3, 1, 1, 1, 8,10,10,15, "co_golden_txt/big");

        $display("\n--- rect: 12x8 f=3x3 s1 p0 Co=8 ---");
        run_test(                 12, 8, 3, 3, 1, 0, 1, 8,10, 6,10, "co_golden_txt/rect");

        $display("\n--- exact4: 5x7 f=3x3 s1 p1 Co=8 ---");
        run_test(                  5, 7, 3, 3, 1, 1, 1, 8, 5, 7, 4, "co_golden_txt/exact4");

        $display("\n--- 1x1: 4x4 f=1x1 s1 p0 Co=8 ---");
        run_test(                  4, 4, 1, 1, 1, 0, 1, 8, 4, 4, 2, "co_golden_txt/1x1");

        $display("\n--- deep: 3x3 f=3x3 s1 p1 wci=3 Co=4 ---");
        run_test(                  3, 3, 3, 3, 1, 1, 3, 4, 3, 3, 1, "co_golden_txt/deep");

        $display("\n--- tiny: 3x3 f=3x3 s1 p0 Co=8 ---");
        run_test(                  3, 3, 3, 3, 1, 0, 1, 8, 1, 1, 1, "co_golden_txt/tiny");

        $display("");
        if (total_errs == 0)
            $display("ALL %0d FEEDS PASSED", total_feeds_ok);
        else
            $display("FAILED: %0d errors across %0d feeds", total_errs, total_feeds_ok);
        $finish;
    end

    initial begin #100_000_000; $display("TIMEOUT"); $finish; end

endmodule