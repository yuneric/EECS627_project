module pe#(
    parameter DATA_WIDTH  = 8,
    parameter PSUM_WIDTH  = 32 
)(
    input wire clk,
    input wire rst_n,
    input wire weight_load,                         //when we are in weight load phase?
    input wire signed [(PSUM_WIDTH - 1):0] psum_in,        //psum coming from the top pe
    input wire signed [(DATA_WIDTH - 1):0] act_in,         //activation flowing from the left 
    input wire signed [(DATA_WIDTH - 1):0] weight_in,      //get weight from north pe

    output wire signed [(PSUM_WIDTH - 1):0] psum_out,      //psum -> below pe
    output wire signed [(DATA_WIDTH - 1):0] weight_out,
    output wire signed [(DATA_WIDTH - 1):0] act_out        // activations are passed to the right
);

    wire [(PSUM_WIDTH-1):0] mac_result;
    // two's complement
    reg signed [(PSUM_WIDTH - 1):0] psum_reg;              //psum reg
    reg signed [(DATA_WIDTH - 1):0] weight_reg;            //weight reg
    reg signed [(DATA_WIDTH - 1):0] act_reg;

    // psum = (act_in * weight) + psum_passed from top
    // psum_wdith = 16 bits + log2(N) = 20 bits
    assign mac_result = (act_in * weight_reg) + psum_in;

    // got this from discussion slide
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            psum_reg <= {PSUM_WIDTH{1'b0}};
            weight_reg <= {DATA_WIDTH{1'b0}};
            act_reg <= {DATA_WIDTH{1'b0}};
        end
        else if (weight_load) begin 
            // when loading weight we are passing that weight to the bottom pe
            // no activation crossing to the right pe taking place?
            weight_reg <= weight_in;
            act_reg <= {DATA_WIDTH{1'b0}};
            psum_reg <= {PSUM_WIDTH{1'b0}};
        end
        else begin
            // controller will delay the input to the pe?
            act_reg <= act_in;
            psum_reg <= mac_result;
        end
    end

    assign psum_out = psum_reg;
    assign act_out = act_reg;
    assign weight_out = weight_reg;

endmodule