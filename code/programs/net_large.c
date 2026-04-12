#include "firmware.h"

// Struct updated to include explicit input/output memory addresses
typedef struct {
    uint32_t Hi;
    uint32_t Wi;
    uint32_t Ci;
    uint32_t Hf;
    uint32_t Wf;
    uint32_t Co;
    uint32_t Ho;
    uint32_t Wo;
    uint8_t scale;
    uint8_t stride;
    uint8_t padding;
    bool relu;
    bool maxpool;
    uint32_t out_tile_base; 
    uint32_t weight_addr;
    uint32_t in_addr;
    uint32_t out_addr;
} LayerConfig;

int main() {

    uint32_t status;

    print_str("Status is:");
    status = npu_get_status();
    print_hex(status, 2);
    print_str("\n");

    // Define the 5-Layer Network exactly matching the Python output
    // uint32_t num_layers = 5;
    uint32_t num_layers = 5;
    LayerConfig network[5] = {
        // Layer 1
        {128, 128, 8,  17, 17, 16,  112, 112, 6, 1, 0, true, false, 40, 
         0x21000000, 0x20000000, 0x2001c988},
        
        // Layer 2
        {112, 112, 16, 7,  7,  32,  53,  53,  5, 1, 0, true, true,  30, 
         0x21008000, 0x2001c988, 0x200487c8},
        
        // Layer 3
        {48,  48,  32, 6,  6,  64,  22,  22,  4, 2, 0, true, false, 10, 
         0x21017200, 0x200487c8, 0x2005a7c8},
        
        // Layer 4 (Entire 11x11 output fits safely inside a single tile)
        {22,  22,  64, 3,  3,  64,  10,  10,  3, 1, 0, true, true,  10, 
         0x21029200, 0x2005a7c8, 0x200620c8},
        
        // Layer 5 (Entire 8x8 output fits safely inside a single tile)
        {10,  10,  64, 3,  3,  192,  8,   8,   2, 1, 0, true, false, 8,  
         0x21032200, 0x200620c8, 0x200639c8}
    };

    print_str("Starting LGNet 5-Layer Pipeline!\n");

    for (uint32_t l = 4; l < num_layers; l++) {
        
        print_str("Executing Layer ");
        print_hex(l + 1, 1);
        print_str("\n");

        LayerConfig curr = network[l];

        uint32_t tiles_y = (curr.Ho + curr.out_tile_base - 1) / curr.out_tile_base;
        uint32_t tiles_x = (curr.Wo + curr.out_tile_base - 1) / curr.out_tile_base;
        uint32_t num_tiles = tiles_y * tiles_x;
        
        // MaxPool halves spatial resolution *after* the convolution.
        // We use this multiplier to calculate the correct pre-pool geometry.
        uint32_t pool_factor = curr.maxpool ? 2 : 1;

        print_str("Loadnetworking weights...\n");
        npu_load_weights(curr.Co, curr.Hf, curr.Wf, curr.Ci, curr.weight_addr);
        while(!npu_load_weights_done());

        // Run the NPU Pipeline
        for (uint32_t i = 0; i < num_tiles + 2; i++) {
            
            // 1. DMA: Load Tile (i)
            if (i < num_tiles) {
                uint32_t ty = i / tiles_x;
                uint32_t tx = i % tiles_x;
                
                uint32_t rem_y = curr.Ho - (ty * curr.out_tile_base);
                uint32_t rem_x = curr.Wo - (tx * curr.out_tile_base);
                uint32_t ho_tile = (rem_y < curr.out_tile_base) ? rem_y : curr.out_tile_base;
                uint32_t wo_tile = (rem_x < curr.out_tile_base) ? rem_x : curr.out_tile_base;
                
                // Scale target output up to pre-pool dimensions
                uint32_t conv_h = ho_tile * pool_factor;
                uint32_t conv_w = wo_tile * pool_factor;
                
                // Account for stride and filter size
                uint32_t hi_tile = (conv_h - 1) * curr.stride + curr.Hf;
                uint32_t wi_tile = (conv_w - 1) * curr.stride + curr.Wf;
                
                // Input coordinates
                uint32_t in_y = (ty * curr.out_tile_base * pool_factor) * curr.stride;
                uint32_t in_x = (tx * curr.out_tile_base * pool_factor) * curr.stride;
                
                uint32_t curr_load_addr = curr.in_addr + (in_y * curr.Wi * curr.Ci) + (in_x * curr.Ci);
                
                npu_load_tile(hi_tile, wi_tile, curr.Ci, curr_load_addr, curr.Wi);
                while(!npu_load_tile_done()); 
            }
            
            // 2. DMA: Store Tile (i - 2)
            if (i >= 2) {
                uint32_t prev2_i = i - 2;
                uint32_t ty = prev2_i / tiles_x;
                uint32_t tx = prev2_i % tiles_x;
                
                uint32_t rem_y = curr.Ho - (ty * curr.out_tile_base);
                uint32_t rem_x = curr.Wo - (tx * curr.out_tile_base);
                uint32_t ho_tile = (rem_y < curr.out_tile_base) ? rem_y : curr.out_tile_base;
                uint32_t wo_tile = (rem_x < curr.out_tile_base) ? rem_x : curr.out_tile_base;
                
                uint32_t out_y = ty * curr.out_tile_base;
                uint32_t out_x = tx * curr.out_tile_base;
                uint32_t curr_store_addr = curr.out_addr + (out_y * curr.Wo * curr.Co) + (out_x * curr.Co);
                
                npu_store_tile(ho_tile, wo_tile, curr.Co, curr_store_addr, curr.Wo);
                while(!npu_store_tile_done());
            }
            
            // 3. Sync: Wait for previous Compute (i - 1)
            if (i > 0 && i < num_tiles + 1) {
                while(!npu_compute_done());
            }
            
            // 4. Ping-Pong: Switch Banks
            if (i < num_tiles + 1) {
                npu_bank_switch();
                while(!npu_bank_switch_done());
            }

            // 5. NPU: Start Compute (i)
            if (i < num_tiles) {
                uint32_t ty = i / tiles_x;
                uint32_t tx = i % tiles_x;
                
                uint32_t rem_y = curr.Ho - (ty * curr.out_tile_base);
                uint32_t rem_x = curr.Wo - (tx * curr.out_tile_base);
                uint32_t ho_tile = (rem_y < curr.out_tile_base) ? rem_y : curr.out_tile_base;
                uint32_t wo_tile = (rem_x < curr.out_tile_base) ? rem_x : curr.out_tile_base;
                
                uint32_t conv_h = ho_tile * pool_factor;
                uint32_t conv_w = wo_tile * pool_factor;
                
                uint32_t hi_tile = (conv_h - 1) * curr.stride + curr.Hf;
                uint32_t wi_tile = (conv_w - 1) * curr.stride + curr.Wf;
                
                npu_compute(hi_tile, wi_tile, curr.Ci, curr.scale, curr.padding, curr.stride, curr.relu, curr.maxpool);
            }
        }
    }
    
    print_str("All Layers Complete!\n");
    print_str("Reg Vals!\n");
    npu_print_regs();

    return 0;
}