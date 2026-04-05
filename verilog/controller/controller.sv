module controller #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter DIM_WIDTH  = 10
) (
    input       i_clk,
    input       i_resetn,

    input                         i_cpu_valid,
    input       [ADDR_WIDTH-1:0]  i_cpu_addr,
    input       [DATA_WIDTH-1:0]  i_cpu_wdata,
    input       [3:0]             i_cpu_wstrb,
    output                        o_cpu_ready,
    output      [DATA_WIDTH-1:0]  o_cpu_rdata,

    output logic                  o_comp_compute_start    ,
    output logic [1:0]            o_comp_stride           ,
    output logic [1:0]            o_comp_padding          ,
    output logic                  o_comp_maxpool_en       ,
    output logic                  o_comp_relu_en          ,
    output logic [4:0]            o_comp_scale_amt        ,
    output logic [DIM_WIDTH-1:0]  o_comp_Hi               ,
    output logic [DIM_WIDTH-1:0]  o_comp_Wi               ,
    output logic [DIM_WIDTH-1:0]  o_comp_Hf               ,
    output logic [DIM_WIDTH-1:0]  o_comp_Wf               ,
    output logic [DIM_WIDTH-1:0]  o_comp_Ho               ,
    output logic [DIM_WIDTH-1:0]  o_comp_Wo               ,
    output logic [DIM_WIDTH-1:0]  o_comp_words_per_channel,
    output logic [DIM_WIDTH-1:0]  o_comp_num_kernels      ,
    input                         i_comp_done             ,

    output logic                  o_sram_load_weights    ,
    output logic                  o_mmu_load_weights     ,
    output logic                  o_mmu_load_tile        ,
    output logic                  o_mmu_store_tile       ,
    output logic [DIM_WIDTH-1:0]  o_mmu_N                ,
    output logic [DIM_WIDTH-1:0]  o_mmu_H                ,
    output logic [DIM_WIDTH-1:0]  o_mmu_W                ,
    output logic [DIM_WIDTH-1:0]  o_mmu_words_per_channel,
    output logic [DIM_WIDTH-1:0]  o_mmu_tile_stride      ,
    output logic [ADDR_WIDTH-1:0] o_mmu_addr             ,
    input                         i_mmu_done             ,

    output logic                  o_bank_sel

);

    logic                       npu_stride         ;
    logic [1:0]                 npu_padding        ;
    logic                       npu_maxpool_en     ;
    logic                       npu_relu_en        ;
    logic [4:0]                 npu_scale_amt      ;
    logic [DIM_WIDTH-1:0]       npu_comp_H         ;
    logic [DIM_WIDTH-1:0]       npu_comp_W         ;
    logic [DIM_WIDTH-1:0]       npu_comp_C         ;
    logic [DIM_WIDTH-1:0]       npu_in_tile_H      ;
    logic [DIM_WIDTH-1:0]       npu_in_tile_W      ;
    logic [DIM_WIDTH-1:0]       npu_in_tile_C      ;
    logic [ADDR_WIDTH-1:0]      npu_in_tile_addr   ;
    logic [DIM_WIDTH-1:0]       npu_in_mat_W       ;
    logic [DIM_WIDTH-1:0]       npu_out_tile_H     ;
    logic [DIM_WIDTH-1:0]       npu_out_tile_W     ;
    logic [DIM_WIDTH-1:0]       npu_out_tile_C     ;
    logic [ADDR_WIDTH-1:0]      npu_out_tile_addr  ;
    logic [DIM_WIDTH-1:0]       npu_out_mat_W      ;
    logic [DIM_WIDTH-1:0]       npu_weight_N       ;
    logic [DIM_WIDTH-1:0]       npu_weight_H       ;
    logic [DIM_WIDTH-1:0]       npu_weight_W       ;
    logic [DIM_WIDTH-1:0]       npu_weight_C       ;
    logic [ADDR_WIDTH-1:0]      npu_weight_addr    ;

    logic compute_done;
    logic load_tile_done;
    logic store_tile_done;
    logic bank_switch_done;
    logic load_weights_done;

    logic compute_start;
    logic load_tile_start;
    logic store_tile_start;
    logic bank_switch_start;
    logic load_weights_start;

    // mmio regs
    mmio #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(32),
        .DIM_WIDTH(DIM_WIDTH),
        .NUM_REGS(21)
    ) mmio_dut (
        .i_clk  (i_clk),
        .i_resetn(i_resetn),

        .i_cpu_valid(i_cpu_valid),
        .i_cpu_addr (i_cpu_addr ),
        .i_cpu_wdata(i_cpu_wdata),
        .i_cpu_wstrb(i_cpu_wstrb),
        .o_cpu_ready(o_cpu_ready),
        .o_cpu_rdata(o_cpu_rdata),

        .i_npu_compute_done     (compute_done       ),
        .i_npu_bank_switch_done (bank_switch_done   ),
        .i_npu_load_tile_done   (load_tile_done     ),
        .i_npu_store_tile_done  (store_tile_done    ),
        .i_npu_load_weights_done(load_weights_done  ),

        .o_npu_compute_start        (compute_start      ),
        .o_npu_bank_switch_start    (bank_switch_start  ),
        .o_npu_load_tile_start      (load_tile_start    ),
        .o_npu_store_tile_start     (store_tile_start   ),
        .o_npu_load_weights_start   (load_weights_start ),

        .o_npu_stride       (npu_stride       ),
        .o_npu_padding      (npu_padding      ),
        .o_npu_maxpool_en   (npu_maxpool_en   ),
        .o_npu_relu_en      (npu_relu_en      ),
        .o_npu_scale_amt    (npu_scale_amt    ),
        .o_npu_comp_H       (npu_comp_H       ),
        .o_npu_comp_W       (npu_comp_W       ),
        .o_npu_comp_C       (npu_comp_C       ),
        .o_npu_in_tile_H    (npu_in_tile_H    ),
        .o_npu_in_tile_W    (npu_in_tile_W    ),
        .o_npu_in_tile_C    (npu_in_tile_C    ),
        .o_npu_in_tile_addr (npu_in_tile_addr ),
        .o_npu_in_mat_W     (npu_in_mat_W     ),
        .o_npu_out_tile_H   (npu_out_tile_H   ),
        .o_npu_out_tile_W   (npu_out_tile_W   ),
        .o_npu_out_tile_C   (npu_out_tile_C   ),
        .o_npu_out_tile_addr(npu_out_tile_addr),
        .o_npu_out_mat_W    (npu_out_mat_W    ),
        .o_npu_weight_N     (npu_weight_N     ),
        .o_npu_weight_H     (npu_weight_H     ),
        .o_npu_weight_W     (npu_weight_W     ),
        .o_npu_weight_C     (npu_weight_C     ),
        .o_npu_weight_addr  (npu_weight_addr  )
    );


    // banked sram fsm
    always_ff @(posedge i_clk or negedge i_resetn) begin
        if(!i_resetn) begin
            o_bank_sel       <= '0;
            bank_switch_done <= '0;
        end else begin
            bank_switch_done <= '0;
            if(bank_switch_start) begin
                bank_switch_done    <= 1;
                o_bank_sel          <= ~o_bank_sel;
            end
        end
    end // always

    // states
    typedef enum {MMU_IDLE, MMU_LOAD_TILE, MMU_STORE_TILE, MMU_LOAD_WEIGHTS} mmu_state_t;
    mmu_state_t mmu_state;

    typedef enum {COMP_IDLE, COMP_COMPUTE} comp_state_t;
    comp_state_t compute_state;

    // compute fsm
    wire [9:0] Ho;
    wire [9:0] Wo;

    assign Ho = ((npu_comp_H + (npu_padding << 1) - npu_weight_H) >> npu_stride) + 1;
    assign Wo = ((npu_comp_W + (npu_padding << 1) - npu_weight_W) >> npu_stride) + 1;

    always_ff @(posedge i_clk or negedge i_resetn) begin
        if(!i_resetn) begin
            compute_done             <= '0;
            compute_state            <= COMP_IDLE;
            o_comp_compute_start     <= '0;
            o_comp_stride            <= '0;
            o_comp_padding           <= '0;
            o_comp_maxpool_en        <= '0;
            o_comp_relu_en           <= '0;
            o_comp_scale_amt         <= '0;
            o_comp_Wi                <= '0;
            o_comp_Hi                <= '0;
            o_comp_Wf                <= '0;
            o_comp_Hf                <= '0;
            o_comp_Ho                <= '0;
            o_comp_Wo                <= '0;
            o_comp_words_per_channel <= '0;
            o_comp_num_kernels       <= '0;
        end else begin
            // Default Assignments
            compute_state             <= COMP_IDLE;
            compute_done              <= '0;
            o_comp_compute_start      <= '0;
            case(compute_state) 
                COMP_IDLE: begin
                    if(compute_start) begin
                        compute_state            <= COMP_COMPUTE;
                        o_comp_compute_start     <= 1;
                        o_comp_stride            <= npu_stride ? 2'd2 : 2'd1;
                        o_comp_padding           <= npu_padding;
                        o_comp_maxpool_en        <= npu_maxpool_en;
                        o_comp_relu_en           <= npu_relu_en;
                        o_comp_scale_amt         <= npu_scale_amt;
                        o_comp_Wi                <= npu_comp_W;
                        o_comp_Hi                <= npu_comp_H;
                        o_comp_Wf                <= npu_weight_W;
                        o_comp_Hf                <= npu_weight_H;
                        o_comp_Ho                <= Ho;
                        o_comp_Wo                <= Wo;
                        o_comp_words_per_channel <= ((npu_comp_C-1) >> 3) + 1; // int divide by 8
                        o_comp_num_kernels       <= npu_weight_N;
                    end else begin
                        o_comp_stride            <= '0;
                        o_comp_padding           <= '0;
                        o_comp_maxpool_en        <= '0;
                        o_comp_relu_en           <= '0;
                        o_comp_scale_amt         <= '0;
                        o_comp_Wi                <= '0;
                        o_comp_Hi                <= '0;
                        o_comp_Wf                <= '0;
                        o_comp_Hf                <= '0;
                        o_comp_Ho                <= '0;
                        o_comp_Wo                <= '0;
                        o_comp_words_per_channel <= '0;
                        o_comp_num_kernels       <= '0;
                    end
                end // COMP_IDLE

                COMP_COMPUTE : begin
                    if(i_comp_done) begin
                        compute_state <= COMP_IDLE;
                        compute_done  <= 1;
                    end else begin
                        compute_state <= COMP_COMPUTE;
                    end

                end // COMP_COMPUTE

                default : begin
                    compute_state     <= COMP_IDLE;
                end // DEFAULT

            endcase // comp_state
        end // reset
    end // always

    // mmu sm
    always_ff @(posedge i_clk or negedge i_resetn) begin
        if(!i_resetn) begin
            mmu_state   <= MMU_IDLE;
            load_tile_done      <= '0;
            store_tile_done     <= '0;
            load_weights_done   <= '0;
            o_mmu_load_tile         <= '0;
            o_mmu_store_tile        <= '0;
            o_mmu_load_weights      <= '0;
            o_sram_load_weights     <= '0;
            o_mmu_N                 <= '0;
            o_mmu_H                 <= '0;
            o_mmu_W                 <= '0;
            o_mmu_words_per_channel <= '0;
            o_mmu_tile_stride       <= '0;
            o_mmu_addr              <= '0;
        end else begin
            mmu_state             <= MMU_IDLE;
            load_tile_done        <= '0;
            store_tile_done       <= '0;
            load_weights_done     <= '0;
            // nanda added this one line below
            o_sram_load_weights   <= '0;
            o_mmu_load_tile       <= '0;
            o_mmu_store_tile      <= '0;
            o_mmu_load_weights    <= '0;
            case(mmu_state) 
                MMU_IDLE: begin
                    if(load_tile_start) begin
                        mmu_state              <= MMU_LOAD_TILE;
                        o_mmu_load_tile         <= 1;
                        o_mmu_N                 <= '0;
                        o_mmu_H                 <= npu_in_tile_H;
                        o_mmu_W                 <= npu_in_tile_W;
                        o_mmu_words_per_channel <= ((npu_in_tile_C-1) >> 3) + 1; // int divide by 8;
                        o_mmu_tile_stride       <= npu_in_mat_W;
                        o_mmu_addr              <= npu_in_tile_addr;
                    end else if (store_tile_start) begin
                        mmu_state              <= MMU_STORE_TILE;
                        o_mmu_store_tile        <= 1;
                        o_mmu_N                 <= '0;
                        o_mmu_H                 <= npu_out_tile_H;
                        o_mmu_W                 <= npu_out_tile_W;
                        o_mmu_words_per_channel <= ((npu_out_tile_C-1) >> 3) + 1; // int divide by 8;
                        o_mmu_tile_stride       <= npu_out_mat_W;
                        o_mmu_addr              <= npu_out_tile_addr;
                    end else if (load_weights_start) begin
                        mmu_state               <= MMU_LOAD_WEIGHTS;
                        o_sram_load_weights     <= 1;
                        o_mmu_load_weights      <= 1;
                        o_mmu_N                 <= npu_weight_N;
                        o_mmu_H                 <= npu_weight_H;
                        o_mmu_W                 <= npu_weight_W;
                        o_mmu_words_per_channel <= ((npu_weight_C-1) >> 3) + 1; // int divide by 8;
                        o_mmu_tile_stride       <= '0;
                        o_mmu_addr              <= npu_weight_addr;
                    end else begin
                        mmu_state <= MMU_IDLE;
                        o_mmu_N                 <= '0;
                        o_mmu_H                 <= '0;
                        o_mmu_W                 <= '0;
                        o_mmu_words_per_channel <= '0;
                        o_mmu_tile_stride       <= '0;
                        o_mmu_addr              <= '0;
                    end
                end // MMU_IDLE

                MMU_LOAD_TILE : begin
                    if(i_mmu_done) begin
                        mmu_state <= MMU_IDLE;
                        load_tile_done <= 1;
                    end else begin
                        mmu_state <= MMU_LOAD_TILE;
                    end
                end // MMU_LOAD_TILE

                MMU_STORE_TILE : begin
                    if(i_mmu_done) begin
                        mmu_state <= MMU_IDLE;
                        store_tile_done <= 1;
                    end else begin
                        mmu_state <= MMU_STORE_TILE;
                    end
                end // MMU_STORE_TILE

                MMU_LOAD_WEIGHTS : begin
                    if(i_mmu_done) begin
                        mmu_state <= MMU_IDLE;
                        load_weights_done <= 1;
                        o_sram_load_weights <= 0;
                    end else begin
                        o_sram_load_weights <= 1;
                        mmu_state <= MMU_LOAD_WEIGHTS;
                    end
                end // MMU_LOAD_WEIGHTS

                default : begin
                    mmu_state  <= MMU_IDLE;
                end // DEFAULT
            endcase // comp_state
        end // reset
    end // always

    `ifdef PROFILE
        int compute_counter;
        int load_counter;
        int store_counter;
        int weight_counter;

        initial begin
            compute_counter = 0;
            load_counter = 0;
            store_counter = 0;
            weight_counter = 0;
        end

        always @(posedge i_clk) begin
            if(mmu_state == MMU_LOAD_TILE) load_counter += 1;
            if(mmu_state == MMU_STORE_TILE) store_counter += 1;
            if(mmu_state == MMU_LOAD_WEIGHTS) weight_counter += 1;
            if(compute_state == COMP_COMPUTE) compute_counter += 1;
            if(i_comp_done) begin
                $display("compute cycles: %d", compute_counter);
                compute_counter = 0;
            end
            if(i_mmu_done && mmu_state == MMU_LOAD_TILE) begin
                $display("load tile cycles: %d", load_counter);
                load_counter = 0;
            end
            if(i_mmu_done && mmu_state == MMU_STORE_TILE) begin
                $display("store tile cycles: %d", store_counter);
                store_counter = 0;
            end
            if(i_mmu_done && mmu_state == MMU_LOAD_WEIGHTS) begin
                $display("load weight cycles: %d", weight_counter);
                weight_counter = 0;
            end
        end
    `endif



endmodule