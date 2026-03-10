// `timescale 1 ns / 1 ps

// module testbench;
//     reg clk = 1;
//     reg resetn = 0;
//     wire trap;

//     always #5 clk = ~clk;

//     initial begin
//         repeat (100) @(posedge clk);
//         resetn <= 1;
//     end

//     // --- ARBITER TO MEMORY WIRES ---
//     wire mem_valid;
//     reg  mem_ready;
//     wire [31:0] mem_addr;
//     wire [31:0] mem_wdata;
//     wire [3:0]  mem_wstrb;
//     reg  [31:0] mem_rdata;

//     // --- CPU TO ARBITER WIRES ---
//     wire cpu_valid;
//     wire cpu_instr;
//     wire cpu_ready;
//     wire [31:0] cpu_addr;
//     wire [31:0] cpu_wdata;
//     wire [3:0]  cpu_wstrb;
//     wire [31:0] cpu_rdata;

//     // --- NPU TO ARBITER WIRES (CRITICAL: INIT TO 0) ---
//     reg [31:0] npu_araddr_reg  = 0;
//     reg [7:0]  npu_arlen_reg   = 0;
//     reg [2:0]  npu_arsize_reg  = 3'b010; 
//     reg        npu_arvalid_reg = 0; // IF THIS ISN'T 0, THE ARBITER HANGS
//     wire       npu_arready_wire;
//     wire [31:0] npu_rdata_wire;
//     wire       npu_rvalid_wire;
//     wire       npu_rlast_wire;

//     // File I/O setup (Kept exactly as you had it)
//     wire        trace_valid;
//     wire [35:0] trace_data;
//     reg [239:0] program_memory_file;
//     reg [239:0] program_trace_file;
//     integer     trace_fd;
//     reg [239:0] memory_access_file;
//     integer     mem_access_fd;
//     integer     npu_log_fd; // Added for NPU logging

//     initial begin
//         if ($value$plusargs("MEMORY=%s", program_memory_file)) begin
//             $display("Loading memory file: %s", program_memory_file);
//         end else begin
//             $display("Loading default memory file: program.mem");
//             program_memory_file = "program.mem";
//         end
//         if ($value$plusargs("TRACE=%s", program_trace_file)) begin
//             $display("Using trace output file: %s", program_trace_file);
//         end else begin
//             $display("Using default writeback output file: trace.out");
//             program_trace_file = "trace.out";
//         end
//         trace_fd = $fopen(program_trace_file, "w");
//         if ($value$plusargs("MEMACCESS=%s", memory_access_file)) begin
//             $display("Using memory access output file: %s", memory_access_file);
//         end else begin
//             $display("Using default memory access file: mem_access.out");
//             memory_access_file = "mem_access.out";
//         end
//         mem_access_fd = $fopen(memory_access_file, "w");
//         npu_log_fd = $fopen("npu_access.out", "w"); // Log for NPU reads
//     end

//     // --- 1. THE CPU ---
//     picorv32 proc (
//         .clk         (clk        ),
//         .resetn      (resetn     ),
//         .trap        (trap       ),
//         .trace_valid (trace_valid),
//         .trace_data  (trace_data ),
//         .mem_valid   (cpu_valid  ), // Wired to CPU wires
//         .mem_instr   (cpu_instr  ),
//         .mem_ready   (cpu_ready  ),
//         .mem_addr    (cpu_addr   ),
//         .mem_wdata   (cpu_wdata  ),
//         .mem_wstrb   (cpu_wstrb  ),
//         .mem_rdata   (cpu_rdata  )
//     );

//     // --- 2. THE ARBITER ---
//     axi_arbiter arbiter_inst (
//         .clk(clk), 
//         .rst_n(resetn),
        
//         // Connect CPU
//         .i_cpu_valid(cpu_valid), 
//         .o_cpu_ready(cpu_ready), 
//         .i_cpu_addr(cpu_addr),
//         .i_cpu_wdata(cpu_wdata), 
//         .i_cpu_wstrb(cpu_wstrb), 
//         .o_cpu_rdata(cpu_rdata),
        
//         // Connect NPU (Read Only)
//         .i_npu_araddr(npu_araddr_reg), 
//         .i_npu_arlen(npu_arlen_reg), 
//         .i_npu_arsize(npu_arsize_reg),
//         .i_npu_arvalid(npu_arvalid_reg), 
//         .o_npu_arready(npu_arready_wire),
//         .o_npu_rdata(npu_rdata_wire), 
//         .o_npu_rvalid(npu_rvalid_wire), 
//         .o_npu_rlast(npu_rlast_wire),
//         .i_npu_rready(1'b1),

