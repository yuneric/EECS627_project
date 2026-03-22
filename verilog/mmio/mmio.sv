
`define COMMAND_REG              8'h00
`define COMP_CFG_REG             8'h01
`define COMP_CFG_H_REG           8'h02
`define COMP_CFG_W_REG           8'h03
`define COMP_CFG_C_REG           8'h04
`define INPUT_TILE_CFG_H_REG     8'h05
`define INPUT_TILE_CFG_W_REG     8'h06
`define INPUT_TILE_CFG_C_REG     8'h07
`define INPUT_TILE_ADDR_REG      8'h08
`define INPUT_TILE_MAT_W_REG     8'h09
`define OUTPUT_TILE_CFG_H_REG    8'h0A
`define OUTPUT_TILE_CFG_W_REG    8'h0B
`define OUTPUT_TILE_CFG_C_REG    8'h0C
`define OUTPUT_TILE_ADDR_REG     8'h0D
`define OUTPUT_TILE_MAT_W_REG    8'h0E
`define WEIGHT_CFG_N_REG         8'h0F
`define WEIGHT_CFG_H_REG         8'h10
`define WEIGHT_CFG_W_REG         8'h11
`define WEIGHT_CFG_C_REG         8'h12
`define WEIGHT_ADDR_REG          8'h13
`define STATUS_REG               8'h14

`define ERR_BIT                  0
`define COMP_DONE_BIT            1
`define LOAD_TILE_DONE_BIT       2
`define STORE_TILE_DONE_BIT      3
`define WEIGHT_LOAD_DONE_BIT     4
`define BANK_SWITCH_DONE_BIT     5

`define COMPUTE_CMD          3'b000
`define BANK_SWITCH_CMD      3'b001
`define LOAD_TILE_CMD        3'b010
`define STORE_TILE_CMD       3'b011
`define LOAD_WEIGHTS_CMD     3'b100

