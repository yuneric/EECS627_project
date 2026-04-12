`timescale 1 ns / 1 ps

module mmio_tb;
    reg clk = 1;
    reg resetn = 0;
    wire trap;

    always #(`CLK_PERIOD_HALF) clk = ~clk;

    initial begin
        repeat (100) @(posedge clk);
        resetn <= 1;
    end

    parameter ADDR_WIDTH = 32;
    parameter DATA_WIDTH = 32;
    parameter DIM_WIDTH  = 10;
    parameter NUM_REGS   = 21;
    parameter MMIO_ADDR  = 32'h1000_1000;
    parameter MMIO_SIZE  = 32'h0000_1000;

    wire cpu_valid;
    wire cpu_instr;
    wire cpu_ready;
    wire [ADDR_WIDTH-1:0] cpu_addr;
    wire [DATA_WIDTH-1:0] cpu_wdata;

    //for full width writes -> mask that lets you know which part of the 32 bits of write data is valid.
    wire [3:0] cpu_wstrb;

    //this is the data that it receives from memory.
    wire  [DATA_WIDTH-1:0] cpu_rdata;

    //what is trace_valid and trace_data
	wire        trace_valid;
	wire [35:0] trace_data;

    wire                    mem_valid;
    wire                    mem_instr;
    reg                     mem_ready;
    wire [ADDR_WIDTH-1:0]   mem_addr ;
    wire [DATA_WIDTH-1:0]   mem_wdata;
    wire [3:0]              mem_wstrb;
    reg  [DATA_WIDTH-1:0]   mem_rdata;

    wire                    mmio_valid;
    wire                    mmio_ready;
    wire [ADDR_WIDTH-1:0]   mmio_addr ;
    wire [DATA_WIDTH-1:0]   mmio_wdata;
    wire [3:0]              mmio_wstrb;
    wire [DATA_WIDTH-1:0]   mmio_rdata;
    
    reg [239:0] program_memory_file;
    reg [239:0] program_trace_file;
    integer     trace_fd;
    reg [239:0] memory_access_file;
    integer     mem_access_fd;

    `ifdef SYN
    initial begin
        $display("[%0t] Applying SDF", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/mmio/mmio.syn.sdf", mmio_dut);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/address_decoder/address_decoder.syn.sdf", addr_dec_dut);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/picorv32/picorv32.syn.sdf", proc);
        $display("[%0t] SDF annotation call finished", $time);
    end
    `else
    initial begin
        $display("[%0t] SYN not defined, no SDF annotation", $time);
    end
    `endif

	initial begin
        if ($value$plusargs("MEMORY=%s", program_memory_file)) begin
            $display("Loading memory file: %s", program_memory_file);
        end else begin
            $display("Loading default memory file: program.mem");
            program_memory_file = "program.mem";
        end
        if ($value$plusargs("TRACE=%s", program_trace_file)) begin
            $display("Using trace output file: %s", program_trace_file);
        end else begin
            $display("Using default writeback output file: trace.out");
            program_trace_file = "trace.out";
        end
        trace_fd = $fopen(program_trace_file, "w");
        if ($value$plusargs("MEMACCESS=%s", memory_access_file)) begin
            $display("Using memory access output file: %s", memory_access_file);
        end else begin
            $display("Using default memory access file: mem_access.out");
            memory_access_file = "mem_access.out";
        end
        mem_access_fd = $fopen(memory_access_file, "w");
	end
    

    picorv32 #(
    ) proc (
        .clk         (clk        ),
        .resetn      (resetn     ),
        .trap        (trap       ),
        .trace_valid (trace_valid),
		.trace_data  (trace_data),
        .mem_valid   (cpu_valid  ),
        .mem_instr   (cpu_instr  ),
        .mem_ready   (cpu_ready  ),
        .mem_addr    (cpu_addr   ),
        .mem_wdata   (cpu_wdata  ),
        .mem_wstrb   (cpu_wstrb  ),
        .mem_rdata   (cpu_rdata  )
    );

    address_decoder #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .MMIO_ADDR(MMIO_ADDR),
        .MMIO_SIZE(MMIO_SIZE)
    ) addr_dec_dut (
        .i_cpu_valid(cpu_valid),
        .i_cpu_instr(cpu_instr),
        .i_cpu_addr (cpu_addr),
        .i_cpu_wdata(cpu_wdata),
        .i_cpu_wstrb(cpu_wstrb),
        .o_cpu_ready(cpu_ready),
        .o_cpu_rdata(cpu_rdata),

        .o_mem_valid(mem_valid),
        .o_mem_instr(mem_instr),
        .o_mem_addr (mem_addr),
        .o_mem_wdata(mem_wdata),
        .o_mem_wstrb(mem_wstrb),
        .i_mem_ready(mem_ready),
        .i_mem_rdata(mem_rdata),

        .o_mmio_valid(mmio_valid),
        .o_mmio_addr (mmio_addr),
        .o_mmio_wdata(mmio_wdata),
        .o_mmio_wstrb(mmio_wstrb),
        .i_mmio_ready(mmio_ready),
        .i_mmio_rdata(mmio_rdata)
    );

    wire [2:0]                 npu_clk_sel        ;
    wire                       npu_new_cmd        ;
    wire                       npu_cmd_ack        ;
    wire                       npu_stride         ;
    wire [1:0]                 npu_padding        ;
    wire                       npu_maxpool_en     ;
    wire                       npu_relu_en        ;
    wire [4:0]                 npu_scale_amt      ;
    wire [DIM_WIDTH-1:0]       npu_comp_H         ;
    wire [DIM_WIDTH-1:0]       npu_comp_W         ;
    wire [DIM_WIDTH-1:0]       npu_comp_C         ;
    wire [DIM_WIDTH-1:0]       npu_in_tile_H      ;
    wire [DIM_WIDTH-1:0]       npu_in_tile_W      ;
    wire [DIM_WIDTH-1:0]       npu_in_tile_C      ;
    wire [ADDR_WIDTH-1:0]      npu_in_tile_addr   ;
    wire [DIM_WIDTH-1:0]       npu_in_mat_W       ;
    wire [DIM_WIDTH-1:0]       npu_out_tile_H     ;
    wire [DIM_WIDTH-1:0]       npu_out_tile_W     ;
    wire [DIM_WIDTH-1:0]       npu_out_tile_C     ;
    wire [ADDR_WIDTH-1:0]      npu_out_tile_addr  ;
    wire [DIM_WIDTH-1:0]       npu_out_mat_W      ;
    wire [DIM_WIDTH-1:0]       npu_weight_N       ;
    wire [DIM_WIDTH-1:0]       npu_weight_H       ;
    wire [DIM_WIDTH-1:0]       npu_weight_W       ;
    wire [DIM_WIDTH-1:0]       npu_weight_C       ;
    wire [ADDR_WIDTH-1:0]      npu_weight_addr    ;

    logic compute_start     ; 
    logic bank_switch_start ; 
    logic load_tile_start   ; 
    logic store_tile_start  ; 
    logic load_weights_start; 

    mmio #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .DIM_WIDTH(DIM_WIDTH),
        .NUM_REGS(NUM_REGS)
    ) mmio_dut (
        .i_clk  (clk),
        .i_resetn(resetn),

        .i_cpu_valid(mmio_valid),
        .i_cpu_addr (mmio_addr),
        .i_cpu_wdata(mmio_wdata),
        .i_cpu_wstrb(mmio_wstrb),
        .o_cpu_ready(mmio_ready),
        .o_cpu_rdata(mmio_rdata), 
        
        .i_npu_compute_done(1'b0),
        .i_npu_bank_switch_done(1'b0),
        .i_npu_load_tile_done(1'b0),
        .i_npu_store_tile_done(1'b0),
        .i_npu_load_weights_done(1'b0),

        .o_npu_compute_start        (compute_start      ),
        .o_npu_bank_switch_start    (bank_switch_start  ),
        .o_npu_load_tile_start      (load_tile_start    ),
        .o_npu_store_tile_start     (store_tile_start   ),
        .o_npu_load_weights_start   (load_weights_start ),
        
        .o_npu_clk_sel      (npu_clk_sel      ),
        .o_npu_stride       (npu_stride       ),
        .o_npu_padding      (npu_padding      ),
        .o_npu_maxpool_en   (npu_maxpool_en   ),
        .o_npu_relu_en      (npu_relu_en      ),
        .o_npu_scale_amt    (npu_scale_amt    ),
        .o_npu_comp_H       (npu_comp_H       ),
        .o_npu_comp_W       (npu_comp_W       ),
        .o_npu_comp_C       (npu_comp_C       ),
        .o_npu_in_tile_H    (npu_in_tile_H    ),
        .o_npu_in_tile_W    (npu_in_tile_W    ),
        .o_npu_in_tile_C    (npu_in_tile_C    ),
        .o_npu_in_tile_addr (npu_in_tile_addr ),
        .o_npu_in_mat_W     (npu_in_mat_W     ),
        .o_npu_out_tile_H   (npu_out_tile_H   ),
        .o_npu_out_tile_W   (npu_out_tile_W   ),
        .o_npu_out_tile_C   (npu_out_tile_C   ),
        .o_npu_out_tile_addr(npu_out_tile_addr),
        .o_npu_out_mat_W    (npu_out_mat_W    ),
        .o_npu_weight_N     (npu_weight_N     ),
        .o_npu_weight_H     (npu_weight_H     ),
        .o_npu_weight_W     (npu_weight_W     ),
        .o_npu_weight_C     (npu_weight_C     ),
        .o_npu_weight_addr  (npu_weight_addr  )
    );

    localparam MEM_SIZE = 1*1024*1024; //1MB
    reg [31:0] memory [0:MEM_SIZE/4-1];
    integer x;

    // load in the program memory
    initial
    begin
        // clear memory
        for (x=0; x<MEM_SIZE/4; x=x+1) memory[x] = 0;
        // load ram contents
        $display("Loading RAM contents starting at: 0x%h", 0);
        $readmemh(program_memory_file, memory);
        $display("Finished loading RAM contents ending at: 0x%h", MEM_SIZE - 1);
        $display("=================================");
        $display("============BEGIN================");
        $display("=================================");
        $monitor("Time: %0t\n  \
            compute_start     : %b\n \
            bank_switch_start : %b\n \
            load_tile_start   : %b\n \
            store_tile_start  : %b\n \
            load_weights_start: %b\n \
            npu_clk_sel       : %b\n \
            npu_stride        : %h\n \
            npu_padding       : %h\n \
            npu_maxpool_en    : %h\n \
            npu_relu_en       : %h\n \
            npu_scale_amt     : %h\n \
            npu_comp_H        : %h\n \
            npu_comp_W        : %h\n \
            npu_comp_C        : %h\n \
            npu_in_tile_H     : %h\n \
            npu_in_tile_W     : %h\n \
            npu_in_tile_C     : %h\n \
            npu_in_tile_addr  : %h\n \
            npu_in_mat_W      : %h\n \
            npu_out_tile_H    : %h\n \
            npu_out_tile_W    : %h\n \
            npu_out_tile_C    : %h\n \
            npu_out_tile_addr : %h\n \
            npu_out_mat_W     : %h\n \
            npu_weight_N      : %h\n \
            npu_weight_H      : %h\n \
            npu_weight_W      : %h\n \
            npu_weight_C      : %h\n \
            npu_weight_addr   : %h\n ",
            $time, 
            compute_start     ,
            bank_switch_start ,
            load_tile_start   ,
            store_tile_start  ,
            load_weights_start,
            npu_clk_sel      ,
            npu_stride       ,
            npu_padding      ,
            npu_maxpool_en   ,
            npu_relu_en      ,
            npu_scale_amt    ,
            npu_comp_H       ,
            npu_comp_W       ,
            npu_comp_C       ,
            npu_in_tile_H    ,
            npu_in_tile_W    ,
            npu_in_tile_C    ,
            npu_in_tile_addr ,
            npu_in_mat_W     ,
            npu_out_tile_H   ,
            npu_out_tile_W   ,
            npu_out_tile_C   ,
            npu_out_tile_addr,
            npu_out_mat_W    ,
            npu_weight_N     ,
            npu_weight_H     ,
            npu_weight_W     ,
            npu_weight_C     ,
            npu_weight_addr  );
    end

    // write the trace file
    initial
    begin
        repeat (10) @(posedge clk);
        while (!trap) begin
            @(posedge clk);
            if (trace_valid)
                $fwrite(trace_fd, "%x\n", trace_data);
        end
        $fclose(trace_fd);
        //$display("Finished writing testbench.trace.");
    end

    always @(posedge clk) begin
        mem_ready <= 0;
        // Handle a memory access
        if (mem_valid && !mem_ready) begin
            mem_ready <= 1;
            mem_rdata <= 'bx;
            case (1)
                mem_addr < MEM_SIZE: begin
                    if ((|mem_wstrb)) begin
                        if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                        if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                        if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
                    end else begin
                        mem_rdata <= memory[mem_addr >> 2];
                    end
                end
                mem_addr == 32'h 1000_0000: begin
                    $write("%c", mem_wdata[7:0]);
                end
                default:
                    $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
            endcase
        end

        // Print memory access information
        if (cpu_valid && cpu_ready) begin
            if ((cpu_wstrb == 4'h0) && (cpu_rdata === 32'bx)) $display("READ FROM UNITIALIZED ADDR=%x", cpu_addr);

            if (|cpu_wstrb)
                $fwrite(mem_access_fd, "WR: ADDR=%x DATA=%x MASK=%b\n", cpu_addr, cpu_wdata, cpu_wstrb);
            else
                $fwrite(mem_access_fd, "RD: ADDR=%x DATA=%x%s\n", cpu_addr, cpu_rdata, cpu_instr ? " INSN" : "");

            if (^cpu_addr === 1'bx ||
                    (cpu_wstrb[0] && ^cpu_wdata[ 7: 0] == 1'bx) ||
                    (cpu_wstrb[1] && ^cpu_wdata[15: 8] == 1'bx) ||
                    (cpu_wstrb[2] && ^cpu_wdata[23:16] == 1'bx) ||
                    (cpu_wstrb[3] && ^cpu_wdata[31:24] == 1'bx)) begin
                $display("CRITICAL UNDEF MEM TRANSACTION");
                $finish;
            end
        end
    end

    `ifdef WRITE_VCD
        initial begin
            $dumpfile("testbench.vcd");
            $dumpvars(0, testbench);
        end
    `endif

    always @(posedge clk) begin
        if (resetn && trap) begin
            repeat (10) @(posedge clk);
            $display("=================================");
            $display("============TRAP=================");
            $display("=================================");
            $finish;
        end
    end
endmodule
