//systemVerilog HDL for "StrongARM", "dldo_tb" "systemVerilog"


`timescale 1ns / 1ps
module dldo_tb (
    // Outputs from the testbench to drive the DUT
    output logic DLDO_CLK,
    output logic [2:0] DVFS_SEL,
    output logic RST_N,
    output logic SENSE_CLK,
    output logic CUTOFF,

    // Inputs to monitor from the DUT
    input logic [2:0] ADC_OUT
);

    // 1. Clock Generation
    initial begin
        DLDO_CLK = 0;
        forever #3.3 DLDO_CLK = ~DLDO_CLK; // 10ns period (100MHz)
    end

    initial begin
        SENSE_CLK = 0;
        forever #3.3 SENSE_CLK = ~SENSE_CLK; // 20ns period (50MHz)
    end

    // 2. Main Stimulus Sequence
    initial begin
        // Initialize all signals
 		RST_N = 1'b1;
       	DVFS_SEL = 3'b000;
	    CUTOFF = 1'b0;
	 	#1 	
 	    RST_N = 1'b0;

        // Wait a bit, then release reset
        #25;
        RST_N = 1'b1;

        // Apply some test vectors
        #50;
        DVFS_SEL = 3'b101;
        
        #100;

        DVFS_SEL = 3'b000;
        
        // End the simulation
        #1000;
        $finish; 
    end

    // 3. Optional: Monitor changes
    // always @(ADC_OUT) begin
    //     $display("Time: %0t | ADC_OUT: %b", $time, ADC_OUT);
    // end

endmodule