module mmio #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter DIM_WIDTH  = 10,
    parameter NUM_REGS   = 21
)(
    input       i_clk,
    input       i_resetn,

    input                        i_cpu_valid,
    input       [ADDR_WIDTH-1:0] i_cpu_addr,
    input       [DATA_WIDTH-1:0] i_cpu_wdata,
    input       [3:0]            i_cpu_wstrb,
    output                       o_cpu_ready,
    output      [DATA_WIDTH-1:0] o_cpu_rdata,

    input                        i_npu_compute_done,
    input                        i_npu_bank_switch_done,
    input                        i_npu_load_tile_done,
    input                        i_npu_store_tile_done,
    input                        i_npu_load_weights_done,

    output logic                 o_npu_compute_start,
    output logic                 o_npu_bank_switch_start,
    output logic                 o_npu_load_tile_start,
    output logic                 o_npu_store_tile_start,
    output logic                 o_npu_load_weights_start,

    // output [2:0]                 o_npu_cmd,
    output                       o_npu_stride,
    output                       o_npu_maxpool_en,
    output                       o_npu_relu_en,
    output [4:0]                 o_npu_scale_amt,
    output [1:0]                 o_npu_padding,
    output [DIM_WIDTH-1:0]       o_npu_comp_H,
    output [DIM_WIDTH-1:0]       o_npu_comp_W,
    output [DIM_WIDTH-1:0]       o_npu_comp_C,
    output [DIM_WIDTH-1:0]       o_npu_in_tile_H,
    output [DIM_WIDTH-1:0]       o_npu_in_tile_W,
    output [DIM_WIDTH-1:0]       o_npu_in_tile_C,
    output [ADDR_WIDTH-1:0]      o_npu_in_tile_addr,
    output [DIM_WIDTH-1:0]       o_npu_in_mat_W,
    output [DIM_WIDTH-1:0]       o_npu_out_tile_H,
    output [DIM_WIDTH-1:0]       o_npu_out_tile_W,
    output [DIM_WIDTH-1:0]       o_npu_out_tile_C,
    output [ADDR_WIDTH-1:0]      o_npu_out_tile_addr,
    output [DIM_WIDTH-1:0]       o_npu_out_mat_W,
    output [DIM_WIDTH-1:0]       o_npu_weight_N,
    output [DIM_WIDTH-1:0]       o_npu_weight_H,
    output [DIM_WIDTH-1:0]       o_npu_weight_W,
    output [DIM_WIDTH-1:0]       o_npu_weight_C,
    output [ADDR_WIDTH-1:0]      o_npu_weight_addr

);

    wire [7:0] mmio_addr;
    wire mmio_valid;
    reg [DATA_WIDTH-1:0] mmio_rdata;
    reg mmio_ready;

    reg [DATA_WIDTH-1:0] mmio_regs [NUM_REGS-1:0];

    assign mmio_addr = i_cpu_addr[9:2];
    assign mmio_valid = (mmio_addr <= `STATUS_REG);
    assign o_cpu_rdata = mmio_rdata;
    assign o_cpu_ready = mmio_ready;

    //assign o_npu_cmd            = mmio_regs[`COMMAND_REG][2:0];
    assign o_npu_stride         = mmio_regs[`COMP_CFG_REG][9];
    assign o_npu_padding        = mmio_regs[`COMP_CFG_REG][8:7];
    assign o_npu_maxpool_en     = mmio_regs[`COMP_CFG_REG][6];
    assign o_npu_relu_en        = mmio_regs[`COMP_CFG_REG][5];
    assign o_npu_scale_amt      = mmio_regs[`COMP_CFG_REG][4:0];
    assign o_npu_comp_H         = mmio_regs[`COMP_CFG_H_REG][9:0];
    assign o_npu_comp_W         = mmio_regs[`COMP_CFG_W_REG][9:0];
    assign o_npu_comp_C         = mmio_regs[`COMP_CFG_C_REG][9:0];
    assign o_npu_in_tile_H      = mmio_regs[`INPUT_TILE_CFG_H_REG][9:0];
    assign o_npu_in_tile_W      = mmio_regs[`INPUT_TILE_CFG_W_REG][9:0];
    assign o_npu_in_tile_C      = mmio_regs[`INPUT_TILE_CFG_C_REG][9:0];
    assign o_npu_in_tile_addr   = mmio_regs[`INPUT_TILE_ADDR_REG];
    assign o_npu_in_mat_W       = mmio_regs[`INPUT_TILE_MAT_W_REG][9:0];
    assign o_npu_out_tile_H     = mmio_regs[`OUTPUT_TILE_CFG_H_REG][9:0];
    assign o_npu_out_tile_W     = mmio_regs[`OUTPUT_TILE_CFG_W_REG][9:0];
    assign o_npu_out_tile_C     = mmio_regs[`OUTPUT_TILE_CFG_C_REG][9:0];
    assign o_npu_out_tile_addr  = mmio_regs[`OUTPUT_TILE_ADDR_REG];
    assign o_npu_out_mat_W      = mmio_regs[`OUTPUT_TILE_MAT_W_REG][9:0];
    assign o_npu_weight_N       = mmio_regs[`WEIGHT_CFG_N_REG][9:0];
    assign o_npu_weight_H       = mmio_regs[`WEIGHT_CFG_H_REG][9:0];
    assign o_npu_weight_W       = mmio_regs[`WEIGHT_CFG_W_REG][9:0];
    assign o_npu_weight_C       = mmio_regs[`WEIGHT_CFG_C_REG][9:0];
    assign o_npu_weight_addr    = mmio_regs[`WEIGHT_ADDR_REG];

    integer i;

    always_ff @(posedge i_clk or negedge i_resetn) begin
        if(!i_resetn) begin
            for (i = 0; i < NUM_REGS; i = i + 1) begin
                mmio_regs[i]    <= '0;
            end
            mmio_ready <= '0;
            mmio_rdata <= '0;
            
            // nanda added the 5 lines below
            o_npu_compute_start <= 0;
            o_npu_bank_switch_start <= 0;
            o_npu_load_tile_start <= 0;
            o_npu_store_tile_start <= 0;
            o_npu_load_weights_start <= 0;
        end else begin
            mmio_ready <= '0;
            mmio_rdata <= '0;
            o_npu_compute_start       <= '0;
            o_npu_load_tile_start     <= '0;
            o_npu_store_tile_start    <= '0;
            o_npu_bank_switch_start   <= '0;
            o_npu_load_weights_start  <= '0;
            if(i_cpu_valid && !mmio_ready) begin
                mmio_ready <= 1;
                // Only do stuff if the mmio address is valid
                if(mmio_valid) begin
                    // Remember not to allow writes to the status reg
                    if(|i_cpu_wstrb && (mmio_addr != `STATUS_REG)) begin
                        mmio_regs[mmio_addr] <=  i_cpu_wdata;
                    end else begin
                        mmio_rdata <= mmio_regs[mmio_addr];
                    end
                end
            end 

            // Set and reset logic for the status registers to avoid race conditions
            // Immediately clears relevant done flag upon a write
            // Pulses start signal for relevant operation
            if((i_cpu_valid && !mmio_ready) && (mmio_addr == `COMMAND_REG) && (|i_cpu_wstrb)) begin
                case (i_cpu_wdata[2:0])
                    `COMPUTE_CMD      : begin
                        mmio_regs[`STATUS_REG][`COMP_DONE_BIT] <= '0;
                        o_npu_compute_start <= 1;
                    end
                    `LOAD_TILE_CMD    : begin
                        mmio_regs[`STATUS_REG][`LOAD_TILE_DONE_BIT] <= '0;
                        o_npu_load_tile_start <= 1;
                    end
                    `STORE_TILE_CMD   : begin
                        mmio_regs[`STATUS_REG][`STORE_TILE_DONE_BIT] <= '0;
                        o_npu_store_tile_start <= 1;
                    end
                    `LOAD_WEIGHTS_CMD : begin
                         mmio_regs[`STATUS_REG][`WEIGHT_LOAD_DONE_BIT] <= '0;
                         o_npu_load_weights_start <= 1;
                    end
                    `BANK_SWITCH_CMD  : begin
                        mmio_regs[`STATUS_REG][`BANK_SWITCH_DONE_BIT] <= '0;
                        o_npu_bank_switch_start <= 1;
                    end
                    default           : mmio_regs[`STATUS_REG][`ERR_BIT] <= 1;
                endcase
            end else begin
                if(i_npu_compute_done) begin
                    mmio_regs[`STATUS_REG][`COMP_DONE_BIT] <= 1;
                end
                if(i_npu_load_tile_done) begin
                    mmio_regs[`STATUS_REG][`LOAD_TILE_DONE_BIT] <= 1;
                end
                if(i_npu_store_tile_done) begin
                    mmio_regs[`STATUS_REG][`STORE_TILE_DONE_BIT] <= 1;
                end
                if(i_npu_load_weights_done) begin
                    mmio_regs[`STATUS_REG][`WEIGHT_LOAD_DONE_BIT] <= 1;
                end
                if(i_npu_bank_switch_done) begin
                    mmio_regs[`STATUS_REG][`BANK_SWITCH_DONE_BIT] <= 1;
                end
            end

            
        end // if reset
    end // always

endmodule
