#include "firmware.h"

int main() {
    // print_str("Writing reset command!\n");
    // npu_reset();

    uint32_t N;
    uint32_t H;
    uint32_t W;
    uint32_t C;
    uint32_t addr;
    uint32_t mat_W;
    uint8_t scale_amt;
    uint8_t padding;
    uint8_t stride;
    bool relu_en;
    bool maxpool_en;
    uint32_t status;

    print_str("Switching banks!\n");
    npu_bank_switch();

    print_str("Status is:");
    status = npu_get_status();
    print_hex(status, 2);
    print_str("\n");

    print_str("Loading tile!\n");
    H = 4;
    W = 4;
    C = 3;
    addr = CNN_MEM_BASE_ADDR;
    mat_W = W;
    npu_load_tile(H,W,C, addr, mat_W);
    while(!npu_load_tile_done());
    
    print_str("Loading weights!\n");
    N = 3;
    H = 2;
    W = 2;
    C = 3;
    addr = CNN_MEM_BASE_ADDR + 0x80;
    npu_load_weights(N, H, W, C, addr);
    while(!npu_load_weights_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());
    
    print_str("Computing!\n");
    H = 4;
    W = 4;
    C = 3;
    scale_amt = 0;
    padding = 0;
    stride  = 1; // Want a stride of 1
    relu_en = false;
    maxpool_en = false;
    npu_compute(H, W, C, scale_amt, padding, stride, relu_en, maxpool_en);
    while(!npu_compute_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());

    print_str("Storing tile!\n");
    H = 4;
    W = 4;
    C = N;
    mat_W = 4;
    addr = CNN_MEM_BASE_ADDR + 0x100;
    npu_store_tile(H, W, C, addr, mat_W);
    while(!npu_store_tile_done());

    print_str("Reg Vals!\n");
    npu_print_regs();

}