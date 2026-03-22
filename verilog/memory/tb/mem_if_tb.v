module mem_if_tb ();

    // Parameters
    parameter ADDR_WIDTH = 12;
    parameter DATA_WIDTH = 64;

    // Clock and Control
    logic i_clk;
    logic i_bank_sel;

    // MMU Interface
    logic [ADDR_WIDTH-1:0] i_mmu_waddr;
    logic                  i_mmu_wen;
    logic [DATA_WIDTH-1:0] i_mmu_wdata;
    logic [ADDR_WIDTH-1:0] i_mmu_raddr;
    logic                  i_mmu_ren;
    logic [DATA_WIDTH-1:0] o_mmu_rdata;

    // Compute Interface
    logic [ADDR_WIDTH-1:0] i_comp_waddr;
    logic                  i_comp_wen;
    logic [DATA_WIDTH-1:0] i_comp_wdata;
    logic [ADDR_WIDTH-1:0] i_comp_raddr;
    logic                  i_comp_ren;
    logic [DATA_WIDTH-1:0] o_comp_rdata;

    mem_if #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
        .i_clk(i_clk),
        
        .i_mmu_waddr(i_mmu_waddr),
        .i_mmu_wen(i_mmu_wen),
        .i_mmu_wdata(i_mmu_wdata),

        .i_mmu_raddr(i_mmu_raddr),
        .i_mmu_ren(i_mmu_ren),
        .o_mmu_rdata(o_mmu_rdata),
        
        .i_comp_waddr(i_comp_waddr),
        .i_comp_wen(i_comp_wen),
        .i_comp_wdata(i_comp_wdata),

        .i_comp_raddr(i_comp_raddr),
        .i_comp_ren(i_comp_ren),
        .o_comp_rdata(o_comp_rdata),
        
        .i_bank_sel(i_bank_sel)
    );

    initial begin
        i_clk = 0;
        forever #(`CLK_PERIOD_HALF) i_clk = ~i_clk;    
    end

    initial begin
        i_bank_sel    = 0;
        
        i_mmu_waddr   = 0;
        i_mmu_wdata   = 0;
        i_mmu_wen     = 1; 

        i_mmu_raddr   = 0;
        i_mmu_ren     = 1; 
        
        i_comp_waddr  = 0;
        i_comp_wdata  = 0;
        i_comp_wen    = 1;

        i_comp_raddr  = 0;
        i_comp_ren    = 1;


        $display("---\nWrite to same spot in bank, make sure both are valid\n---");
        @(negedge i_clk)
        i_bank_sel = 0;
        i_mmu_waddr = 12'h111;
        i_mmu_wdata = 64'd919191;
        i_mmu_wen = 0;

        i_comp_waddr = 12'h222;
        i_comp_wdata = 64'd727272;
        i_comp_wen = 0;

        $display("BANK SEL = %b", i_bank_sel);
        $display("MMU  Write Addr = %h Data = %d", i_mmu_waddr, i_mmu_wdata);
        $display("Comp Write Addr = %h Data = %d", i_comp_waddr, i_comp_wdata);
        @(negedge i_clk)
        i_bank_sel = 1;
        i_mmu_waddr = 12'h111;
        i_mmu_wdata = 64'd111222333;
        i_mmu_wen = 0;

        i_comp_waddr = 12'h222;
        i_comp_wdata = 64'd444555666;
        i_comp_wen = 0;

        @(negedge i_clk)
        $display("BANK SEL = %b", i_bank_sel);
        $display("MMU  Write Addr = %h Data = %d", i_mmu_waddr, i_mmu_wdata);
        $display("Comp Write Addr = %h Data = %d", i_comp_waddr, i_comp_wdata);
        i_bank_sel = 0;
        i_mmu_wen  = 1;
        i_comp_wen = 1;

        i_comp_ren = 0;
        i_mmu_ren  = 0;

        i_comp_raddr = i_mmu_waddr;
        i_mmu_raddr = i_comp_waddr;

        @(negedge i_clk)
        $display("BANK SEL = %b", i_bank_sel);
        $display("Comp Read Addr = %h Data = %d", i_comp_raddr, o_comp_rdata);
        $display("MMU  Read Addr = %h Data = %d", i_mmu_raddr, o_mmu_rdata);
        i_bank_sel = 1;

        @(negedge i_clk)
        $display("BANK SEL = %b", i_bank_sel);
        $display("Comp Read Addr = %h Data = %d", i_comp_raddr, o_comp_rdata);
        $display("MMU  Read Addr = %h Data = %d", i_mmu_raddr, o_mmu_rdata);

        i_comp_ren = 1;
        i_mmu_ren  = 1;

        $display("---\nTesting some random gobbledegook\n---");
        @(negedge i_clk)
        i_mmu_waddr = 12'h111;
        i_mmu_wdata = 64'd1234;
        i_mmu_wen = 0;

        i_comp_waddr = 12'h222;
        i_comp_wdata = 64'd5678;
        i_comp_wen = 0;

        $display("BANK SEL = %b", i_bank_sel);
        $display("MMU  Write Addr = %h Data = %d", i_mmu_waddr, i_mmu_wdata);
        $display("Comp Write Addr = %h Data = %d", i_comp_waddr, i_comp_wdata);
        @(negedge i_clk)
        i_mmu_wen = 1;
        i_comp_wen = 1;

        i_bank_sel = 1;
        i_comp_ren = 0;
        i_mmu_ren = 0;
        i_comp_raddr = i_mmu_waddr;
        i_mmu_raddr = i_comp_waddr;

        @(negedge i_clk)
        $display("BANK SEL = %b", i_bank_sel);
        $display("Comp Read Addr = %h Data = %d", i_comp_raddr, o_comp_rdata);
        $display("MMU  Read Addr = %h Data = %d", i_mmu_raddr, o_mmu_rdata);

        i_mmu_waddr = 12'h333;
        i_mmu_wdata = 64'd11111111111;
        i_mmu_wen = 0;

        i_comp_waddr = 12'h444;
        i_comp_wdata = 64'd2222222222;
        i_comp_wen = 0;

        $display("BANK SEL = %b", i_bank_sel);
        $display("MMU  Write Addr = %h Data = %d", i_mmu_waddr, i_mmu_wdata);
        $display("Comp Write Addr = %h Data = %d", i_comp_waddr, i_comp_wdata);
        @(negedge i_clk)
        i_mmu_wen = 1;
        i_comp_wen = 1;

        i_bank_sel = 0;
        i_comp_ren = 0;
        i_mmu_ren = 0;
        i_comp_raddr = i_mmu_waddr;
        i_mmu_raddr = i_comp_waddr;

        @(negedge i_clk)
        $display("BANK SEL = %b", i_bank_sel);
        $display("Comp Read Addr = %h Data = %d", i_comp_raddr, o_comp_rdata);
        $display("MMU  Read Addr = %h Data = %d", i_mmu_raddr, o_mmu_rdata);

        $finish;
    end
endmodule