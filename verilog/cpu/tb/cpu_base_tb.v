`timescale 1 ns / 1 ps

module testbench;
    reg clk = 1;
    reg resetn = 0;
    wire trap;

    always #3.5 clk = ~clk;

    initial begin
        repeat (100) @(posedge clk);
        resetn <= 1;
    end

    wire mem_valid;
    wire mem_instr;
    reg mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;

    //for full width writes -> mask that lets you know which part of the 32 bits of write data is valid.
    wire [3:0] mem_wstrb;

    //this is the data that it receives from memory.
    reg  [31:0] mem_rdata;

    //what is trace_valid and trace_data
	wire        trace_valid;
	wire [35:0] trace_data;

    
    reg [239:0] program_memory_file;
    reg [239:0] program_trace_file;
    integer      trace_fd;
    reg [239:0] memory_access_file;
    integer      mem_access_fd;

    // $sdf_annotate(sdf_file, scope, config_file, log_file);
    `ifdef SYN
    initial begin
        $display("[%0t] Applying SDF to testbench.proc", $time);
        $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/picorv32/picorv32.syn.sdf",
                    testbench.proc, , "picorv32_sdf.log");
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
        .mem_valid   (mem_valid  ),
        .mem_instr   (mem_instr  ),
        .mem_ready   (mem_ready  ),
        .mem_addr    (mem_addr   ),
        .mem_wdata   (mem_wdata  ),
        .mem_wstrb   (mem_wstrb  ),
        .mem_rdata   (mem_rdata  )
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
        if (mem_valid && mem_ready) begin
            if ((mem_wstrb == 4'h0) && (mem_rdata === 32'bx)) $display("READ FROM UNITIALIZED ADDR=%x", mem_addr);

            if (|mem_wstrb)
                $fwrite(mem_access_fd, "WR: ADDR=%x DATA=%x MASK=%b\n", mem_addr, mem_wdata, mem_wstrb);
            else
                $fwrite(mem_access_fd, "RD: ADDR=%x DATA=%x%s\n", mem_addr, mem_rdata, mem_instr ? " INSN" : "");

            if (^mem_addr === 1'bx ||
                    (mem_wstrb[0] && ^mem_wdata[ 7: 0] == 1'bx) ||
                    (mem_wstrb[1] && ^mem_wdata[15: 8] == 1'bx) ||
                    (mem_wstrb[2] && ^mem_wdata[23:16] == 1'bx) ||
                    (mem_wstrb[3] && ^mem_wdata[31:24] == 1'bx)) begin
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
