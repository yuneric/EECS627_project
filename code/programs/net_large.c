// #include "firmware.h"

#include "firmware.h"
// #include <stdlib.h>

// Helper macros to print variables cleanly
#define PRINT_VAR(name_str, val) { print_str(name_str ": "); print_dec(val); print_str("\n"); }
#define PRINT_HEX_VAR(name_str, val) { print_str(name_str ": 0x"); print_hex(val, 8); print_str("\n"); }

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
    uint8_t clk_sel;
    print_str("Status is: 0x");
    status = npu_get_status();
    print_hex(status, 2);
    print_str("\n");

    // Define the 5-Layer Network exactly matching the Python output
    uint32_t num_layers = 5;
    PRINT_VAR("num_layers", num_layers);

    LayerConfig network[5] = {
        // Layer 1
        {110, 110, 8 ,  15, 15, 16 ,  96 , 96 , 6, 1, 0, true, false, 44,
         0x21000000, 0x20000000, 0x20017a20},
        // Layer 2
        {96 , 96 , 16,  9 , 9 , 32 ,  44 , 44 , 5, 1, 0, true, true , 18,
         0x21007080, 0x20017a20, 0x2003ba20},
        // Layer 3
        {44 , 44 , 32,  6 , 6 , 64 ,  20 , 20 , 4, 2, 0, true, false, 12,
         0x21011280, 0x2003ba20, 0x2004ac20},
        // Layer 4
        {20 , 20 , 64,  3 , 3 , 64 ,  10 , 10 , 3, 1, 1, true, true , 10,
         0x21023280, 0x2004ac20, 0x20051020},
        // Layer 5
        {10 , 10 , 64,  3 , 3 , 192,  8  , 8  , 2, 1, 0, true, false,  8,
         0x2102c280, 0x20051020, 0x20052920}
    };


    print_str("Starting LGNet 5-Layer Pipeline!\n");

    for (uint32_t l = 0; l < num_layers; l++) {
        
        if(l >= 2) {
            print_str("Performing some awesome work D: !!!!!\n");
            int x = 0;
            for(int i = 0; i < 30000; i += 1) {
                x += 1 + i;
            }
            print_str("Finished work :D !!!!!!\n");
        }
        print_str("Executing Layer ");
        print_dec(l + 1);
        print_str("\n");
        PRINT_VAR("l (loop index)", l);

        LayerConfig curr = network[l];
        
        // Print Current Layer Config
        print_str("--- curr Config ---\n");
        PRINT_VAR("curr.Hi", curr.Hi);
        PRINT_VAR("curr.Wi", curr.Wi);
        PRINT_VAR("curr.Ci", curr.Ci);
        PRINT_VAR("curr.Hf", curr.Hf);
        PRINT_VAR("curr.Wf", curr.Wf);
        PRINT_VAR("curr.Co", curr.Co);
        PRINT_VAR("curr.Ho", curr.Ho);
        PRINT_VAR("curr.Wo", curr.Wo);
        PRINT_VAR("curr.scale", curr.scale);
        PRINT_VAR("curr.stride", curr.stride);
        PRINT_VAR("curr.padding", curr.padding);
        PRINT_VAR("curr.relu", curr.relu);
        PRINT_VAR("curr.maxpool", curr.maxpool);
        PRINT_VAR("curr.out_tile_base", curr.out_tile_base);
        PRINT_HEX_VAR("curr.weight_addr", curr.weight_addr);
        PRINT_HEX_VAR("curr.in_addr", curr.in_addr);
        PRINT_HEX_VAR("curr.out_addr", curr.out_addr);
        print_str("-------------------\n");

        uint32_t tiles_y = (curr.Ho + curr.out_tile_base - 1) / curr.out_tile_base;
        PRINT_VAR("tiles_y", tiles_y);
        
        uint32_t tiles_x = (curr.Wo + curr.out_tile_base - 1) / curr.out_tile_base;
        PRINT_VAR("tiles_x", tiles_x);
        
        uint32_t num_tiles = tiles_y * tiles_x;
        PRINT_VAR("num_tiles", num_tiles);
        
        // MaxPool halves spatial resolution *after* the convolution.
        // We use this multiplier to calculate the correct pre-pool geometry.
        uint32_t pool_factor = curr.maxpool ? 2 : 1;
        PRINT_VAR("pool_factor", pool_factor);

        print_str("Loading weights...\n");
        npu_load_weights(curr.Co, curr.Hf, curr.Wf, curr.Ci, curr.weight_addr);
        while(!npu_load_weights_done());

        // Run the NPU Pipeline
        for (uint32_t i = 0; i < num_tiles + 2; i++) {
            
            print_str("\n--- Pipeline Iteration ---\n");
            PRINT_VAR("i (pipeline index)", i);
            print_str("Clock cfg: ");
            print_dec(5-l);
            print_str("\n");
            npu_clock_cfg(5-l);

            // 1. DMA: Load Tile (i)
            if (i < num_tiles) {
                print_str("[DMA Load Tile]\n");
                uint32_t ty = i / tiles_x;
                PRINT_VAR("load ty", ty);
                
                uint32_t tx = i % tiles_x;
                PRINT_VAR("load tx", tx);
                
                uint32_t rem_y = curr.Ho - (ty * curr.out_tile_base);
                PRINT_VAR("load rem_y", rem_y);
                
                uint32_t rem_x = curr.Wo - (tx * curr.out_tile_base);
                PRINT_VAR("load rem_x", rem_x);
                
                uint32_t ho_tile = (rem_y < curr.out_tile_base) ? rem_y : curr.out_tile_base;
                PRINT_VAR("load ho_tile", ho_tile);
                
                uint32_t wo_tile = (rem_x < curr.out_tile_base) ? rem_x : curr.out_tile_base;
                PRINT_VAR("load wo_tile", wo_tile);
                
                // Scale target output up to pre-pool dimensions
                uint32_t conv_h = ho_tile * pool_factor;
                PRINT_VAR("load conv_h", conv_h);
                
                uint32_t conv_w = wo_tile * pool_factor;
                PRINT_VAR("load conv_w", conv_w);
                
                // Account for stride and filter size
                uint32_t hi_tile = (conv_h - 1) * curr.stride + curr.Hf - 2 * curr.padding;
                PRINT_VAR("load hi_tile", hi_tile);
                
                uint32_t wi_tile = (conv_w - 1) * curr.stride + curr.Wf - 2 * curr.padding;
                PRINT_VAR("load wi_tile", wi_tile);
                
                // Input coordinates
                uint32_t in_y = (ty * curr.out_tile_base * pool_factor) * curr.stride;
                PRINT_VAR("load in_y", in_y);
                
                uint32_t in_x = (tx * curr.out_tile_base * pool_factor) * curr.stride;
                PRINT_VAR("load in_x", in_x);
                
                uint32_t curr_load_addr = curr.in_addr + (in_y * curr.Wi * curr.Ci) + (in_x * curr.Ci);
                PRINT_HEX_VAR("curr_load_addr", curr_load_addr);
                
                npu_load_tile(hi_tile, wi_tile, curr.Ci, curr_load_addr, curr.Wi);
                while(!npu_load_tile_done()); 
            }
            
            // 2. DMA: Store Tile (i - 2)
            if (i >= 2) {
                print_str("[DMA Store Tile]\n");
                uint32_t prev2_i = i - 2;
                PRINT_VAR("prev2_i", prev2_i);
                
                uint32_t ty = prev2_i / tiles_x;
                PRINT_VAR("store ty", ty);
                
                uint32_t tx = prev2_i % tiles_x;
                PRINT_VAR("store tx", tx);
                
                uint32_t rem_y = curr.Ho - (ty * curr.out_tile_base);
                PRINT_VAR("store rem_y", rem_y);
                
                uint32_t rem_x = curr.Wo - (tx * curr.out_tile_base);
                PRINT_VAR("store rem_x", rem_x);
                
                uint32_t ho_tile = (rem_y < curr.out_tile_base) ? rem_y : curr.out_tile_base;
                PRINT_VAR("store ho_tile", ho_tile);
                
                uint32_t wo_tile = (rem_x < curr.out_tile_base) ? rem_x : curr.out_tile_base;
                PRINT_VAR("store wo_tile", wo_tile);
                
                uint32_t out_y = ty * curr.out_tile_base;
                PRINT_VAR("store out_y", out_y);
                
                uint32_t out_x = tx * curr.out_tile_base;
                PRINT_VAR("store out_x", out_x);
                
                uint32_t curr_store_addr = curr.out_addr + (out_y * curr.Wo * curr.Co) + (out_x * curr.Co);
                PRINT_HEX_VAR("curr_store_addr", curr_store_addr);
                
                npu_store_tile(ho_tile, wo_tile, curr.Co, curr_store_addr, curr.Wo);
                while(!npu_store_tile_done());
            }
            
            // 3. Sync: Wait for previous Compute (i - 1)
            if (i > 0 && i < num_tiles + 1) {
                while(!npu_compute_done());
            }
            
            // 4. Ping-Pong: Switch Banks
            if (i < num_tiles + 1) {
                print_str("[NPU Bank Switch]\n");
                npu_bank_switch();
                while(!npu_bank_switch_done());
            }

            // 5. NPU: Start Compute (i)
            if (i < num_tiles) {
                print_str("[NPU Compute]\n");
                uint32_t ty = i / tiles_x;
                PRINT_VAR("compute ty", ty);
                
                uint32_t tx = i % tiles_x;
                PRINT_VAR("compute tx", tx);
                
                uint32_t rem_y = curr.Ho - (ty * curr.out_tile_base);
                PRINT_VAR("compute rem_y", rem_y);
                
                uint32_t rem_x = curr.Wo - (tx * curr.out_tile_base);
                PRINT_VAR("compute rem_x", rem_x);
                
                uint32_t ho_tile = (rem_y < curr.out_tile_base) ? rem_y : curr.out_tile_base;
                PRINT_VAR("compute ho_tile", ho_tile);
                
                uint32_t wo_tile = (rem_x < curr.out_tile_base) ? rem_x : curr.out_tile_base;
                PRINT_VAR("compute wo_tile", wo_tile);
                
                uint32_t conv_h = ho_tile * pool_factor;
                PRINT_VAR("compute conv_h", conv_h);
                
                uint32_t conv_w = wo_tile * pool_factor;
                PRINT_VAR("compute conv_w", conv_w);
                
                uint32_t hi_tile = (conv_h - 1) * curr.stride + curr.Hf - 2 * curr.padding;
                PRINT_VAR("compute hi_tile", hi_tile);
                
                uint32_t wi_tile = (conv_w - 1) * curr.stride + curr.Wf - 2 * curr.padding;
                PRINT_VAR("compute wi_tile", wi_tile);
                
                npu_compute(hi_tile, wi_tile, curr.Ci, curr.scale, curr.padding, curr.stride, curr.relu, curr.maxpool);
            }
        }
    }
    
    print_str("All Layers Complete!\n");
    print_str("Reg Vals!\n");
    npu_print_regs();

    return 0;
}
