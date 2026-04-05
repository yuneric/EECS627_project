#include "firmware.h"


int main() {

    uint32_t status;

    print_str("Status is:");
    status = npu_get_status();
    print_hex(status, 2);
    print_str("\n");

    // Layer 1
    print_str("Layer 1!\n");
    print_str("Loading weights!\n");
    npu_load_weights(16, 3, 3, 8, 0x21000000);
    while(!npu_load_weights_done());

    print_str("Loading tile!\n");
    npu_load_tile(32, 32, 8, 0x20000000, 32);
    while(!npu_load_tile_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());
    
    print_str("Computing!\n");
    npu_compute(32, 32, 8, 4, 1, 1, true, true);
    while(!npu_compute_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());

    print_str("Storing tile!\n");
    npu_store_tile(16, 16, 16, 0x20002000, 16);
    while(!npu_store_tile_done());
    
    print_str("Reg Vals!\n");
    npu_print_regs();

    // Layer 2
    print_str("Layer 2!\n");
    print_str("Loading weights!\n");
    npu_load_weights(32, 3, 3, 16, 0x21000480);
    while(!npu_load_weights_done());

    print_str("Loading tile!\n");
    npu_load_tile(16, 16, 16, 0x20002000, 16);
    while(!npu_load_tile_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());
    
    print_str("Computing!\n");
    npu_compute(16, 16, 16, 3, 1, 1, true, false);
    while(!npu_compute_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());

    print_str("Storing tile!\n");
    npu_store_tile(16, 16, 32, 0x20003000, 16);
    while(!npu_store_tile_done());
    
    print_str("Reg Vals!\n");
    npu_print_regs();

    // Layer 3
    print_str("Layer 3!\n");
    print_str("Loading weights!\n");
    npu_load_weights(64, 2, 2, 32, 0x21001680);
    while(!npu_load_weights_done());

    print_str("Loading tile!\n");
    npu_load_tile(16, 16, 32, 0x20003000, 16);
    while(!npu_load_tile_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());
    
    print_str("Computing!\n");
    npu_compute(16, 16, 32, 2, 0, 2, true, false);
    while(!npu_compute_done());

    print_str("Switching banks!\n");
    npu_bank_switch();
    while(!npu_bank_switch_done());

    print_str("Storing tile!\n");
    npu_store_tile(8, 8, 64, 0x20005000, 8);
    while(!npu_store_tile_done());
    
    print_str("Reg Vals!\n");
    npu_print_regs();

}