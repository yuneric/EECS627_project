#include "firmware.h"

int main() {

    uint32_t status;

    print_str("Status is:");
    status = npu_get_status();
    print_hex(status, 2);
    print_str("\n");

    // Network & Tile Definitions for Layer 1
    uint32_t Hi = 128;
    uint32_t Wi = 128;
    uint32_t Hi_tile = 64;
    uint32_t Wi_tile = 64;
    uint32_t Ci = 8;
    
    uint32_t Hf = 17;
    uint32_t Wf = 17;
    uint32_t Co = 16;
    
    // Derived outputs 
    uint32_t Ho_tile = 57; 
    uint32_t Wo_tile = 57; 
    uint32_t Wo = 114;     

    uint8_t scale = 6;
    uint8_t stride = 1;
    uint8_t padding = 1;
    bool relu = true;
    bool maxpool = false;

    // Grid coordinates
    uint32_t tiles_y = Hi / Hi_tile;
    uint32_t tiles_x = Wi / Wi_tile;
    uint32_t num_tiles = tiles_y * tiles_x;

    uint32_t base_load_addr   = 0x20000000;
    uint32_t base_store_addr  = 0x20020000;
    uint32_t weight_addr      = 0x21000000;

    /////////////
    // Layer 1 //
    /////////////
    print_str("Layer 1!\n");

    print_str("Loading weights!\n");
    npu_load_weights(Co, Hf, Wf, Ci, weight_addr);
    while(!npu_load_weights_done());

    print_str("Starting Pipelined Execution!\n");
    
    // Run loop num_tiles + 2 times to fill and drain the pipeline completely
    for (uint32_t i = 0; i < num_tiles + 2; i++) {
        
        // 1. DMA: Load Tile (i)
        // Happens entirely in the background NPU bank
        if (i < num_tiles) {
            uint32_t ty = i / tiles_x;
            uint32_t tx = i % tiles_x;
            uint32_t curr_load_addr = base_load_addr + (ty * Wi * Ci * Hi_tile) + (tx * Wi_tile * Ci);
            
            npu_load_tile(Hi_tile, Wi_tile, Ci, curr_load_addr, Wi);
            while(!npu_load_tile_done()); 
        }
        
        // 2. DMA: Store Tile (i - 2)
        // Also happens in the background bank, grabbing the results from two cycles ago
        if (i >= 2) {
            uint32_t prev2_i = i - 2;
            uint32_t ty = prev2_i / tiles_x;
            uint32_t tx = prev2_i % tiles_x;
            uint32_t curr_store_addr = base_store_addr + (ty * Wo * Co * Ho_tile) + (tx * Wo_tile * Co);
            
            npu_store_tile(Ho_tile, Wo_tile, Co, curr_store_addr, Wo);
            while(!npu_store_tile_done());
        }
        
        // 3. Sync: Wait for previous Compute (i - 1)
        // Ensure the NPU is finished with its math before we pull the rug out
        if (i > 0 && i < num_tiles + 1) {
            while(!npu_compute_done());
        }
        
        // 4. Ping-Pong: Switch Banks
        // Swaps the buffers:
        // - Brings the tile we just loaded (Step 1) into the active NPU compute memory
        // - Pushes the results we just waited for (Step 3) into the background memory to be stored next loop
        if (i < num_tiles + 1) {
            npu_bank_switch();
            while(!npu_bank_switch_done());
        }

        // 5. NPU: Start Compute (i)
        // Starts grinding on the newly exposed bank. Runs async while the loop restarts!
        if (i < num_tiles) {
            npu_compute(Hi_tile, Wi_tile, Ci, scale, padding, stride, relu, maxpool);
        }
    }
    
    print_str("Reg Vals!\n");
    npu_print_regs();

    return 0;
}