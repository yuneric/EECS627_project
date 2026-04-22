`timescale 1 ns / 1 ps

`define HI 0
`define WI 1
`define HF 2
`define WF 3
`define HO 4
`define WO 5
`define CI 6
`define NUM_KERNELS 7
`define WORDS_NEEDED_FOR_CI 8
`define WORDS_NEEDED_FOR_CO 9
`define STRIDE 10
`define PADDING 11
`define MAXPOOL_EN 12
`define RELU_EN 13
`define SCALE_AMT 14
`define ACT_START_ADDR 15
`define ACT_END_ADDR 16
`define WT_START_ADDR 17
`define WT_END_ADDR 18
`define OUTPUT_START_ADDR 19
`define OUTPUT_END_ADDR 20


module top_tb;

    parameter NUM_ARRAYS            = 8;
    parameter CPU_ADDR_WIDTH        = 32;
    parameter CPU_DATA_WIDTH        = 32;
    parameter NPU_ACT_ADDR_WIDTH    = 12;
    parameter NPU_WT_ADDR_WIDTH     = 11;
    parameter NPU_DATA_WIDTH        = 64;
    parameter DIM_WIDTH             = 10;
    parameter PRINT_ADDR            = 32'h1000_0000;
    parameter MMIO_ADDR             = 32'h1000_1000;
    parameter MMIO_SIZE             = 32'h0000_0100;
    parameter CFG_ADDR              = 32'h1000_2000;
    parameter CFG_SIZE              = 32'h0000_0100;
    parameter CNN_ADDR              = 32'h2000_0000;

    parameter PSUM_WIDTH        = 32;
    parameter SHIFT_WIDTH       = 5;
    parameter INPUT_FIFO_DEPTH  = 32; 
    parameter INPUT_FIFO_AF_LVL = 5; 
    parameter OUTPUT_FIFO_DEPTH = 8; 

    //Clock & Reset
    //logic clk_sys, clk_sa;
    logic clk_sys;
    initial clk_sys = 0;
    always #`CLK_PERIOD_SYS_HALF clk_sys = ~clk_sys;

    // initial clk_sa = 0;
    // always #`CLK_PERIOD_SA_HALF clk_sa = ~clk_sa;

    logic rstn_sync;
    logic rstn_async;

    //memory size
    localparam int MEM_SIZE_BYTES = 1 * 1024 * 1024; // 1MB
    localparam int MEM_WORDS      = MEM_SIZE_BYTES / 4;
    
    //define memory seperately for ease of testing
    logic [31:0] prgm_memory [0:MEM_WORDS-1];   // Contains addresses between 0x0000_0000-0x000f_ffff
    logic [31:0] cnn_memory [0:MEM_WORDS-1];    // Contains addresses between 0x2000_0000-0x200f_ffff
    logic [31:0] cnn_memory_clean [0:MEM_WORDS-1];    // Contains addresses between 0x2000_0000-0x200f_ffff
    logic [31:0] cfg_memory       [0:31]; // Contains the test configuration info for the cpu

    //trace signals
    wire trap, trace_valid;
    wire [33:0] trace_data;

    // Off chip memory interface
    logic                      mem_valid;
    logic                      mem_ready;
    logic [CPU_ADDR_WIDTH-1:0] mem_addr;
    logic [CPU_DATA_WIDTH-1:0] mem_wdata;
    logic [3:0]                mem_wstrb;
    logic [CPU_DATA_WIDTH-1:0] mem_rdata;

    // =========================================================================
    // Top Module Instantiation (Replacing all internal wiring)
    // =========================================================================
    top #(
        .NUM_ARRAYS         (NUM_ARRAYS),
        .CPU_ADDR_WIDTH     (CPU_ADDR_WIDTH),
        .CPU_DATA_WIDTH     (CPU_DATA_WIDTH),
        .NPU_ACT_ADDR_WIDTH (NPU_ACT_ADDR_WIDTH),
        .NPU_WT_ADDR_WIDTH  (NPU_WT_ADDR_WIDTH),
        .NPU_DATA_WIDTH     (NPU_DATA_WIDTH),
        .DIM_WIDTH          (DIM_WIDTH),
        .MMIO_ADDR          (MMIO_ADDR),
        .MMIO_SIZE          (MMIO_SIZE),
        .PSUM_WIDTH         (PSUM_WIDTH),
        .SHIFT_WIDTH        (SHIFT_WIDTH),
        .INPUT_FIFO_DEPTH   (INPUT_FIFO_DEPTH),
        .INPUT_FIFO_AF_LVL  (INPUT_FIFO_AF_LVL),
        .OUTPUT_FIFO_DEPTH  (OUTPUT_FIFO_DEPTH)
    ) dut (
        .i_clk_sys     (clk_sys),
        // .i_clk_sa      (clk_sa),
        .i_rstn_sync   (rstn_sync),
        .i_rstn_async  (rstn_async),

        // Off-chip memory interface
        .o_mem_valid   (mem_valid),
        .i_mem_ready   (mem_ready),
        .o_mem_addr    (mem_addr),
        .o_mem_wdata   (mem_wdata),
        .o_mem_wstrb   (mem_wstrb),
        .i_mem_rdata   (mem_rdata),

        // Trace signals
        .o_trap        (trap),
        .o_trace_valid (trace_valid),
        .o_trace_data  (trace_data)
    );

    genvar top_i;
    generate
        for (top_i = 0; top_i < NUM_ARRAYS/2; top_i = top_i + 2) begin
            // --- ANALOG FEEDBACK LOOP MIMIC (Per Top Array Generate Block) ---
            localparam integer MV_SLEW_RATE = 5;

            // Inner Slice Tracking Variables
            integer active_pmos_inner;
            integer current_fake_vcore_mv_inner = 0;
            integer target_vcore_mv_inner;
            logic [11:0] mock_A_inner;

            // Outer Slice Tracking Variables
            integer active_pmos_outer;
            integer current_fake_vcore_mv_outer = 0;
            integer target_vcore_mv_outer;
            logic [11:0] mock_A_outer;

            always @(posedge clk_sys) begin
                if (!rstn_async) begin
                    current_fake_vcore_mv_inner <= 0;
                    mock_A_inner <= 12'b0;

                    current_fake_vcore_mv_outer <= 0;
                    mock_A_outer <= 12'b0;
                end else begin
                    // 1. Read the PMOS drive independently
                    active_pmos_inner = 255 - dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_inner.pmos_val;
                    active_pmos_outer = 255 - dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_outer.pmos_val;

                    // 2. Calculate independent target steady-state voltages
                    target_vcore_mv_inner = active_pmos_inner * 5;
                    target_vcore_mv_outer = active_pmos_outer * 5;

                    // 3. Fake RC Charging/Discharging for INNER
                    if (current_fake_vcore_mv_inner < target_vcore_mv_inner) begin
                        if ((target_vcore_mv_inner - current_fake_vcore_mv_inner) < MV_SLEW_RATE)
                            current_fake_vcore_mv_inner <= target_vcore_mv_inner;
                        else
                            current_fake_vcore_mv_inner <= current_fake_vcore_mv_inner + MV_SLEW_RATE;
                    end
                    else if (current_fake_vcore_mv_inner > target_vcore_mv_inner) begin
                        if ((current_fake_vcore_mv_inner - target_vcore_mv_inner) < MV_SLEW_RATE)
                            current_fake_vcore_mv_inner <= target_vcore_mv_inner;
                        else
                            current_fake_vcore_mv_inner <= current_fake_vcore_mv_inner - MV_SLEW_RATE;
                    end

                    // 4. Fake RC Charging/Discharging for OUTER
                    if (current_fake_vcore_mv_outer < target_vcore_mv_outer) begin
                        if ((target_vcore_mv_outer - current_fake_vcore_mv_outer) < MV_SLEW_RATE)
                            current_fake_vcore_mv_outer <= target_vcore_mv_outer;
                        else
                            current_fake_vcore_mv_outer <= current_fake_vcore_mv_outer + MV_SLEW_RATE;
                    end
                    else if (current_fake_vcore_mv_outer > target_vcore_mv_outer) begin
                        if ((current_fake_vcore_mv_outer - target_vcore_mv_outer) < MV_SLEW_RATE)
                            current_fake_vcore_mv_outer <= target_vcore_mv_outer;
                        else
                            current_fake_vcore_mv_outer <= current_fake_vcore_mv_outer - MV_SLEW_RATE;
                    end

                    // 5. ADC Threshold Logic for Both
                    for (int i = 0; i < 12; i = i + 1) begin
                        mock_A_inner[i] <= (current_fake_vcore_mv_inner >= (600 + i*50));
                        mock_A_outer[i] <= (current_fake_vcore_mv_outer >= (600 + i*50));
                    end
                end
            end

            // 6. Inject the calculated outputs straight into LVS black-box
            initial begin
                force dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_inner.u_sa_sys_power.u_adc.A = mock_A_inner;
                force dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_inner.u_sa_sys_power.u_adc.B = ~mock_A_inner;

                force dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_outer.u_sa_sys_power.u_adc.A = mock_A_outer;
                force dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_outer.u_sa_sys_power.u_adc.B = ~mock_A_outer;
            end

            // `ifdef APR
            //     initial begin
                   
            //     end
            // `elsif SYN
            //     initial begin 
            //         $display("[%0t] Applying SYN SDF to BOTTOM_SYSTOLIC_ARRAYS[%0d]", $time, bot_i);
        
            //         // Annotate the specific slice instance in the current generate iteration
            //         $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice_thru/sa_slice_thru.syn.sdf",
            //                     dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_inner, , "sa_slice_bot_inner.log");
                    
            //         $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf",
            //                     dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_outer, , "sa_slice_bot_outer.log");

            //         // Annotate the power/system logic inside those slices
            //         $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
            //                     dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_inner.u_sa_sys_power, , "pwr_bot_inner.log");
                                
            //         $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
            //                     dut.TOP_SYSTOLIC_ARRAYS[top_i].slice_inner.u_sa_sys_power.u_sa_sys, , "sys_bot_inner.log");
 
            //     end
            // `endif

        end
    endgenerate

    genvar bot_i;
    generate
        for (bot_i = 0; bot_i < NUM_ARRAYS/2; bot_i = bot_i + 2) begin
            // --- ANALOG FEEDBACK LOOP MIMIC (Per Top Array Generate Block) ---
            localparam integer MV_SLEW_RATE = 5;

            // Inner Slice Tracking Variables
            integer active_pmos_inner;
            integer current_fake_vcore_mv_inner = 0;
            integer target_vcore_mv_inner;
            logic [11:0] mock_A_inner;

            // Outer Slice Tracking Variables
            integer active_pmos_outer;
            integer current_fake_vcore_mv_outer = 0;
            integer target_vcore_mv_outer;
            logic [11:0] mock_A_outer;

            always @(posedge clk_sys) begin
                if (!rstn_async) begin
                    current_fake_vcore_mv_inner <= 0;
                    mock_A_inner <= 12'b0;

                    current_fake_vcore_mv_outer <= 0;
                    mock_A_outer <= 12'b0;
                end else begin
                    // 1. Read the PMOS drive independently
                    active_pmos_inner = 255 - dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_inner.pmos_val;
                    active_pmos_outer = 255 - dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_outer.pmos_val;

                    // 2. Calculate independent target steady-state voltages
                    target_vcore_mv_inner = active_pmos_inner * 5;
                    target_vcore_mv_outer = active_pmos_outer * 5;

                    // 3. Fake RC Charging/Discharging for INNER
                    if (current_fake_vcore_mv_inner < target_vcore_mv_inner) begin
                        if ((target_vcore_mv_inner - current_fake_vcore_mv_inner) < MV_SLEW_RATE)
                            current_fake_vcore_mv_inner <= target_vcore_mv_inner;
                        else
                            current_fake_vcore_mv_inner <= current_fake_vcore_mv_inner + MV_SLEW_RATE;
                    end
                    else if (current_fake_vcore_mv_inner > target_vcore_mv_inner) begin
                        if ((current_fake_vcore_mv_inner - target_vcore_mv_inner) < MV_SLEW_RATE)
                            current_fake_vcore_mv_inner <= target_vcore_mv_inner;
                        else
                            current_fake_vcore_mv_inner <= current_fake_vcore_mv_inner - MV_SLEW_RATE;
                    end

                    // 4. Fake RC Charging/Discharging for OUTER
                    if (current_fake_vcore_mv_outer < target_vcore_mv_outer) begin
                        if ((target_vcore_mv_outer - current_fake_vcore_mv_outer) < MV_SLEW_RATE)
                            current_fake_vcore_mv_outer <= target_vcore_mv_outer;
                        else
                            current_fake_vcore_mv_outer <= current_fake_vcore_mv_outer + MV_SLEW_RATE;
                    end
                    else if (current_fake_vcore_mv_outer > target_vcore_mv_outer) begin
                        if ((current_fake_vcore_mv_outer - target_vcore_mv_outer) < MV_SLEW_RATE)
                            current_fake_vcore_mv_outer <= target_vcore_mv_outer;
                        else
                            current_fake_vcore_mv_outer <= current_fake_vcore_mv_outer - MV_SLEW_RATE;
                    end

                    // 5. ADC Threshold Logic for Both
                    for (int i = 0; i < 12; i = i + 1) begin
                        mock_A_inner[i] <= (current_fake_vcore_mv_inner >= (600 + i*50));
                        mock_A_outer[i] <= (current_fake_vcore_mv_outer >= (600 + i*50));
                    end
                end
            end

            // 6. Inject the calculated outputs straight into LVS black-box
            initial begin
                force dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_inner.u_sa_sys_power.u_adc.A = mock_A_inner;
                force dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_inner.u_sa_sys_power.u_adc.B = ~mock_A_inner;

                force dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_outer.u_sa_sys_power.u_adc.A = mock_A_outer;
                force dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_outer.u_sa_sys_power.u_adc.B = ~mock_A_outer;
            end

            // `ifdef APR
            //     initial begin
                    
            //     end
            // `elsif SYN
            //     initial begin
            //         // $display("[%0t] Applying SYN SDF to BOTTOM_SYSTOLIC_ARRAYS[%0d]", $time, bot_i);
        
            //         // // Annotate the specific slice instance in the current generate iteration
            //         // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice_thru/sa_slice_thru.syn.sdf",
            //         //             dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_inner, , "sa_slice_bot_inner.log");
                    
            //         // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf",
            //         //             dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_outer, , "sa_slice_bot_outer.log");

            //         // // Annotate the power/system logic inside those slices
            //         // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
            //         //             dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_inner.u_sa_sys_power, , "pwr_bot_inner.log");
                                
            //         // $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
            //         //             dut.BOTTOM_SYSTOLIC_ARRAYS[bot_i].slice_inner.u_sa_sys_power.u_sa_sys, , "sys_bot_inner.log");
            //     end
            // `endif

        end
    endgenerate


    initial begin
        `ifdef APR
            // Removed nested initial begin
            $display("[%0t] Starting APR Simulation", $time);
        `elsif SYN
            // Removed nested initial begin
            $display("[%0t] Applying SYN SDF Annotations", $time);
            
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/dunkin_donuts/dunkin_donuts.syn.sdf", 
                    dut.core);

            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/mmu/mmu.syn.sdf",
                        dut.core.u_munchkin_mmu_inst);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/computation_overseer/computation_overseer.syn.sdf",
                        dut.core.u_munchkin_comp_over_inst);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/controller/controller.syn.sdf",
                        dut.core.u_munchkin_controller_inst);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/picorv32/picorv32.syn.sdf",
                        dut.core.u_munchkin_proc);

             

            // TOP ARRAY 0
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice_thru/sa_slice_thru.syn.sdf", 
                    dut.TOP_SYSTOLIC_ARRAYS_0__slice_inner, , "top_0_inner.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", 
                    dut.TOP_SYSTOLIC_ARRAYS_0__slice_outer, , "top_0_outer.log");
            
            //TOP ARRAY 0 - sys_power and sa_sys - sa_slice_thru
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.TOP_SYSTOLIC_ARRAYS_0__slice_inner.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                         dut.TOP_SYSTOLIC_ARRAYS_0__slice_inner.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");

            //TOP ARRAY 0 - sys_power and sa_sys - sa_slice       
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.TOP_SYSTOLIC_ARRAYS_0__slice_outer.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                        dut.TOP_SYSTOLIC_ARRAYS_0__slice_outer.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");


            // TOP ARRAY 2
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice_thru/sa_slice_thru.syn.sdf", 
                    dut.TOP_SYSTOLIC_ARRAYS_2__slice_inner, , "top_2_inner.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", 
                    dut.TOP_SYSTOLIC_ARRAYS_2__slice_outer, , "top_2_outer.log");

            //TOP ARRAY 2 - sys_power and sa_sys - sa_slice_thru
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.TOP_SYSTOLIC_ARRAYS_2__slice_inner.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                         dut.TOP_SYSTOLIC_ARRAYS_2__slice_inner.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");

            //TOP ARRAY 2 - sys_power and sa_sys - sa_slice     
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.TOP_SYSTOLIC_ARRAYS_2__slice_outer.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                        dut.TOP_SYSTOLIC_ARRAYS_2__slice_outer.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");
            

            // BOTTOM ARRAY 0
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice_thru/sa_slice_thru.syn.sdf", 
                    dut.BOTTOM_SYSTOLIC_ARRAYS_0__slice_inner, , "bot_0_inner.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", 
                    dut.BOTTOM_SYSTOLIC_ARRAYS_0__slice_outer, , "bot_0_outer.log");

            //BOTTOM ARRAY 0 - sys_power and sa_sys - sa_slice_thru
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.BOTTOM_SYSTOLIC_ARRAYS_0__slice_inner.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                         dut.BOTTOM_SYSTOLIC_ARRAYS_0__slice_inner.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");

            //BOTTOM ARRAY 0 - sys_power and sa_sys - sa_slice       
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.BOTTOM_SYSTOLIC_ARRAYS_0__slice_outer.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                        dut.BOTTOM_SYSTOLIC_ARRAYS_0__slice_outer.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");

            
            // BOTTOM ARRAY 2
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice_thru/sa_slice_thru.syn.sdf", 
                    dut.BOTTOM_SYSTOLIC_ARRAYS_2__slice_inner, , "bot_0_inner.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_slice/sa_slice.syn.sdf", 
                    dut.BOTTOM_SYSTOLIC_ARRAYS_2__slice_outer, , "bot_0_outer.log");

            //BOTTOM ARRAY 2 - sys_power and sa_sys - sa_slice_thru
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.BOTTOM_SYSTOLIC_ARRAYS_2__slice_inner.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                         dut.BOTTOM_SYSTOLIC_ARRAYS_2__slice_inner.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");

            //BOTTOM ARRAY 2 - sys_power and sa_sys - sa_slice       
            $display("[%0t] Applying SYN SDF", $time);
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_sys_power/sa_sys_power.syn.sdf",
                        dut.BOTTOM_SYSTOLIC_ARRAYS_2__slice_outer.u_sa_sys_power, "", "sa_sys_pwr_syn_sdf.log");
            $sdf_annotate("/afs/umich.edu/class/eecs627/w26/groups/group7/project/syn/sa_system/systolic_array_system.syn.sdf",
                        dut.BOTTOM_SYSTOLIC_ARRAYS_2__slice_outer.u_sa_sys_power.u_sa_sys, "", "sa_sys_syn_sdf.log");
        `endif
    end

    // =========================================================================
    // Writing to off-chip main memory (Kept from your original logic)
    // =========================================================================
    logic [CPU_ADDR_WIDTH-1:0] adj_addr;
    localparam DELAY_CNT_WIDTH = (`MEM_DELAY_CYCLES > 0) ? $clog2(`MEM_DELAY_CYCLES + 1) : 1;
    logic [DELAY_CNT_WIDTH-1:0] delay_counter = 0;

    always @(posedge clk_sys) begin
        mem_ready <= 0; // Default state (drops ready after 1 cycle)
        
        //rst counter at reset
        if (!rstn_sync) begin
            delay_counter <= 0;
        //if mem_valid
        end else if (mem_valid) begin
            
            // Only proceed if we didn't just assert mem_ready on the last cycle
            if (!mem_ready) begin 
                //delay_counter is >= MEM_DELAY_CYCLES.
                if (delay_counter >= `MEM_DELAY_CYCLES) begin
                    mem_ready <= 1;
                    delay_counter <= 0; // Reset counter for the next transaction
                    mem_rdata <= 'bx;
                    
                    case (1)
                        (mem_addr >> 2) < MEM_WORDS: begin
                            if (|mem_wstrb) begin
                                if (mem_wstrb[0]) prgm_memory[mem_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                                if (mem_wstrb[1]) prgm_memory[mem_addr >> 2][15: 8] <= mem_wdata[15: 8];
                                if (mem_wstrb[2]) prgm_memory[mem_addr >> 2][23:16] <= mem_wdata[23:16];
                                if (mem_wstrb[3]) prgm_memory[mem_addr >> 2][31:24] <= mem_wdata[31:24];
                            end else begin
                                mem_rdata <= prgm_memory[mem_addr >> 2];
                            end
                        end

                        // printing
                        (mem_addr == PRINT_ADDR): begin
                            $write("%c", mem_wdata[7:0]);
                        end

                        // cfg_addr
                        (mem_addr >= CFG_ADDR) && (mem_addr < CFG_ADDR + CFG_SIZE): begin
                            adj_addr = mem_addr - CFG_ADDR;
                            if (!(|mem_wstrb)) begin
                                mem_rdata <= cfg_memory[adj_addr >> 2];
                            end else begin
                                $display("Just tried to write to cfg addr?");
                            end
                        end

                        // to the cnn memory
                        (mem_addr >= CNN_ADDR): begin 
                            adj_addr = mem_addr - CNN_ADDR;
                            if (|mem_wstrb) begin
                                if (mem_wstrb[0]) cnn_memory[adj_addr >> 2][ 7: 0] <= mem_wdata[ 7: 0];
                                if (mem_wstrb[1]) cnn_memory[adj_addr >> 2][15: 8] <= mem_wdata[15: 8];
                                if (mem_wstrb[2]) cnn_memory[adj_addr >> 2][23:16] <= mem_wdata[23:16];
                                if (mem_wstrb[3]) cnn_memory[adj_addr >> 2][31:24] <= mem_wdata[31:24];
                            end else begin
                                mem_rdata <= cnn_memory[adj_addr >> 2];
                            end
                        end

                        default: $display("Tried to access mem outside MEM_SIZE: %h", mem_addr);
                    endcase
                end else begin
                    // Increment counter while waiting
                    delay_counter <= delay_counter + 1;
                end
            end else begin
                // We just finished a transaction. 
                // Keep the counter at 0 while we wait for the CPU to drop mem_valid.
                delay_counter <= 0;
            end
            
        end else begin
            // Reset counter if valid drops
            delay_counter <= 0;
        end
    end

    // =========================================================================
    // File I/O, Trace, and Logger (Kept exactly as you had it)
    // =========================================================================
    string program_memory_file;
    string cnn_memory_file;
    string cfg_file;
    string program_trace_file;
    string memory_access_file;
    integer trace_fd;
    integer mem_access_fd;
    integer cfg_fd;
    integer output_fd;
    integer retval;

    // Arg parsing and mem loading
    initial begin
        //dump for verdi
        $fsdbDumpfile("top_tb.fsdb");
        $fsdbDumpvars(0, top_tb);
        $fsdbDumpMDA();

        for (int j=0; j<MEM_WORDS; j++) prgm_memory[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) cnn_memory[j] = 0;
        for (int j=0; j<MEM_WORDS; j++) cnn_memory_clean[j] = 0;
        for (int j=0; j<32; j++)        cfg_memory[j] = 0;
        
        //plusargs files
        if ($value$plusargs("PRGM_MEMORY=%s", program_memory_file)) begin
            $display("Loading main memory file: %s", program_memory_file);
        end else begin
            $display("Loading default memory file: program.mem");
            program_memory_file = "program.mem";
        end

        //plusargs files
        if ($value$plusargs("CNN_MEMORY=%s", cnn_memory_file)) begin
            $display("Loading cnn memory file: %s", cnn_memory_file);
        end else begin
            $display("Loading default cnn memory file: top_test.mem");
            cnn_memory_file = "top_test.mem";
        end
        
        //trace_file
        if ($value$plusargs("TRACE=%s", program_trace_file)) begin
            $display("Using trace output file: %s", program_trace_file);
        end else begin
            $display("Using default trace output file: trace.out");
            program_trace_file = "trace.out";
        end
        trace_fd = $fopen(program_trace_file, "w");
        
        //mem_access file
        if ($value$plusargs("MEMACCESS=%s", memory_access_file)) begin
            $display("Using memory access output file: %s", memory_access_file);
        end else begin
            $display("Using default memory access file: mem_access.out");
            memory_access_file = "mem_access.out";
        end
        mem_access_fd = $fopen(memory_access_file, "w");

        //config file
        if ($value$plusargs("CONFIG=%s", cfg_file)) begin
            $display("Using config output file: %s", cfg_file);
        end else begin
            $display("Using default config file: top_test.cfg");
            cfg_file = "top_test.cfg";
        end
        cfg_fd = $fopen(cfg_file, "r");

        // Load the mem files
        $readmemh(program_memory_file, prgm_memory);
        $readmemh(cnn_memory_file, cnn_memory_clean);
        $readmemh(cnn_memory_file, cnn_memory);

        // Load the cfg file
        retval = $fscanf(cfg_fd, "comp_Hi: %h", cfg_memory[`HI]);
        retval = $fscanf(cfg_fd, "comp_Wi: %h", cfg_memory[`WI]);
        retval = $fscanf(cfg_fd, "comp_Hf: %h", cfg_memory[`HF]);
        retval = $fscanf(cfg_fd, "comp_Wf: %h", cfg_memory[`WF]);
        retval = $fscanf(cfg_fd, "comp_Ho: %h", cfg_memory[`HO]);
        retval = $fscanf(cfg_fd, "comp_Wo: %h", cfg_memory[`WO]);
        retval = $fscanf(cfg_fd, "comp_Ci: %h", cfg_memory[`CI]);
        retval = $fscanf(cfg_fd, "comp_num_kernels: %h", cfg_memory[`NUM_KERNELS]);
        retval = $fscanf(cfg_fd, "words_needed_for_Ci: %h", cfg_memory[`WORDS_NEEDED_FOR_CI]);
        retval = $fscanf(cfg_fd, "words_needed_for_Co: %h", cfg_memory[`WORDS_NEEDED_FOR_CO]);
        retval = $fscanf(cfg_fd, "comp_stride: %b", cfg_memory[`STRIDE]);
        retval = $fscanf(cfg_fd, "comp_padding: %b", cfg_memory[`PADDING]);
        retval = $fscanf(cfg_fd, "comp_maxpool_en: %b", cfg_memory[`MAXPOOL_EN]);
        retval = $fscanf(cfg_fd, "comp_relu_en: %b", cfg_memory[`RELU_EN]);
        retval = $fscanf(cfg_fd, "comp_scale_amt: %b", cfg_memory[`SCALE_AMT]);
        retval = $fscanf(cfg_fd, "act_start_addr: %h", cfg_memory[`ACT_START_ADDR]);
        retval = $fscanf(cfg_fd, "act_end_addr: %h", cfg_memory[`ACT_END_ADDR]);
        retval = $fscanf(cfg_fd, "wt_start_addr: %h", cfg_memory[`WT_START_ADDR]);
        retval = $fscanf(cfg_fd, "wt_end_addr: %h", cfg_memory[`WT_END_ADDR]);
        retval = $fscanf(cfg_fd, "output_start_addr: %h", cfg_memory[`OUTPUT_START_ADDR]);
        retval = $fscanf(cfg_fd, "output_end_addr: %h", cfg_memory[`OUTPUT_END_ADDR]);

        // Clear the output portion of our dut cnn memory
        for (int j=(cfg_memory[`OUTPUT_START_ADDR] >> 2); j<(cfg_memory[`OUTPUT_END_ADDR] >> 2); j++) cnn_memory[j] = 0;
        $display("Act Start Line #: %d", cfg_memory[`ACT_START_ADDR]/4 + 1);
        $display("Wt Start Line #: %d", cfg_memory[`WT_START_ADDR]/4 + 1);
        $display("Output Start Line #: %d", cfg_memory[`OUTPUT_START_ADDR]/4 + 1);

        cfg_memory[`ACT_START_ADDR]     += CNN_ADDR;
        cfg_memory[`ACT_END_ADDR]       += CNN_ADDR;
        cfg_memory[`WT_START_ADDR]      += CNN_ADDR;
        cfg_memory[`WT_END_ADDR]        += CNN_ADDR;
        cfg_memory[`OUTPUT_START_ADDR]  += CNN_ADDR;
        cfg_memory[`OUTPUT_END_ADDR]    += CNN_ADDR;
        rstn_sync <= 0;
        rstn_async <= 0;
        repeat (100) @(posedge clk_sys);
        #1;
        rstn_sync <= 1;
        rstn_async <= 1;
    end

    // Flight Data Recorder (Trace)
    initial begin
        repeat (10) @(posedge clk_sys);
        while (!trap) begin
            @(posedge clk_sys);
            if (trace_valid)
                $fwrite(trace_fd, "%x\n", trace_data);
        end
        $fclose(trace_fd);
    end

    // Memory Access Logger
    initial begin
        repeat (10) @(posedge clk_sys);
        while (!trap) begin
            @(posedge clk_sys);
            if (mem_valid && mem_ready) begin
                if (|mem_wstrb) begin
                    $fwrite(mem_access_fd, "WRITE: Addr=%08x, Data=%08x, Strb=%b\n", mem_addr, mem_wdata, mem_wstrb);
                end else begin
                    $fwrite(mem_access_fd, "READ:  Addr=%08x, Data=%08x\n", mem_addr, mem_rdata);
                end
            end
        end
        $fclose(mem_access_fd);
    end

    int num_errors;

    always @(posedge clk_sys) begin
        if (rstn_sync && trap) begin
            $display("CPU TRAP HIT");
            $display("Checking memory...");
            output_fd = $fopen("top_test_dut.mem", "w");
            num_errors = 0;
            for(int word = 0; word < MEM_WORDS; word +=1 ) begin
                if(word < ((cfg_memory[`OUTPUT_END_ADDR] - CNN_ADDR) >> 2)) $fwrite(output_fd, "%h\n", cnn_memory[word]);
                if(cnn_memory[word] !== cnn_memory_clean[word]) begin
                    num_errors += 1;
                    $display("Mismatch @%h act: %h exp: %h", (word << 2) + CNN_ADDR, cnn_memory[word], cnn_memory_clean[word]);
                end
            end
            if(num_errors == 0) begin
                $display("TEST PASSED!!!!!!!");
            end else begin
                $display("TEST FAILED WITH %d ERRORS!!!!!!!", num_errors);
            end
            $finish;
        end
    end

    // Timeout failsafe
    initial begin
        #50000000;
        $display("TIMEOUT ERROR: Simulation hung.");
        $finish;
    end

endmodule
