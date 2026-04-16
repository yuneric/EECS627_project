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

    // Sram interface
    logic                  b0_s0_cen   ;
    logic                  b0_s0_wen   ;
    logic [DATA_WIDTH-1:0] b0_s0_rdata ;
    logic [ADDR_WIDTH-1:0] b0_s0_addr  ;
    logic [DATA_WIDTH-1:0] b0_s0_wdata ;

    logic                   b0_s1_cen   ;
    logic                   b0_s1_wen   ;
    logic  [DATA_WIDTH-1:0] b0_s1_rdata ;
    logic  [ADDR_WIDTH-1:0] b0_s1_addr  ;
    logic  [DATA_WIDTH-1:0] b0_s1_wdata ;

    logic                   b1_s0_cen   ;
    logic                   b1_s0_wen   ;
    logic  [DATA_WIDTH-1:0] b1_s0_rdata ;
    logic  [ADDR_WIDTH-1:0] b1_s0_addr  ;
    logic  [DATA_WIDTH-1:0] b1_s0_wdata ;

    logic                   b1_s1_cen   ;
    logic                   b1_s1_wen   ;
    logic  [DATA_WIDTH-1:0] b1_s1_rdata ;
    logic  [ADDR_WIDTH-1:0] b1_s1_addr  ;
    logic  [DATA_WIDTH-1:0] b1_s1_wdata ;

    mem_bank #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) bank0 (
        .i_clk(i_clk),

        .i_s0_cen  (b0_s0_cen  ), 
        .i_s0_wen  (b0_s0_wen  ),
        .o_s0_rdata(b0_s0_rdata),
        .i_s0_addr (b0_s0_addr ),
        .i_s0_wdata(b0_s0_wdata),
        .i_s1_cen  (b0_s1_cen  ), 
        .i_s1_wen  (b0_s1_wen  ),
        .o_s1_rdata(b0_s1_rdata),
        .i_s1_addr (b0_s1_addr ),
        .i_s1_wdata(b0_s1_wdata)
    );

    mem_bank #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) bank1 (
        .i_clk(i_clk),

        .i_s0_cen  (b1_s0_cen  ), 
        .i_s0_wen  (b1_s0_wen  ),
        .o_s0_rdata(b1_s0_rdata),
        .i_s0_addr (b1_s0_addr ),
        .i_s0_wdata(b1_s0_wdata),
        .i_s1_cen  (b1_s1_cen  ), 
        .i_s1_wen  (b1_s1_wen  ),
        .o_s1_rdata(b1_s1_rdata),
        .i_s1_addr (b1_s1_addr ),
        .i_s1_wdata(b1_s1_wdata)
    );

    `ifdef APR
    initial begin
        $display("[%0t] Applying APR SDF to mem_if_tb.bank0", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/apr/mem_bank/apr/mem_bank.apr.sdf", mem_if_tb.bank0,,,"MAXIMUM");
        $display("[%0t] Applying APR SDF to mem_if_tb.bank1", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/apr/mem_bank/apr/mem_bank.apr.sdf", mem_if_tb.bank1,,,"MAXIMUM");
    end
    `elsif SYN
    initial begin
        $display("[%0t] Applying SYN SDF to mem_if_tb.bank0", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/mem_bank/mem_bank.syn.sdf", mem_if_tb.bank0);
        $display("[%0t] Applying SYN SDF to mem_if_tb.bank1", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/mem_bank/mem_bank.syn.sdf", mem_if_tb.bank1);
    end
    `else
    initial begin
        $display("[%0t] no SDF annotation", $time);
    end
    `endif

    mem_if #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) dut (
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

        .o_b0_s0_cen  (b0_s0_cen  ),
        .o_b0_s0_wen  (b0_s0_wen  ),
        .i_b0_s0_rdata(b0_s0_rdata),
        .o_b0_s0_addr (b0_s0_addr ),
        .o_b0_s0_wdata(b0_s0_wdata),
        .o_b0_s1_cen  (b0_s1_cen  ),
        .o_b0_s1_wen  (b0_s1_wen  ),
        .i_b0_s1_rdata(b0_s1_rdata),
        .o_b0_s1_addr (b0_s1_addr ),
        .o_b0_s1_wdata(b0_s1_wdata),
        .o_b1_s0_cen  (b1_s0_cen  ),
        .o_b1_s0_wen  (b1_s0_wen  ),
        .i_b1_s0_rdata(b1_s0_rdata),
        .o_b1_s0_addr (b1_s0_addr ),
        .o_b1_s0_wdata(b1_s0_wdata),
        .o_b1_s1_cen  (b1_s1_cen  ),
        .o_b1_s1_wen  (b1_s1_wen  ),
        .i_b1_s1_rdata(b1_s1_rdata),
        .o_b1_s1_addr (b1_s1_addr ),
        .o_b1_s1_wdata(b1_s1_wdata),

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
