// module dldo for dvfs and cut-off
// this module will stay always on, with a clock that's always on
// the clock is the PE clock, so probably gate it to the PE core but give DLDO uninterrupted access
// 
// Cut-off:
// Cut-off need to cross clock domain into here
// power on sequence from cut-off
// 1. assert reset for power domain that's starting up
// 2. deassert p_ldo_cutoff
// 3. monitor p_ldo_adc_out, deassert reset after some safety margin desired operating point reached

module dldo #(
    parameter DVFS_SLOTS  = 6,
    parameter MAX_PMOS = 256,
    parameter INITIAL_STARTUP_VALUE = 255
)(	
    input p_clk,  // PE clock
    input p_rst_n,
    
    // External input for voltage level selection;
    input [$clog2(DVFS_SLOTS)-1:0] p_dvfs_sel,
    
    // External input, power cut off
    input p_ldo_cutoff,
    
    // Internal input from flash adc
    input [DVFS_SLOTS-1:0] flash_adc_in,
   
    // External output forwarding a converted flash adc out
    // Use this for power good
    output logic [$clog2(DVFS_SLOTS)-1:0] p_ldo_adc_out,
    
    // Internal output to PMOS ladder
    output logic [MAX_PMOS-1:0] pmos_drv
);

logic err_sig; // error sign
logic [$clog2(MAX_PMOS)-1:0] count; // count of how many pmos on PLUS ONE
logic [MAX_PMOS-1:0] count_therometer; // count in thermometer coding

// convert adc reading from thermometer to binary
always_comb begin
	p_ldo_adc_out = 0;
	for(int i=0; i<DVFS_SLOTS; ++i) begin
		p_ldo_adc_out+=flash_adc_in[i];
	end
end

assign err_sig = (p_ldo_adc_out <= p_dvfs_sel) ? 1 : 0;

// one line binary to thermometer conversion
assign count_therometer = p_ldo_cutoff ? 0 : (1<<(count+1))-1;
// pmos inverse polarity
assign pmos_drv = ~count_therometer;

always @(posedge p_clk or negedge p_rst_n) begin
    if (!p_rst_n) 
        count <= INITIAL_STARTUP_VALUE; // Start with a safe number of PMOS on
    else if (p_ldo_cutoff)
        count <= 0; // this is actuall one, but that's OK, see above
    else if (err_sig == 1 && count < MAX_PMOS-1)
        count <= count + 1;
    else if (err_sig == 0 && count > 0)
        count <= count - 1;
end

endmodule