//         // Connect Memory Slave
//         .o_mem_valid(mem_valid), 
//         .i_mem_ready(mem_ready), 
//         .o_mem_addr(mem_addr),
//         .o_mem_wdata(mem_wdata), 
//         .o_mem_wstrb(mem_wstrb), 
//         .i_mem_rdata(mem_rdata)
//     );

//     // --- 3. THE MEMORY ---
//     localparam MEM_SIZE = 1*1024*1024; //1MB
//     reg [31:0] memory [0:MEM_SIZE/4-1];
//     integer x;

//     initial begin
//         for (x=0; x<MEM_SIZE/4; x=x+1) memory[x] = 0;
//         $display("Loading RAM contents starting at: 0x%h", 0);
//         $readmemh(program_memory_file, memory);
//         $display("Finished loading RAM contents ending at: 0x%h", MEM_SIZE - 1);
//         $display("=================================");
//         $display("============BEGIN================");
//         $display("=================================");
//     end

//     // Trace logging
//     initial begin
//         repeat (10) @(posedge clk);
//         while (!trap) begin
//             @(posedge clk);
//             if (trace_valid)
//                 $fwrite(trace_fd, "%x\n", trace_data);
//         end
//         $fclose(trace_fd);
//     end

//     // Memory State Machine
//     always @(posedge clk) begin
//         mem_ready <= 0;
//         if (mem_valid && !mem_ready) begin
//             mem_ready <= 1;
//             mem_rdata <= 'bx;
//             case (1)
//                 mem_addr < MEM_SIZE: begin
//                     if ((|mem_wstrb)) begin
//                         if (mem_wstrb[0]) memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
//                         if (mem_wstrb[1]) memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
//                         if (mem_wstrb[2]) memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
//                         if (mem_wstrb[3]) memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
//                     end else begin
//                         mem_rdata <= memory[mem_addr >> 2];
//                     end
//                 end
//                 mem_addr == 32'h 1000_0000: begin
//                     $write("%c", mem_wdata[7:0]);
//                 end
//                 default:
//                     $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
//             endcase
//         end

//         // Access Logging
//         if (mem_valid && mem_ready) begin
//             if ((mem_wstrb == 4'h0) && (mem_rdata === 32'bx)) $display("READ FROM UNITIALIZED ADDR=%x", mem_addr);

//             if (|mem_wstrb)
//                 $fwrite(mem_access_fd, "WR: ADDR=%x DATA=%x MASK=%b\n", mem_addr, mem_wdata, mem_wstrb);
//             else
//                 $fwrite(mem_access_fd, "RD: ADDR=%x DATA=%x\n", mem_addr, mem_rdata);

//             if (^mem_addr === 1'bx ||
//                     (mem_wstrb[0] && ^mem_wdata[ 7: 0] == 1'bx) ||
//                     (mem_wstrb[1] && ^mem_wdata[15: 8] == 1'bx) ||
//                     (mem_wstrb[2] && ^mem_wdata[23:16] == 1'bx) ||
//                     (mem_wstrb[3] && ^mem_wdata[31:24] == 1'bx)) begin
//                 $display("CRITICAL UNDEF MEM TRANSACTION");
//                 $finish;
//             end
//         end
//     end

//     // NPU Test Task
//     task npu_load_weights(input [31:0] addr, input [7:0] len);
//         begin
//             @(posedge clk);
//             npu_araddr_reg  <= addr;
//             npu_arlen_reg   <= len;
//             npu_arvalid_reg <= 1'b1;
//             $fwrite(npu_log_fd, "[%0t] START NPU READ BURST: ADDR=%x LEN=%d\n", $time, addr, len+1);
            
//             wait(npu_arready_wire);
//             @(posedge clk);
//             npu_arvalid_reg <= 1'b0; // DROP VALID WHEN ACCEPTED
            
//             wait(npu_rlast_wire && npu_rvalid_wire);
//             @(posedge clk); 
//             #1;
//             $fwrite(npu_log_fd, "[%0t] END NPU READ BURST\n\n", $time);
//             $fflush(npu_log_fd);
//         end
//     endtask

//     // NPU Stimulus
//     initial begin
//         wait(resetn);
        
//         // Let the CPU boot uninterrupted
//         repeat(1000) @(posedge clk);
        
//         // Interrupt the CPU with an NPU Read
//         npu_load_weights(32'h0000_07D0, 8'd7); 

