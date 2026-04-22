//systemVerilog HDL for "StrongARM", "dldo" "systemVerilog"


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

module dldo (    
    input              p_clk,         // PE clock
    input              p_rst_n,       // Active low reset
    
    // Hardcoded widths to avoid AMS-2151 netlisting errors
    input        [2:0] p_dvfs_sel,    // External voltage level selection
    input              p_ldo_cutoff,  // Power cut off signal
    input        [11:0] flash_adc_in,  // Internal input from flash adc (flash_adc_12)
   
    output logic [2:0] p_ldo_adc_out, // Converted flash adc out (for Power Good)
    output logic [7:0] pmos_drv_bin   // 8-bit Binary Output (Inverted: 8'hFF = All OFF)
);

// --- Internal Parameters ---
//localparam int DVFS_SLOTS = 6;
localparam int ADC_SLOTS = 12; //number of ADC bits for 12-bit precision (still 6 DVFS modes)
localparam int MAX_PMOS   = 256;
localparam int INITIAL_STARTUP_VALUE = 64;

// Tuning Parameters for PI Control (Gain = 2^SHIFT)
localparam int KP_SHIFT = 0;  // Proportional gain (e.g., 2 means x4)
localparam int KI_HIGH_SHIFT = 0;

// --- State Variables ---
logic [8:0] count; // 9 bits to safely hold up to 256, strictly clamped 0-255

//CHANGED
logic [3:0] adc_count_raw; // raw 12-step counts 
logic [3:0] target_code; // map our target DVFS operating points

// --- PI Controller Internal Signals ---
logic signed [4:0] target_val;
logic signed [4:0] current_val;
logic signed [4:0] error;
logic signed [4:0] prev_error;
logic signed [4:0] delta_error;

logic signed [9:0] p_term;
logic signed [9:0] i_term;
logic signed [10:0] next_count_calc; 

logic err_is_small;
logic prev_err_is_small;
logic steady_state;

// raw 12-bit ADC count
always_comb begin
	adc_count_raw = '0;
	for (int i = 0; i < ADC_SLOTS; i++) begin
		adc_count_raw += flash_adc_in[i];
	end
end

// Map the 12-step to our DVFS operating points
always_comb begin
    unique case (p_dvfs_sel)
        3'd1: target_code = 4'd1; //0.6V
        3'd2: target_code = 4'd3; //0.7V
        3'd3:    target_code = 4'd5;   // 0.80V
        3'd4:    target_code = 4'd7;   // 0.90V
        3'd5:    target_code = 4'd9;   // 1.00V
        3'd6:    target_code = 4'd11;  // 1.10V NOTE: if this is a big problem change to 1.15V 4'd12
        default: target_code = 4'd1;
    endcase

end

always_comb begin
    unique case (adc_count_raw)
	    4'd0 		: p_ldo_adc_out = 3'd0;
        4'd1, 4'd2   : p_ldo_adc_out = 3'd1;
        4'd3, 4'd4   : p_ldo_adc_out = 3'd2;
        4'd5, 4'd6   : p_ldo_adc_out = 3'd3;
        4'd7, 4'd8   : p_ldo_adc_out = 3'd4;
        4'd9, 4'd10  : p_ldo_adc_out = 3'd5;
        4'd11, 4'd12 : p_ldo_adc_out = 3'd6;
        default      : p_ldo_adc_out = 3'd0;
    endcase
    
end


// Binary PMOS Drive (Active Low / Inverse Polarity)
always_comb begin
    if (p_ldo_cutoff) begin
        pmos_drv_bin = 8'hFF; // 1111_1111 -> All PMOS forced OFF during cutoff
    end else begin
        pmos_drv_bin = ~count[7:0];
    end
end

// --- PI Control Math (Combinational) ---

// Safely cast to signed to avoid Verilog sign-extension bugs
// assign target_val  = {2'b00, p_dvfs_sel};
// assign current_val = {2'b00, p_ldo_adc_out};
assign target_val = {1'b0, target_code};
assign current_val = {1'b0, adc_count_raw};

assign error       = target_val - current_val;
assign delta_error = error - prev_error;

// Hardware-efficient "Small Error" detection
assign err_is_small      = (error == 5'sd0) || (error == 5'sd1) || (error == -5'sd1);
assign prev_err_is_small = (prev_error == 5'sd0) || (prev_error == 5'sd1) || (prev_error == -5'sd1);

// We only enter steady state if the error is small AND we aren't stuck on a droop
assign steady_state = err_is_small && prev_err_is_small;

// Zone-Based Gain Scheduling
always_comb begin
    if (steady_state) begin
        // Inside the zone: Pure Integrator, Gain = 1 (Exactly +/- 1 PMOS)
        p_term = '0;
        i_term = error; 
    end else begin
        // Outside the zone (or stuck in a droop!): High-Gain Acceleration
        p_term = delta_error <<< KP_SHIFT;
        i_term = error <<< KI_HIGH_SHIFT; 
    end
end

// Calculate the raw next count, not apply p_term if going down
always_comb begin
	if(p_term < 0) next_count_calc = $signed({2'b00, count}) + i_term;
	else next_count_calc = $signed({2'b00, count}) + p_term + i_term;
end

// --- PI Control State Machine ---
always_ff @(posedge p_clk or negedge p_rst_n) begin
    if (!p_rst_n) begin
        count      <= INITIAL_STARTUP_VALUE;
        prev_error <= '0;
    end else if (p_ldo_cutoff) begin
        count      <= '0; // 0 count internally means 0 PMOS active
        prev_error <= '0;
    end else begin
        prev_error <= error;
        
        // Saturation/Anti-Windup Logic limits `count` strictly between 0 and 255
        if (next_count_calc > (MAX_PMOS - 1))
            count <= MAX_PMOS - 1;
        else if (next_count_calc <= 0)
            count <= 1;
        else
            count <= next_count_calc[8:0];
    end
end

// Debugging: Monitor variables in SimVision Console
// initial begin
//     $display("AMS_DEBUG: DLDO Binary PI Module Initialized");
//     $monitor("TIME: %0t | RST: %b | ADC: %d | SEL: %d | ERR: %d | COUNT: %d | PMOS_DRV: %b", 
//               $time, p_rst_n, p_ldo_adc_out, p_dvfs_sel, error, count, pmos_drv_bin);
// end

endmodule