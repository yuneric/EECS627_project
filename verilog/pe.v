module pe#(
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 32 
)(
    input wire                              clk,
    input wire                              rst_n,
    //input wire weight_load,                         //when we are in weight load phase?
    //input wire signed [(PSUM_WIDTH - 1):0] psum_in,        //psum coming from the top pe
    input wire signed [(DATA_WIDTH - 1):0] act_in,         //activation flowing from the left 
    input wire signed [(DATA_WIDTH - 1):0] weight_in,      //get weight from north pe

    // Accumulator control
    input  wire  clear,  // start a new output
    input  wire  acc_en, //accumulate this cycle
    input  wire  drain,  //final psum

    //output wire signed [(PSUM_WIDTH - 1):0] psum_out,      //psum -> below pe (for weight stationary)
    output wire signed [(DATA_WIDTH - 1):0] weight_out, //weight passed to the bottom
    output wire signed [(DATA_WIDTH - 1):0] act_out,  //activations are passed to the right
    
    //final output
    output wire signed [(PSUM_WIDTH - 1):0] final_out

);

    wire signed [(PSUM_WIDTH-1):0] mac_result;

    // two's complement
    reg signed [(PSUM_WIDTH - 1):0] psum_reg, final_out_reg; //psum reg
    reg signed [(DATA_WIDTH - 1):0] weight_reg;  //weight reg
    reg signed [(DATA_WIDTH - 1):0] act_reg;
    reg signed done_reg; // when the calculation for all the activations cycles are done?

    // psum = (act_in * weight) + psum_passed from top
    // psum_wdith = 16 bits + log2(N) = 20 bits
    // weights stationary -> assign mac_result = (act_in * weight_reg) + psum_in;
    assign mac_result = (act_in * weight_reg);

    // got this from discussion slide
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            psum_reg <= {PSUM_WIDTH{1'b0}};
            weight_reg <= {DATA_WIDTH{1'b0}};
            act_reg <= {DATA_WIDTH{1'b0}};
            final_out_reg <= {DATA_WIDTH{1'b0}}';
            done_reg <= '0
        end
        else begin
            // start a new accumulation cycle
            if (clear)
                final_out_reg <= {DATA_WIDTH{1'b0}};
            else if (acc_en && ) begin
                // previous stored psum is added to the current cycle psum
                psum_reg <= psum_reg + mac_result;
            end
            act_reg <= act_in;
            psum_reg <= mac_result;
        end
    end

    assign final_out = psum_reg;
    assign act_out = act_reg;
    assign weight_out = weight_reg;

endmodule