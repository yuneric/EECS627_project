#include "firmware.h"

#define CFG_MEM_BASE_ADDR 0x10002000

struct cfg_mem {
    uint32_t HI;
    uint32_t WI;
    uint32_t HF;
    uint32_t WF;
    uint32_t HO;
    uint32_t WO;
    uint32_t CI;
    uint32_t NUM_KERNELS;
    uint32_t WORDS_NEEDED_FOR_CI ;
    uint32_t WORDS_NEEDED_FOR_CO;
    uint32_t STRIDE;
    uint32_t PADDING;
    uint32_t MAXPOOL_EN;
    uint32_t RELU_EN ;
    uint32_t SCALE_AMT;
    uint32_t ACT_START_ADDR;
    uint32_t ACT_END_ADDR;
    uint32_t WT_START_ADDR;
    uint32_t WT_END_ADDR;
    uint32_t OUTPUT_START_ADDR;
    uint32_t OUTPUT_END_ADDR;
};

int main() {
    // print_str("Writing reset command!\n");
    // npu_reset();
    volatile struct cfg_mem * cfg_mem_ptr;
    cfg_mem_ptr = CFG_MEM_BASE_ADDR;
    uint32_t status;

    print_str("Switching banks!\n");
    npu_bank_switch();

    print_str("Status is:");
    status = npu_get_status();
    print_hex(status, 2);
    print_str("\n");

    print_str("Loading tile!\n");
    npu_load_tile(cfg_mem_ptr->HI, cfg_mem_ptr->WI, cfg_mem_ptr->CI, cfg_mem_ptr->ACT_START_ADDR, cfg_mem_ptr->WI);
    while(!npu_load_tile_done());
    
    print_str("Loading weights!\n");
    npu_load_weights(cfg_mem_ptr->NUM_KERNELS, cfg_mem_ptr->HF, cfg_mem_ptr->WF, cfg_mem_ptr->CI, cfg_mem_ptr->WT_START_ADDR);
    while(!npu_load_weights_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());
    
    print_str("Computing!\n");
    npu_clock_cfg(0);
    npu_compute(cfg_mem_ptr->HI, cfg_mem_ptr->WI,  cfg_mem_ptr->CI,  cfg_mem_ptr->SCALE_AMT, cfg_mem_ptr->PADDING, cfg_mem_ptr->STRIDE, cfg_mem_ptr->RELU_EN, cfg_mem_ptr->MAXPOOL_EN);
    while(!npu_compute_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());

    print_str("Storing tile!\n");
    npu_store_tile(cfg_mem_ptr->HO, cfg_mem_ptr->WO, cfg_mem_ptr->NUM_KERNELS, cfg_mem_ptr->OUTPUT_START_ADDR, cfg_mem_ptr->WO);
    while(!npu_store_tile_done());
    
    print_str("Reg Vals!\n");
    npu_print_regs();

}