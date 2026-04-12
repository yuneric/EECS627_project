module axi_mem_pipeline #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire clk,
    input  wire rst_n,

    // Combinational side (to Arbiter)
    input  wire                   i_arb_valid,
    output wire                   o_arb_ready,
    input  wire [ADDR_WIDTH-1:0]  i_arb_addr,
    input  wire [DATA_WIDTH-1:0]  i_arb_wdata,
    input  wire [3:0]             i_arb_wstrb,
    output wire [DATA_WIDTH-1:0]  o_arb_rdata,

    // Registered side (to Memory Pads)
    output reg                    o_mem_valid,
    input  wire                   i_mem_ready,
    output reg  [ADDR_WIDTH-1:0]  o_mem_addr,
    output reg  [DATA_WIDTH-1:0]  o_mem_wdata,
    output reg  [3:0]             o_mem_wstrb,
    input  wire [DATA_WIDTH-1:0]  i_mem_rdata
);

    reg [DATA_WIDTH-1:0] rdata_reg;
    reg                  ready_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            o_mem_valid <= 1'b0;
            o_mem_addr  <= {ADDR_WIDTH{1'b0}};
            o_mem_wdata <= {DATA_WIDTH{1'b0}};
            o_mem_wstrb <= 4'd0;
            
            ready_reg   <= 1'b0;
            rdata_reg   <= {DATA_WIDTH{1'b0}};
        end else begin
            // Default: ensure ready flag pulses for exactly 1 cycle back to the arbiter
            ready_reg <= 1'b0;

            if (o_mem_valid && i_mem_ready) begin
                // Off-chip Memory accepted the request
                o_mem_valid <= 1'b0; 
                ready_reg   <= 1'b1;
                rdata_reg   <= i_mem_rdata;
            end else if (i_arb_valid && !o_mem_valid && !ready_reg) begin
                // Launch new request. 
                // !ready_reg blocks back-to-back writes for 1 cycle to allow arbiter's address to safely increment.
                o_mem_valid <= 1'b1;
                o_mem_addr  <= i_arb_addr;
                o_mem_wdata <= i_arb_wdata;
                o_mem_wstrb <= i_arb_wstrb;
            end
        end
    end

    assign o_arb_ready = ready_reg;
    assign o_arb_rdata = rdata_reg;

endmodule