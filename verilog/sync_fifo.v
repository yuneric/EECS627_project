module sync_fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 4       // must be power of 2
)(
    input  wire                     clk,
    input  wire                     rst_n,

    // Write port
    input  wire                     wr_en,
    input  wire [WIDTH-1:0]         wr_data,

    // Read port
    input  wire                     rd_en,
    output wire [WIDTH-1:0]         rd_data,

    // Status
    output wire                     full,
    output wire                     empty,
    output wire [$clog2(DEPTH):0]   count
);

    localparam PTR_WIDTH = $clog2(DEPTH);

    reg [PTR_WIDTH:0] wr_ptr;
    reg [PTR_WIDTH:0] rd_ptr;

    // Storage
    reg [WIDTH-1:0] mem [0:DEPTH-1];

    assign full  = (wr_ptr[PTR_WIDTH] != rd_ptr[PTR_WIDTH]) &&
                   (wr_ptr[PTR_WIDTH-1:0] == rd_ptr[PTR_WIDTH-1:0]);
    assign empty = (wr_ptr == rd_ptr);
    assign count = wr_ptr - rd_ptr;

    // Combinational read output
    assign rd_data = mem[rd_ptr[PTR_WIDTH-1:0]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else if (wr_en && !full) begin
            mem[wr_ptr[PTR_WIDTH-1:0]] <= wr_data;
            wr_ptr <= wr_ptr + 1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= 0;
        end else if (rd_en && !empty) begin
            rd_ptr <= rd_ptr + 1;
        end
    end

endmodule