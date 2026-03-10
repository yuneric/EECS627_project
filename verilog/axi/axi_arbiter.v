module axi_arbiter #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(                            
    input wire clk,
    input wire rst_n,

    // CPU MASTER
    input  wire                  i_cpu_valid, //inputing valid instruction
    output reg                   o_cpu_ready, //the memory data sent is valid.
    input  wire [ADDR_WIDTH-1:0] i_cpu_addr, //the address to read from.
    input  wire [DATA_WIDTH-1:0] i_cpu_wdata, //write data to the cpu.
    input  wire [3:0]            i_cpu_wstrb, //the word mask
    output wire [DATA_WIDTH-1:0] o_cpu_rdata, //data read from memory.

    // NPU MASTER
    // Read Channels
    input  wire [ADDR_WIDTH-1:0] i_npu_araddr, //the npu address for read
    input  wire [7:0]            i_npu_arlen, //the number of bursts
    input  wire [2:0]            i_npu_arsize, //the beat size
    input  wire                  i_npu_arvalid, //if the address you're passing is valid
    output reg                  o_npu_arready, //if the npu signal can change to the next thing
    output wire [DATA_WIDTH-1:0] o_npu_rdata, //the npu read data
    output reg                   o_npu_rlast, //the npu rlast is the last beat.
    output reg                   o_npu_rvalid, //the data the memory sent is valid
    input  wire                  i_npu_rready, //the npu is ready to receive values.
    // Write Channels
    input  wire [ADDR_WIDTH-1:0] i_npu_awaddr, //the npu address for write
    input  wire [7:0]            i_npu_awlen, //the number of bursts
    input  wire [2:0]            i_npu_awsize, //the beat size
    input  wire                  i_npu_awvalid, //if the address you're passing is valid
    output reg                  o_npu_awready, //if the npu could move onto changing the next thing
    input  wire [DATA_WIDTH-1:0] i_npu_wdata, //the write data.
    input  wire [3:0]            i_npu_wstrb, //the mask.
    input  wire                  i_npu_wlast, //the last input it wants to write
    input  wire                  i_npu_wvalid, //the write its sending is valid
    output wire                  o_npu_wready, //the npu could move onto outputting the next set of data
    
    // Added B-Channel for Write Response
    output reg  [1:0]            o_npu_bresp, //a good write has taken place
    output reg                   o_npu_bvalid, //the write is good.
    input  wire                  i_npu_bready, //the npu is ready to receive the signal.

    // MEMORY SLAVE
    output reg                   o_mem_valid,
    input  wire                  i_mem_ready,
    output reg  [ADDR_WIDTH-1:0] o_mem_addr,
    output reg  [DATA_WIDTH-1:0] o_mem_wdata,
    output reg  [3:0]            o_mem_wstrb,
    input  wire [DATA_WIDTH-1:0] i_mem_rdata
);

    localparam ST_IDLE       = 3'd0;
    localparam ST_NPU_RBURST = 3'd1;
    localparam ST_CPU_ACCESS = 3'd2;
    localparam ST_NPU_WBURST = 3'd3;
    localparam ST_NPU_BRESP  = 3'd4; // Final write response state

    reg [2:0] state, next_state;
    reg [ADDR_WIDTH-1:0] burst_addr;
    reg [7:0]            burst_count;
    reg [2:0]            burst_size;       

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
                //The npu write is given priority
                if (i_npu_awvalid) begin 
                    next_state = ST_NPU_WBURST;
                    o_npu_awready = 1'b1;
                end else if (i_npu_arvalid) begin
                    next_state = ST_NPU_RBURST;
                    o_npu_arready = 1'b1;
                end else if (i_cpu_valid)   next_state = ST_CPU_ACCESS;
            end
            ST_CPU_ACCESS: begin
                if (i_cpu_valid && i_mem_ready) next_state = ST_IDLE;
            end
            ST_NPU_RBURST: begin
                //if npu is ready to receive values and memory is ready and the burst count is 0, then NPU should be done with reading, so could move to the idle state
                if (i_mem_ready && i_npu_rready && (burst_count == 8'd0)) 
                    next_state = ST_IDLE;
            end
            ST_NPU_WBURST: begin
                //if npu is ready to write values and memory is ready to receive and burst count is 0. then NPU should be done with writing, so move to response phase.
                if (i_mem_ready && i_npu_wvalid && (burst_count == 8'd0))
                    next_state = ST_NPU_BRESP;
            end
            //this is the signal saying that you're all done from memory. it received the last write and you could move on.
            ST_NPU_BRESP: begin
                if (i_npu_bready) next_state = ST_IDLE;
            end
        endcase
    end


    //if the state is idle and we're not writing so we could move on
    //assign o_npu_arready = (state == ST_IDLE) && !i_npu_awvalid;

    //if the state is idle, so ready to move on to next operation
    //assign o_npu_awready = (state == ST_IDLE);

    //if the data from wready is valid
    assign o_npu_wready  = (state == ST_NPU_WBURST) && i_mem_ready;

    //reading data from memory.
    assign o_cpu_rdata   = i_mem_rdata;
    assign o_npu_rdata   = i_mem_rdata;

    always @(*) begin
        //default signals
        o_mem_valid  = 1'b0;

        //feed in the cpu addr and cpu_wdata
        o_mem_addr   = burst_addr; // Default to burst addr to maintain continuity
        o_mem_wdata  = i_npu_wdata;
        o_mem_wstrb  = 4'd0;
        o_cpu_ready  = 1'b0;

        //npu rvalid and rlast is low.
        o_npu_rvalid = 1'b0;
        o_npu_rlast  = 1'b0;
        o_npu_bvalid = 1'b0;
        o_npu_bresp  = 2'b00;

        case (state)
            ST_IDLE: begin
                if (i_npu_awvalid) begin
                    o_mem_valid = i_npu_wvalid;
                    o_mem_addr  = i_npu_awaddr;
                    o_mem_wdata = i_npu_wdata;
                    o_mem_wstrb = i_npu_wstrb;
                end else if (i_npu_arvalid) begin
                    o_mem_valid = 1'b1; //fine to read randomly.
                    o_mem_addr  = i_npu_araddr;
                end else if (i_cpu_valid) begin
                    o_mem_valid = i_cpu_valid;
                    o_mem_addr  = i_cpu_addr;
                    o_mem_wdata = i_cpu_wdata;
                    o_mem_wstrb = i_cpu_wstrb;
                    o_cpu_ready = i_mem_ready;
                end
            end


            ST_CPU_ACCESS: begin
                o_mem_valid = i_cpu_valid;
                o_mem_addr  = i_cpu_addr;
                o_mem_wdata = i_cpu_wdata;
                o_mem_wstrb = i_cpu_wstrb;
                o_cpu_ready = i_mem_ready;
            end

            //npu is good to read, so mem is valid. 
            //else turn it off.
            ST_NPU_RBURST: begin
                o_mem_valid  = i_npu_rready; 
                o_mem_addr   = burst_addr;
                o_npu_rvalid = i_mem_ready;
                o_npu_rlast  = (burst_count == 8'd0);
            end

            //npu is good to write, so enable memory.
            ST_NPU_WBURST: begin
                o_mem_valid = i_npu_wvalid;
                o_mem_addr  = burst_addr;
                o_mem_wdata = i_npu_wdata;
                o_mem_wstrb = i_npu_wstrb;
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
                //increment burst_addr if mem_ready and then the value that you're inputing wvalid. 
                burst_addr  <= i_npu_awaddr + (i_mem_ready && i_npu_wvalid ? (32'd1 << i_npu_awsize) : 0);
                burst_count <= i_npu_awlen;
                burst_size  <= i_npu_awsize;
            end else if (i_npu_arvalid) begin
                //if arvalid, then pass in i_npu_araddr.
                burst_addr  <= i_npu_araddr;
                burst_count <= i_npu_arlen;
                burst_size  <= i_npu_arsize;
            end
        //if npu read burst, mem_ready, and npu rready so ready to receive data then we want to move onto next set.
        end else if (state == ST_NPU_RBURST && i_mem_ready && i_npu_rready) begin
            if (burst_count != 8'd0) begin
                burst_count <= burst_count - 8'd1;
                burst_addr  <= burst_addr + (32'd1 << burst_size);
            end
        //if npu write burst, memory is ready, and input write is valid, so could move onto next.
        end else if (state == ST_NPU_WBURST && i_mem_ready && i_npu_wvalid) begin
            if (burst_count != 8'd0) begin
                burst_count <= burst_count - 8'd1;
                burst_addr  <= burst_addr + (32'd1 << burst_size);
            end
        end
    end

endmodule