//         // Let CPU run some more
//         repeat(500) @(posedge clk);
        
//         $display("Simulation timeout reached. CPU and NPU successfully shared bus.");
//         $finish;
//     end

// `ifdef WRITE_VCD
//     initial begin
//         $dumpfile("testbench.vcd");
//         $dumpvars(0, testbench);
//     end
// `endif

//     always @(posedge clk) begin
//         if (resetn && trap) begin
//             repeat (10) @(posedge clk);
//             $display("=================================");
//             $display("============TRAP=================");
//             $display("=================================");
//             $finish;
//         end
//     end
// endmodule


`timescale 1 ns / 1 ps

module testbench;
    reg clk = 1;
    reg resetn = 0;
    wire trap;

    always #5 clk = ~clk;

    initial begin
        repeat (100) @(posedge clk);
        resetn <= 1;
    end

    // --- ARBITER TO MEMORY WIRES ---
    wire mem_valid;
    reg  mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    // --- CPU TO ARBITER WIRES ---
    wire cpu_valid;
    wire cpu_instr;
    wire cpu_ready;
    wire [31:0] cpu_addr;
    wire [31:0] cpu_wdata;
    wire [3:0]  cpu_wstrb;
    wire [31:0] cpu_rdata;

    // --- NPU READ CHANNELS (CRITICAL: INIT TO 0) ---
    reg [31:0] npu_araddr_reg  = 0;
    reg [7:0]  npu_arlen_reg   = 0;
    reg [2:0]  npu_arsize_reg  = 3'b010; 
    reg        npu_arvalid_reg = 0; 
    wire       npu_arready_wire;
    wire [31:0] npu_rdata_wire;
    wire       npu_rvalid_wire;
    wire       npu_rlast_wire;

    // --- NPU WRITE CHANNELS (CRITICAL: INIT TO 0) ---
    reg [31:0] npu_awaddr_reg  = 0;
    reg [7:0]  npu_awlen_reg   = 0;
    reg [2:0]  npu_awsize_reg  = 3'b010;
    reg        npu_awvalid_reg = 0;
    wire       npu_awready_wire;
    
    reg [31:0] npu_wdata_reg   = 0;
    reg [3:0]  npu_wstrb_reg   = 4'hF; // Full word write by default
    reg        npu_wvalid_reg  = 0;
    reg        npu_wlast_reg   = 0;
    wire       npu_wready_wire;

    wire [1:0] npu_bresp_wire;
    wire       npu_bvalid_wire;

    // File I/O setup
    wire        trace_valid;
    wire [35:0] trace_data;
    reg [239:0] program_memory_file;
    reg [239:0] program_trace_file;
    integer     trace_fd;
    reg [239:0] memory_access_file;
    integer     mem_access_fd;
    integer     npu_log_fd; 

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
        npu_log_fd = $fopen("npu_access.out", "w"); 
    end

    // --- 1. THE CPU ---
    picorv32 proc (
        .clk         (clk        ),
        .resetn      (resetn     ),
        .trap        (trap       ),
        .trace_valid (trace_valid),
        .trace_data  (trace_data ),
        .mem_valid   (cpu_valid  ), 
        .mem_instr   (cpu_instr  ),
        .mem_ready   (cpu_ready  ),
        .mem_addr    (cpu_addr   ),
        .mem_wdata   (cpu_wdata  ),
        .mem_wstrb   (cpu_wstrb  ),
        .mem_rdata   (cpu_rdata  )
    );

    // --- 2. THE ARBITER ---
    axi_arbiter arbiter_inst (
        .clk(clk), 
        .rst_n(resetn),
        
        // CPU Connect
        .i_cpu_valid  (cpu_valid), 
        .o_cpu_ready  (cpu_ready), 
        .i_cpu_addr   (cpu_addr),
        .i_cpu_wdata  (cpu_wdata), 
        .i_cpu_wstrb  (cpu_wstrb), 
        .o_cpu_rdata  (cpu_rdata),
        
        // NPU Read Connect
        .i_npu_araddr (npu_araddr_reg), 
        .i_npu_arlen  (npu_arlen_reg), 
        .i_npu_arsize (npu_arsize_reg),
        .i_npu_arvalid(npu_arvalid_reg), 
        .o_npu_arready(npu_arready_wire),
        .o_npu_rdata  (npu_rdata_wire), 
        .o_npu_rvalid (npu_rvalid_wire), 
        .o_npu_rlast  (npu_rlast_wire),
        .i_npu_rready (1'b1),

        // NPU Write Connect
        .i_npu_awaddr (npu_awaddr_reg), 
        .i_npu_awlen  (npu_awlen_reg), 
        .i_npu_awsize (npu_awsize_reg),
        .i_npu_awvalid(npu_awvalid_reg), 
        .o_npu_awready(npu_awready_wire),
        .i_npu_wdata  (npu_wdata_reg), 
        .i_npu_wstrb  (npu_wstrb_reg), 
        .i_npu_wlast  (npu_wlast_reg),
        .i_npu_wvalid (npu_wvalid_reg), 
        .o_npu_wready (npu_wready_wire),
        .o_npu_bresp  (npu_bresp_wire), 
        .o_npu_bvalid (npu_bvalid_wire), 
        .i_npu_bready (1'b1), // Always ready for write response

        // Memory Slave Connect
        .o_mem_valid  (mem_valid), 
        .i_mem_ready  (mem_ready), 
        .o_mem_addr   (mem_addr),
        .o_mem_wdata  (mem_wdata), 
        .o_mem_wstrb  (mem_wstrb), 
        .i_mem_rdata  (mem_rdata)
    );

    // --- 3. THE MEMORY ---
    localparam MEM_SIZE = 1*1024*1024; //1MB
    reg [31:0] memory [0:MEM_SIZE/4-1];
    integer x;

    initial begin
        for (x=0; x<MEM_SIZE/4; x=x+1) memory[x] = 0;
        $display("Loading RAM contents starting at: 0x%h", 0);
        $readmemh(program_memory_file, memory);
        $display("Finished loading RAM contents ending at: 0x%h", MEM_SIZE - 1);
        $display("=================================");
        $display("============BEGIN================");
        $display("=================================");
    end

    // Trace logging
    initial begin
        repeat (10) @(posedge clk);
        while (!trap) begin
            @(posedge clk);
            if (trace_valid)
                $fwrite(trace_fd, "%x\n", trace_data);
        end
        $fclose(trace_fd);
    end

    // Memory State Machine
    always @(posedge clk) begin
        mem_ready <= 0;
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

        // Access Logging
        if (mem_valid && mem_ready) begin
            if ((mem_wstrb == 4'h0) && (mem_rdata === 32'bx)) $display("READ FROM UNITIALIZED ADDR=%x", mem_addr);

            if (|mem_wstrb)
                $fwrite(mem_access_fd, "WR: ADDR=%x DATA=%x MASK=%b\n", mem_addr, mem_wdata, mem_wstrb);
            else
                $fwrite(mem_access_fd, "RD: ADDR=%x DATA=%x\n", mem_addr, mem_rdata);

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

    // NPU Tasks
    task npu_load_weights(input [31:0] addr, input [7:0] len);
        begin
            @(posedge clk);
            npu_araddr_reg  <= addr;
            npu_arlen_reg   <= len;
            npu_arvalid_reg <= 1'b1;
            $fwrite(npu_log_fd, "[%0t] START NPU READ BURST: ADDR=%x LEN=%d\n", $time, addr, len+1);
            
            wait(npu_arready_wire);
            @(posedge clk);
            npu_arvalid_reg <= 1'b0; 
            
            // Wait for data and log it exactly like your trace output
            begin : read_wait_loop
                forever begin
                    @(posedge clk);
                    if (npu_rvalid_wire) begin
                        $fwrite(npu_log_fd, "NPU_DATA: DATA=%x LAST=%b\n", npu_rdata_wire, npu_rlast_wire);
                        if (npu_rlast_wire) disable read_wait_loop; // Verilog-2001 safe break
                    end
                end
            end
            
            #1;
            $fwrite(npu_log_fd, "[%0t] END NPU READ BURST\n\n", $time);
            $fflush(npu_log_fd);
        end
    endtask

    task npu_store_weights(input [31:0] addr, input [7:0] len, input [31:0] start_data);
        integer i;
        begin
            // --- 1. Address Phase ---
            @(posedge clk);
            npu_awaddr_reg  <= addr;
            npu_awlen_reg   <= len;
            npu_awvalid_reg <= 1'b1;
            
            // Block until NPU is ready, then move to next clock to drop valid
            wait(npu_awready_wire);
            @(posedge clk);
            npu_awvalid_reg <= 1'b0;

            // --- 2. Data Burst Phase ---
            $fwrite(npu_log_fd, "[%0t] START NPU WRITE BURST: ADDR=%x LEN=%d\n", $time, addr, len+1);
            

            i = 0;
            while (i <= len) begin
                // 1. DRIVE: Set the values for this beat
                npu_wdata_reg  <= start_data + i; 
                npu_wvalid_reg <= 1'b1;
                npu_wlast_reg  <= (i == len);

                // 2. THE HANDSHAKE: Wait for the rising edge where both are 1
                // We stay in this 'do-nothing' state until the Arbiter is ready
                @(posedge clk);
                
                if (npu_wready_wire) begin
                    // Handshake occurred!
                    $fwrite(npu_log_fd, "[%0t] Handshake Success - Beat %0d\n", $time, i);
                    $fflush(npu_log_fd);
                    
                    // Only increment the index if the data was actually accepted
                    i = i + 1;
                end else begin
                    // No handshake? The loop repeats with the same 'i', 
                    // effectively "holding" the data stable for another cycle.
                    $fwrite(npu_log_fd, "[%0t] Waiting... Arbiter Busy\n", $time);
                end
            end

            // // --- 3. Cleanup & Response Phase ---
            npu_wvalid_reg <= 1'b0;
            npu_wlast_reg  <= 1'b0;
            // // npu_bready_reg <= 1'b1; 

            $fwrite(npu_log_fd, "waiting\n", $time);
            $fflush(npu_log_fd);

            // @(posedge clk);
            // @(posedge clk);

            // $finish;

            wait(npu_bvalid_wire);
            @(posedge clk);
            // npu_bready_reg <= 1'b0;
            
            $display("[%0t] NPU Write Complete.", $time);
        end
    endtask

    

    // NPU Stimulus Mapped from Trace
    integer test_len;
    initial begin
        wait(resetn);
        
        // Let the CPU boot uninterrupted
        repeat(1) @(posedge clk);
        
        // //ADDR=000007d0 LEN=8
        $display("[%0t] Starting NPU Read Test 1...", $time);
        npu_load_weights(32'h0000_07D0, 8'd7); 
        repeat(1) @(posedge clk);

        // // ADDR=00000500 LEN=16
        $display("[%0t] Starting NPU Read Test 2...", $time);
        npu_load_weights(32'h0000_0500, 8'd15); 
        repeat(1) @(posedge clk);

        // // // ADDR=00000000 LEN=256
        $display("[%0t] Starting NPU Read Test 3...", $time);
        npu_load_weights(32'h0000_0000, 8'd255); 
        repeat(1) @(posedge clk);

        //ADDR=00000190 LEN=4
        $display("[%0t] Starting NPU Read Test 4...", $time);
        npu_load_weights(32'h0000_0190, 8'd3); 
        repeat(1) @(posedge clk);

        // // ADDR=000001a0 LEN=4
        $display("[%0t] Starting NPU Read Test 5...", $time);
        npu_load_weights(32'h0000_01A0, 8'd3); 
        repeat(1) @(posedge clk);

        // // ADDR=000001b0 LEN=4
        $display("[%0t] Starting NPU Read Test 6...", $time);
        npu_load_weights(32'h0000_01B0, 8'd3); 
        repeat(1) @(posedge clk);

        // // NPU Write Burst (Store)
        $display("[%0t] Starting NPU Write Test...", $time);
        npu_store_weights(32'h0000_3000, 8'd3, 32'hAAAA0000); // Writes 4 beats

        repeat(1) @(posedge clk);

        // Verification Read Burst (Load)
        $display("[%0t] Verifying NPU Write with Read Test...", $time);
        npu_load_weights(32'h0000_3000, 8'd3); // Reads 4 beats

        // Let CPU run some more
        repeat(500) @(posedge clk);


        //more npu write and read tests
        for (test_len = 8; test_len <= 255; test_len = test_len + 32) begin
            npu_store_weights(32'h4000 + (test_len*4), test_len-1, 32'hBBBB_0000 + test_len);
            repeat(1) @(posedge clk); 
        end

        // --- [3] SYSTEMATIC READ STRESS TEST (8 to 255) ---
        for (test_len = 8; test_len <= 255; test_len = test_len + 32) begin
            npu_load_weights(32'h4000 + (test_len*4), test_len-1);
            repeat(1) @(posedge clk);
        end
        
        $display("Simulation timeout reached. All trace loads, write, and verify read completed.");
    end

    initial begin
        // $dumpfile("testbench.vcd");
        // $dumpvars(0, testbench);
        $dumpfile("testbench.fsdb");
        $dumpvars(0, testbench); // Dump everything in the TB
        // $fsdbDumpvars("+all");           // Capture structs and arrays
    end

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