module pe#(
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 16 
)(
    input wire                              clk,
    input wire                              rst_n,
    //input wire weight_load,                         //when we are in weight load phase?
    //input wire signed [(PSUM_WIDTH - 1):0] psum_in,        //psum coming from the top pe
    input wire signed [(DATA_WIDTH - 1):0] act_in,         //activation flowing from the left 
    input wire signed [(DATA_WIDTH - 1):0] weight_in,      //get weight from north pe

    // Accumulator control
    input  wire  clear,  // start a new output
    input  wire  compute_en, //accumulate this cycle
    input  wire  drain,  //final psum

    //output wire signed [(PSUM_WIDTH - 1):0] psum_out,      //psum -> below pe (for weight stationary)
    output wire signed [(DATA_WIDTH - 1):0] weight_out, //weight passed to the bottom
    output wire signed [(DATA_WIDTH - 1):0] act_out,  //activations are passed to the right
    
    //final output
    output wire signed [(PSUM_WIDTH - 1):0] psum_out,
    output wire out_valid // signal assert when the computation across all the cycles is done

);

    // since we are just doing 8*8 bits multiply
    wire signed [(2*DATA_WIDTH-1):0] mac_result;

    // two's complement
    reg signed [(PSUM_WIDTH - 1):0] psum_reg; //psum reg
    // psum_reg holds hte current computation and hte final_out reg is the final after all the cycles are done
    reg signed [(DATA_WIDTH - 1):0] weight_reg;  //weight reg
    reg signed [(DATA_WIDTH - 1):0] act_reg;
    // reg signed done_reg; // when the calculation for all the activations cycles are done?

    assign mac_result = (act_reg * weight_reg);
    assign out_valid = drain; 

    // got this from discussion slide
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            psum_reg <= {PSUM_WIDTH{1'b0}};
            weight_reg <= {DATA_WIDTH{1'b0}};
            act_reg <= {DATA_WIDTH{1'b0}};
        end
        else begin
            // start a new accumulation cycle
            weight_reg <= weight_in;            
            act_reg <= act_in;
            if (clear) psum_reg <= {PSUM_WIDTH{1'b0}};
            // only accumulate when controller enables?
            else if (compute_en) begin
                // previous stored psum is added to the current cycle psum
                psum_reg <= psum_reg + mac_result;
            end
        end
    end

    assign psum_out = psum_reg;
    assign act_out = act_reg;
    assign weight_out = weight_reg;

endmodule