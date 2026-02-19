module sync_fifo #(
    parameter WIDTH = 64,
    parameter DEPTH = 4
)(
    input  wire             clk,
    input  wire             rst_n,

    // Write port
    input  wire [WIDTH-1:0] wr_data,
    input  wire             wr_en,
    output wire             full,

    // Read port
    output wire [WIDTH-1:0] rd_data,
    input  wire             rd_en,
    output wire             empty
);

    localparam ADDR_W = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_W:0]  wr_ptr;  // Extra bit for full/empty detection
    reg [ADDR_W:0]  rd_ptr;

    wire [ADDR_W-1:0] wr_addr = wr_ptr[ADDR_W-1:0];
    wire [ADDR_W-1:0] rd_addr = rd_ptr[ADDR_W-1:0];

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[ADDR_W] != rd_ptr[ADDR_W]) &&
                   (wr_ptr[ADDR_W-1:0] == rd_ptr[ADDR_W-1:0]);

    assign rd_data = mem[rd_addr];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (wr_en && !full) begin
                mem[wr_addr] <= wr_data;
                wr_ptr <= wr_ptr + 1;
            end
            if (rd_en && !empty) begin
                rd_ptr <= rd_ptr + 1;
            end
        end
    end

endmodule