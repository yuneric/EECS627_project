module pe #(
    parameter DATA_WIDTH  = 8
    parameter PSUM_WIDTH  = 24  
)(
    input wire clk,
    input wire rst_n,
    input wire weight_load;                         //when we are in weight load phase?
    input wire [(PSUM_WIDTH - 1):0] psum_in,        //psum coming from the top pe
    input wire [(DATA_WIDTH - 1):0] acc_in,         //activation flowing from the left 
    input wire [(DATA_WIDTH - 1):0] weight_in,      //weight passed into the pe, when loading weights

    output wire [(PSUM_WIDTH - 1):0] psum_out,      //psum -> below pe
    output wire [(DATA_WIDTH - 1):0] weight_out
)

    wire [(PSUM_WIDTH-1):0] mac_result;
    reg [(PSUM_WIDTH - 1):0] psum_reg;              //psum reg
    reg [(DATA_WIDTH - 1):0] weight_reg;            //weight reg width shouldn't the same i think
    reg [(DATA_WIDTH - 1):0] acc_reg;

    // psum = (acc_in * weight) + psum_passed from top
    assign mac_result = (acc_in * weight_reg) + psum_in;

    // got this from discussion slide
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            psum_out <= {DATA_WIDTH{1'b0}};
            weight_out <= {DATA_WIDTH{1'b0}}
        end
        else if (weight_load) begin 
            weight_reg <= weight_in;
            weight_out <= weight_in;
        end
        else begin
            psum_out <= 
            acc_reg <= acc_in;
            psum_reg <= mac_result;
        end
    end

endmodule