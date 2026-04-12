module axi_arbiter #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(                            
    input wire clk,
    input wire rst_n,

    // CPU MASTER
    input  wire                  i_cpu_valid,
    output reg                   o_cpu_ready,
    input  wire [ADDR_WIDTH-1:0] i_cpu_addr,
    input  wire [DATA_WIDTH-1:0] i_cpu_wdata,
    input  wire [3:0]            i_cpu_wstrb,
    output wire [DATA_WIDTH-1:0] o_cpu_rdata,

    // NPU MASTER
    // Read Channels
    input  wire [ADDR_WIDTH-1:0] i_npu_araddr,
    input  wire [7:0]            i_npu_arlen,
    input  wire [2:0]            i_npu_arsize,
    input  wire                  i_npu_arvalid,
    output reg                   o_npu_arready,
    output wire [DATA_WIDTH-1:0] o_npu_rdata,
    output reg                   o_npu_rlast,
    output reg                   o_npu_rvalid,
    input  wire                  i_npu_rready,
    // Write Channels
    input  wire [ADDR_WIDTH-1:0] i_npu_awaddr,
    input  wire [7:0]            i_npu_awlen,
    input  wire [2:0]            i_npu_awsize,
    input  wire                  i_npu_awvalid,
    output reg                   o_npu_awready,
    input  wire [DATA_WIDTH-1:0] i_npu_wdata,
    input  wire [3:0]            i_npu_wstrb,
    input  wire                  i_npu_wlast,
    input  wire                  i_npu_wvalid,
    output wire                  o_npu_wready,
    
    // Added B-Channel for Write Response
    output reg  [1:0]            o_npu_bresp,
    output reg                   o_npu_bvalid,
    input  wire                  i_npu_bready,

    // MEMORY SLAVE (Now Registered via Pipeline)
    output wire                  o_mem_valid,
    input  wire                  i_mem_ready,
    output wire [ADDR_WIDTH-1:0] o_mem_addr,
    output wire [DATA_WIDTH-1:0] o_mem_wdata,
    output wire [3:0]            o_mem_wstrb,
    input  wire [DATA_WIDTH-1:0] i_mem_rdata
);

    localparam ST_IDLE       = 3'd0;
    localparam ST_NPU_RBURST = 3'd1;
    localparam ST_CPU_ACCESS = 3'd2;
    localparam ST_NPU_WBURST = 3'd3;
    localparam ST_NPU_BRESP  = 3'd4;

    reg [2:0] state, next_state;
    reg [ADDR_WIDTH-1:0] burst_addr;
    reg [7:0]            burst_count;
    reg [2:0]            burst_size;       

    // Internal combinatorial signals interfacing with the pipeline
    wire                  int_mem_ready;
    wire [DATA_WIDTH-1:0] int_mem_rdata;
    reg                   int_mem_valid;
    reg  [ADDR_WIDTH-1:0] int_mem_addr;
    reg  [DATA_WIDTH-1:0] int_mem_wdata;
    reg  [3:0]            int_mem_wstrb;


    // Instantiate Output Pipeline Stage
    axi_mem_pipeline #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH)
    ) mem_pipe_inst (
        .clk        (clk),
        .rst_n      (rst_n),
        
        // Internal Combinatorial Connections
        .i_arb_valid(int_mem_valid),
        .o_arb_ready(int_mem_ready),
        .i_arb_addr (int_mem_addr),
        .i_arb_wdata(int_mem_wdata),
        .i_arb_wstrb(int_mem_wstrb),
        .o_arb_rdata(int_mem_rdata),
        
        // External Physical Pads
        .o_mem_valid(o_mem_valid),
        .i_mem_ready(i_mem_ready),
        .o_mem_addr (o_mem_addr),
        .o_mem_wdata(o_mem_wdata),
        .o_mem_wstrb(o_mem_wstrb),
        .i_mem_rdata(i_mem_rdata)
    );

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= next_state;
    end

    always @(*) begin
        next_state = state;
        o_npu_arready = 1'b0;
        o_npu_awready = 1'b0;
        case (state)
            ST_IDLE: begin
                if (i_npu_awvalid) begin 
                    next_state = ST_NPU_WBURST;
                    o_npu_awready = 1'b1;
                end else if (i_npu_arvalid) begin
                    next_state = ST_NPU_RBURST;
                    o_npu_arready = 1'b1;
                end else if (i_cpu_valid)   next_state = ST_CPU_ACCESS;
            end
            ST_CPU_ACCESS: begin
                // Replaced i_mem_ready with pipeline's int_mem_ready
                if (i_cpu_valid && int_mem_ready) next_state = ST_IDLE;
            end
            ST_NPU_RBURST: begin
                if (int_mem_ready && i_npu_rready && (burst_count == 8'd0)) 
                    next_state = ST_IDLE;
            end
            ST_NPU_WBURST: begin
                if (int_mem_ready && i_npu_wvalid && (burst_count == 8'd0) && i_npu_wlast)
                    next_state = ST_NPU_BRESP;
            end
            ST_NPU_BRESP: begin
                if (i_npu_bready) next_state = ST_IDLE;
            end
        endcase
    end

    assign o_npu_wready  = (state == ST_NPU_WBURST) && int_mem_ready;
    assign o_cpu_rdata   = int_mem_rdata;
    assign o_npu_rdata   = int_mem_rdata;

    always @(*) begin
        int_mem_valid  = 1'b0;
        int_mem_addr   = burst_addr; 
        int_mem_wdata  = i_npu_wdata;
        int_mem_wstrb  = 4'd0;
        o_cpu_ready    = 1'b0;

        o_npu_rvalid = 1'b0;
        o_npu_rlast  = 1'b0;
        o_npu_bvalid = 1'b0;
        o_npu_bresp  = 2'b00;

        case (state)
            ST_IDLE: begin
                if (i_npu_awvalid) begin
                    int_mem_addr  = i_npu_awaddr;
                    int_mem_wdata = i_npu_wdata;
                    int_mem_wstrb = i_npu_wstrb;
                end else if (i_npu_arvalid) begin
                    int_mem_addr  = i_npu_araddr;
                end else if (i_cpu_valid) begin
                    int_mem_addr  = i_cpu_addr;
                    int_mem_wdata = i_cpu_wdata;
                    int_mem_wstrb = i_cpu_wstrb;
                    o_cpu_ready   = int_mem_ready;
                end
            end

            ST_CPU_ACCESS: begin
                int_mem_valid = i_cpu_valid;
                int_mem_addr  = i_cpu_addr;
                int_mem_wdata = i_cpu_wdata;
                int_mem_wstrb = i_cpu_wstrb;
                o_cpu_ready   = int_mem_ready;
            end

            ST_NPU_RBURST: begin
                int_mem_valid = i_npu_rready; 
                int_mem_addr  = burst_addr;
                o_npu_rvalid  = int_mem_ready;
                o_npu_rlast   = (burst_count == 8'd0);
            end

            ST_NPU_WBURST: begin
                int_mem_valid = i_npu_wvalid;
                int_mem_addr  = burst_addr;
                int_mem_wdata = i_npu_wdata;
                int_mem_wstrb = i_npu_wstrb;
            end

            ST_NPU_BRESP: begin
                o_npu_bvalid = 1'b1;
            end
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            burst_addr  <= 32'd0;
            burst_count <= 8'd0;
            burst_size  <= 3'd0;
        end else if (state == ST_IDLE) begin
            if (i_npu_awvalid) begin
                burst_addr  <= i_npu_awaddr + (int_mem_ready && i_npu_wvalid ? (32'd1 << i_npu_awsize) : 0);
                burst_count <= i_npu_awlen;
                burst_size  <= i_npu_awsize;
            end else if (i_npu_arvalid) begin
                burst_addr  <= i_npu_araddr;
                burst_count <= i_npu_arlen;
                burst_size  <= i_npu_arsize;
            end
        end else if (state == ST_NPU_RBURST && int_mem_ready && i_npu_rready) begin
            if (burst_count != 8'd0) begin
                burst_count <= burst_count - 8'd1;
                burst_addr  <= burst_addr + (32'd1 << burst_size);
            end
        end else if (state == ST_NPU_WBURST && int_mem_ready && i_npu_wvalid) begin
            if (burst_count != 8'd0) begin
                burst_count <= burst_count - 8'd1;
                burst_addr  <= burst_addr + (32'd1 << burst_size);
            end
        end
    end

endmodule