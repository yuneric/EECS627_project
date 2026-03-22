import numpy as np
import argparse
import sys
import os
import copy
import math
import random

# Add the common script to our path so we can get some epic func's
script_dir = os.path.dirname(__file__) 
scripts_path = os.path.join(script_dir, '../common') 
sys.path.append(scripts_path) 

from matgen import *

from systolic_array_block_be import systolic_array_backend
from systolic_array_block_fe import systolic_array_frontend

# Global constants
dim = 8
num_arrays = 8
#num_arrays = 8
word_size = 8
bit_size = 8
main_mem_depth = 4096 #32kB each
#main mem depth by word size
main_mem_size = main_mem_depth * word_size
weight_mem_depth = 2048 #16kB each
weight_mem_size = weight_mem_depth * word_size

def run_im2col_gen(activations, weights, options):

    # Get our dimensions
    Hi, Wi, Ci = activations.shape
    Co, Hf, Wf, Ci = weights.shape
    stride = options.stride
    padding = options.padding

    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)

    print(f'Input shape: Hi: {Hi} Wi: {Wi} Ci: {Ci}')
    print(f'Kernel shape: Hf: {Hf} Wf: {Wf} Ci: {Ci} Co: {Co}')
    print(f'Output shape: Ho: {Ho} Wo: {Wo} Co: {Co}')
    print(f'Stride: {stride} Padding: {padding}')

    # Need to account for the fact that we are zero padding channels
    words_needed_for_Ci = math.ceil(Ci/word_size)
    num_words_for_output_channels = math.ceil(Co/word_size)
    # if options.verbose:
    #     print(f"words needed for channels: {words_needed_for_Ci} ")
    print(f"words needed for channels: {words_needed_for_Ci} ")

    # Calculate our mem sizes
    # if options.verbose:
    #     print(f'main mem size for inputs/outputs: {main_mem_size//1024} kB')
    #     print(f'weight mem size for weights: {weight_mem_size//1024} kB')
    print(f'main mem size for inputs/outputs: {main_mem_size//1024} kB')
    print(f'weight mem size for weights: {weight_mem_size//1024} kB')
    print(f'weight mem size for weights total: {8*weight_mem_size//1024} kB')

    # Determine how much space our inputs, weights, and outputs take up
    activation_size = Hi * Wi * words_needed_for_Ci * word_size
    kernel_size_single =  Hf * Wf * words_needed_for_Ci * word_size
    num_rows_per_kernel = Hf * Wf * words_needed_for_Ci
    kernels_size = kernel_size_single * Co # We can operate on 8 kernels at a time
    output_size = Wo * Ho * num_words_for_output_channels * word_size
    # if options.verbose:
    print(f"activation size: {activation_size//1024} kB")
    print(f"kernels size: {kernels_size//1024} kB")
    print(f"output size: {output_size//1024} kB")

    if(main_mem_size < activation_size):
        print("ERROR: activations too big")
        exit(1)

    if(main_mem_size < output_size):
        print("ERROR: outputs too big")
        exit(1)

    if(8*weight_mem_size < kernels_size):
        print("ERROR: kernels too big")
        exit(1)

    if options.debug:
        activations = debug_mat_gen_HWC(Hi, Wi, Ci)
        weights = debug_mat_gen_NHWC(Hf, Wf, Ci, Co)

    if options.debug:
        print("Input activations:")
        print_HWC(activations)
        print("Single weight kernel")
        print_HWC(weights[0])
    # Make mem model
    main_mem = make_memory_model(activations, word_size)
    weight_mem = make_memory_model(weights, word_size)

    # Do the tiling
    # We calculate 8 channels at a time using our systolic arrays (1 kernel/channel per col)
    # We calculate 8 pixels of the output at a time (8 rows)
    # To do maxpooling, we need 2 2x2 squares, 
    # Lets assume the systolic array does a 2x4 square of the output for each tile
    # (THIS MEANS EVEN IF YOUR OUTPUT IS 2X2, IT WILL BE FORMATTED AS A 2X4 MATRIX IN MEMORY)
    tiles_in_width = math.ceil(Wo/4) # how many tiles are in the output width-wise
    tiles_in_height = math.ceil(Ho/2) # how many tiles are in the output height-wise
    kernel_groups = math.ceil(Co/(dim*num_arrays)) # how many kernel groups we have to iterate through
    num_tiles = tiles_in_width * tiles_in_height
    top_left_pixel_x = 0
    top_left_pixel_y = 0
    # Lowered ifmap dimensions
    lowered_act_rows = Wo * Ho
    lowered_act_cols = Wf * Hf * words_needed_for_Ci
    print(f"Kernel groups: {kernel_groups}") 
    print(f"Num tiles in output: {num_tiles}") 
    # The tiled lowered act matrix is dim rows by however many cols the lowered act matrix
    # The tiled lowered weight matrix is dim cols with however many rows the lowered weight matrix
    if options.debug:
        lowered_act = np.empty((kernel_groups, num_tiles, dim, Wf*Hf*words_needed_for_Ci, word_size), dtype='<U10')
        lowered_weight = np.empty((num_arrays, kernel_groups, num_tiles, Wf*Hf*words_needed_for_Ci, dim, word_size), dtype='<U10')
    else:
        lowered_act = np.zeros((kernel_groups, num_tiles, dim, Wf*Hf*words_needed_for_Ci, word_size))
        lowered_weight = np.zeros((num_arrays, kernel_groups, num_tiles, Wf*Hf*words_needed_for_Ci, dim, word_size))

    lowered_act_col = 0
    lowered_weight_row = 0
    kernels_processed = 0
    kernels_left = Co

    if options.im2col_test:
        im2col_test_file = open('im2col_test.txt', 'w')

    # Loop for each group of 64 kernels
    for kernel_group in range(kernel_groups):


        # This tiling goes through each output tile and generates, in order, the data to be fed to the 
        # left side of the systolic array (activations), and the data to be fed to the top side (weights)
        # The important part is the address generation, which we can use in our tb to verify correctness
        for tile_v in range(tiles_in_height):
            for tile_h in range(tiles_in_width):
                
                tile_idx = (tile_v * tiles_in_width) + tile_h

                # Determine the top left pixel coordinate of this tile in the output
                top_left_output_pixel_x = tile_h*4
                top_left_output_pixel_y = tile_v*2
                # and use that to calculate the top left pixel of the input
                top_left_input_pixel_x = top_left_output_pixel_x * stride
                top_left_input_pixel_y = top_left_output_pixel_y * stride
                if options.debug:
                    print(f'top_left_output_pixel_y: {top_left_output_pixel_y}')
                    print(f'top_left_output_pixel_x: {top_left_output_pixel_x}')
                    print(f'top_left_input_pixel_y: {top_left_input_pixel_y}')
                    print(f'top_left_input_pixel_x: {top_left_input_pixel_x}')
                # Determine how many output pixels are actually in the output on this tile on this iteration
                x_bound = min(Wo - top_left_output_pixel_x - 1, 3)
                y_bound = min(Ho - top_left_output_pixel_y - 1, 1)
                if options.debug:
                    print(f'y_bound: {y_bound}')
                    print(f'x_bound: {x_bound}')

                if options.im2col_test:
                    total = words_needed_for_Ci * Hf * Wf * dim
                    cnt = 0
                    kernels_in_group = 64 if (Co - kernels_processed >= 64) else (Co - kernels_processed)
                    #print(kernels_in_group)
                    array_wts_valid = [0] * num_arrays
                    for kernel in range(kernels_in_group):
                        array_wts_valid[kernel//8] += 1
                    # im2col_test_file.write(f'kernels_processed: {kernels_processed}\n')
                    # im2col_test_file.write(f'kgroup: {kernel_group}\n')
                    im2col_test_file.write(f'cfg_tile_H: {Hi:03x} cfg_tile_W: {Wi:03x} cfg_Hf: {Hf:03x} cfg_Wf: {Wf:03x} ' 
                                           f'cfg_stride: {stride:02b} cfg_padding: {padding:02b} cfg_words_ci: {words_needed_for_Ci:03x} '
                                           f'cfg_curr_kernel_group: {kernel_group:03x} cfg_num_kernels_per_group: {kernels_in_group:03x} '
                                           f'cfg_sub_tile_x: {tile_h:03x} cfg_sub_tile_y: {tile_v:03x} cfg_x_bound: {x_bound:02b} cfg_y_bound: {y_bound:01b} '
                                           f'total: {total:d}\n')


                # Need to get all the data words for each channel
                for word_idx in range(words_needed_for_Ci):
                    # Iterate through the pixels in a patch
                    for weight_pixel_y in range(Hf):
                        for  weight_pixel_x in range(Wf):
                            output_pixel_x = 0
                            output_pixel_y = 0
                            # Iterate over a single pixel from each patch
                            #print(f'Weight pixel: {weight_pixel_y},{weight_pixel_x}')
                            for row in range(dim):
                                input_pixel_x = top_left_input_pixel_x + weight_pixel_x + output_pixel_x * stride - padding
                                input_pixel_y = top_left_input_pixel_y + weight_pixel_y + output_pixel_y * stride - padding

                                # 1. Is the output pixel valid for this tile?
                                valid_out = not (output_pixel_x > x_bound or output_pixel_y > y_bound)
                                
                                # 2. Check if the input/output pixel is within the image (for padding)
                                valid_in = (0 <= input_pixel_x < Wi) and (0 <= input_pixel_y < Hi)

                                # Get the new chunk of activation data
                                mem_address = (input_pixel_x + input_pixel_y*Wi) * words_needed_for_Ci + word_idx
                                if(valid_out and valid_in):
                                    # If valid, get the data
                                    #print(f'Output Pixel: {output_pixel_y},{output_pixel_x}')
                                    #print(f'Input pixel: {input_pixel_y},{input_pixel_x} word_idx: {word_idx}')
                                
                                    new_data = main_mem[mem_address]
                                    
                                else:
                                    # If invalid, give substitute zeros
                                    #print(f'OofB pixel: {input_pixel_y},{input_pixel_x}')
                                    new_data = np.zeros(word_size)

                                # Load into our lowered activation matrix for later, fill in the row for each colum
                                lowered_act[kernel_group][tile_idx][row][lowered_act_col] = new_data 

                                # Update output pixel
                                output_pixel_x += 1
                                if(output_pixel_x > 3):
                                    output_pixel_x = 0
                                    output_pixel_y += 1

                                # Now do the weights
                                for array in range(num_arrays):
                                    kernel_num = row + (dim * array) + (dim * num_arrays) * kernel_group
                                    valid_weight = kernel_num < Co
                                    weight_mem_address = ((weight_pixel_x + weight_pixel_y*Wf) * words_needed_for_Ci) + word_idx + (kernel_num * num_rows_per_kernel)
                                    
                                    # Check if the valid kernel and get the chunk of weights
                                    if valid_weight:
                                        new_weights = weight_mem[weight_mem_address]
                                    else:
                                        new_weights = np.zeros(word_size)

                                    # Load into our lowered weight matrix for later
                                    col = row
                                    lowered_weight[array][kernel_group][tile_idx][lowered_weight_row][col] = new_weights

                                if options.im2col_test:
                                    # [act_mem_address] [valid_out] [weight_mem_address] [valid_weight_bits] [data last bit]
                                    array_enable = [0] * 8
                                    for array in range(num_arrays):
                                        array_enable[array] = array_wts_valid[array] > row
                                    cnt += 1
                                    kernel_num = row + (dim) * kernel_group
                                    weight_mem_address = ((weight_pixel_x + weight_pixel_y*Wf) * words_needed_for_Ci) + word_idx + (kernel_num * num_rows_per_kernel)
                                    im2col_test_file.write(f'{mem_address:03x} {(valid_out and valid_in):d} {weight_mem_address:03x} ' 
                                        f'{array_enable[7]:d}{array_enable[6]:d}{array_enable[5]:d}{array_enable[4]:d}' 
                                        f'{array_enable[3]:d}{array_enable[2]:d}{array_enable[1]:d}{array_enable[0]:d} ' 
                                        f'{(cnt == total):d}\n')

                                # row in dim
                            lowered_act_col += 1
                            lowered_weight_row += 1
                            # weight pixel x
                        # weight pixel y
                    # word_idx
                lowered_act_col = 0
                lowered_weight_row = 0
                if options.dump_addr:
                    _f.close()
            # tile_h
        # tile_v
        # For this kernel group determine how many arrays should be turned on
        for array in range(num_arrays):
            if(kernels_processed+8 < Co):
                kernels_processed += dim
            else:
                kernels_processed == Co
    # kernel group
    if options.debug:
        for kernel_group in range(kernel_groups):
            for tile in range(num_tiles):
                print(f'Lowered Ifmap for Tile: {tile} Kernel Group: {kernel_group}')
                for row in range(lowered_act.shape[2]):
                    for col in range(lowered_act.shape[3]):
                        for data in range(word_size):
                            # print(tile, kernel_group, row, col, data)
                            print(f'{lowered_act[kernel_group][tile][row][col][data]:>5}', end=' ')
                    print('')
                print(f'Lowered Weights for Tile: {tile} Kernel Group: {kernel_group} for systolic array 0')
                for row in range(lowered_weight.shape[3]):
                    for data in range(word_size):
                        for col in range(lowered_weight.shape[4]):
                            # print(tile, kernel_group, row, col, data)
                            print(f'{lowered_weight[0][kernel_group][tile][row][col][data]:>5}', end=' ')
                        print('')

    return lowered_act, lowered_weight

def run_test(activations, weights, options):
    # DO THE IM2COL_GEN
    # lowered_weight now has shape [num_arrays, kernel_groups, tile_num, rows, cols, word_size]
    lowered_act, lowered_weight = run_im2col_gen(activations, weights, options)
    
    # this part had a bit of gemini help to speed up its development, thanks gemini
    if not options.debug:
        # 1. GET THE GOLDEN NUMPY OFMAP FIRST
        # Doing this first so we can use its shape to build our empty reconstructed matrix
        correct_ofmap = do_cnn_layer(activations, weights, options.stride, options.padding)
        correct_ofmap = pad_channels_to_word_size(correct_ofmap, word_size)
        # make the matrices a multiple of our 2x4 systolic array output
        correct_ofmap = pad_channels_to_word_size(correct_ofmap, 2, 0) # pad the rows
        correct_ofmap = pad_channels_to_word_size(correct_ofmap, 4, 1) # pad the cols
        
        # Apply backend processing to the golden model
        if options.relu: correct_ofmap = relu(correct_ofmap)
        correct_ofmap = scale_clip_real(correct_ofmap, options.scale)
        if options.maxpool: correct_ofmap = maxpool_real(correct_ofmap)

        if options.verbose:
            print("NUMPY OFMAP")
            print_HWC(correct_ofmap)
            
        # 2. PREP THE LOWERED MATRICES FOR MATMULT
        num_kernel_groups = lowered_act.shape[0]
        num_tiles = lowered_act.shape[1]
        
        # Flatten acts to (KG, Tiles, 8, L)
        lowered_act_mats = lowered_act.reshape(num_kernel_groups, num_tiles, dim, -1)

        # Transpose weights to (Arrays, KG, Tiles, L, word_size, dim) so we can flatten L and word_size
        lowered_weight = np.transpose(lowered_weight, (0, 1, 2, 3, 5, 4))
        # Flatten weights to (Arrays, KG, Tiles, L, 8)
        lowered_weight_mats = lowered_weight.reshape(num_arrays, num_kernel_groups, num_tiles, -1, dim)

        # 3. RECONSTRUCT THE HARDWARE OUTPUT
        # Create an empty matrix identical to our expected golden output shape
        reconstructed_ofmap = np.zeros_like(correct_ofmap)
        
        # We need the unpooled width to calculate tile X/Y coordinates accurately
        unpooled_W = correct_ofmap.shape[1] * (2 if options.maxpool else 1)
        tiles_in_width = math.ceil(unpooled_W / 4)

        # Simulate all arrays!
        for array in range(num_arrays):
            for kernel_group in range(num_kernel_groups):
                for tile in range(num_tiles):
                    
                    # Core MatMult for this specific array, group, and tile
                    simulated = np.matmul(lowered_act_mats[kernel_group][tile], lowered_weight_mats[array][kernel_group][tile])
                    
                    # Pass through backend
                    if options.relu: simulated = relu(simulated)
                    simulated = scale_clip_sim(simulated, options.scale)
                    if options.maxpool: simulated = maxpool_sim(simulated)
                    
                    # Format output dimensions based on maxpool
                    if options.maxpool:
                        tile_out = simulated.reshape(1, 2, word_size)
                        tile_h, tile_w = 1, 2
                    else:
                        tile_out = simulated.reshape(2, 4, word_size)
                        tile_h, tile_w = 2, 4
                        
                    # Calculate spatial coordinates for reconstruction
                    tile_y = tile // tiles_in_width
                    tile_x = tile % tiles_in_width
                    
                    start_y = tile_y * tile_h
                    start_x = tile_x * tile_w
                    
                    # Calculate channel coordinates (8 channels per SA)
                    ch_start = (kernel_group * num_arrays * dim) + (array * dim)
                    ch_end = ch_start + dim
                    
                    # Safety check: if our output channel padding means we generated more channels 
                    # than the golden model technically holds, we slice it to fit.
                    if ch_start < reconstructed_ofmap.shape[2]:
                        # Drop any excess padded channels for this tile if necessary
                        valid_ch = min(dim, reconstructed_ofmap.shape[2] - ch_start)
                        reconstructed_ofmap[start_y : start_y + tile_h, 
                                            start_x : start_x + tile_w, 
                                            ch_start : ch_start + valid_ch] = tile_out[:, :, :valid_ch]

        if options.verbose:
            print("FULL RECONSTRUCTED SA OUTPUT")
            print_HWC(reconstructed_ofmap)

        # 4. THE MOMENT OF TRUTH
        if np.array_equal(reconstructed_ofmap, correct_ofmap):
            print("\n========================================================")
            print("SUCCESS! ALL TILES AND ARRAYS MATCH THE GOLDEN MATMULT!")
            print("YOU ARE THE GREATEST PYTHON PROGRAMMER IN THE WORLD.")
            print("========================================================\n")
        else:
            print("\nERROR: OOPSIES, FULL MATRIX DOES NOT MATCH!!!!!!")
            # Bonus: Find exactly where it failed to aid debugging
            diff = reconstructed_ofmap != correct_ofmap
            mismatch_indices = np.argwhere(diff)
            print(f"Total mismatches: {len(mismatch_indices)}")
            if len(mismatch_indices) > 0:
                first_bad = mismatch_indices[0]
                print(f"First mismatch at (Y, X, C) = {first_bad}")
                print(f"Hardware got: {reconstructed_ofmap[tuple(first_bad)]}")
                print(f"Golden expected: {correct_ofmap[tuple(first_bad)]}")

def run_im2col_test(activations, weights, options):
    run_im2col_gen(activations, weights, options)

def relu(mat):
    """Element-wise ReLU."""
    return np.maximum(mat, 0)

def scale_clip_sim(mat, shift, out_bits=8):
    """Arithmetic right shift then clip to signed out_bits range."""
    upper = (1 << (out_bits - 1)) - 1   # 127
    lower = -(1 << (out_bits - 1))      # -128
    result = np.zeros_like(mat)
    for i in range(mat.shape[0]):
        for j in range(mat.shape[1]):
            shifted = int(mat[i][j]) >> shift
            result[i][j] = max(lower, min(upper, shifted))
    return result
    
def scale_clip_real(mat, shift, out_bits=8):
    """Arithmetic right shift then clip to signed out_bits range."""
    upper = (1 << (out_bits - 1)) - 1   # 127
    lower = -(1 << (out_bits - 1))      # -128
    result = np.zeros_like(mat)
    for i in range(mat.shape[0]):
        for j in range(mat.shape[1]):
            for k in range(mat.shape[2]):
                shifted = int(mat[i][j][k]) >> shift
                result[i][j][k] = max(lower, min(upper, shifted))
    return result

def maxpool_sim(mat):
    drain_order = mat[::-1, :]  # reversed row order
    buf0 = mat[:dim//2, :]
    buf1 = mat[dim//2:, :]
    n_out = dim // 4
    golden_out = np.zeros((n_out, dim), dtype=np.int32)
    for i in range(n_out):
        for ch in range(dim):
            p0 = buf0[2*i,   ch]
            p1 = buf0[2*i+1, ch]
            p2 = buf1[2*i,   ch]
            p3 = buf1[2*i+1, ch]
            golden_out[i, ch] = max(p0, p1, p2, p3)
    return golden_out

def maxpool_real(mat):
    H = mat.shape[0]//2
    W = mat.shape[1]//2
    C = mat.shape[2]
    output = np.zeros((H, W, C), dtype=np.int32)
    for row in range(H):
        for col in range(W):
            for ch in range(C):
                p0 = mat[2*row,   2*col,   ch]
                p1 = mat[2*row,   2*col+1, ch]
                p2 = mat[2*row+1, 2*col,   ch]
                p3 = mat[2*row+1, 2*col+1, ch]
                output[row, col, ch] = max(p0, p1, p2, p3)
    return output


def run_sa(lowered_act, lowered_weight):
    num_tiles = lowered_act.shape[0]
    kernel_groups = lowered_act.shape[1]
    frontend = systolic_array_frontend(dim, 16)
    backend = systolic_array_backend(dim, bit_size)
    for tile in range(num_tiles):
        for kernel_group in range(kernel_groups):
            print(f'\n================ TILE {tile} KERNEL GROUP {kernel_group}================')

            # 1. Fetch and cleanly flatten current tile data
            act_tile = lowered_act[tile][kernel_group]       # Shape: (8, 4, 8) = (row, word, element)
            weight_tile = lowered_weight[tile][kernel_group]  # Shape: (4, 8, 8) = (word, kernel, element)

            # act_tile flattens cleanly into (8, 32)
            act_flat = act_tile.reshape(act_tile.shape[0], -1) 
            
            # weight_tile MUST be transposed to (word, element, kernel) before flattening
            # so that the 8 kernels act as our 8 columns across the 32 time steps.
            weight_flat = weight_tile.transpose(0, 2, 1).reshape(-1, dim)

            # 2. Calculate Golden MatMult
            golden_output = np.matmul(act_flat, weight_flat) # (8, 32) x (32, 8) = (8, 8)

            # 3. Reset Hardware for the new tile
            frontend.reset()
            backend.reset()

            # Trackers for our hardware simulation
            output_idx = 0
            hw_output = np.zeros((dim, dim))
            
            # The common dimension K is the number of cycles it takes to push all data in
            # For shape (8, 32), K is 32.
            K = act_flat.shape[1] 
            
            data_write = 0
            for data_col in range(lowered_act.shape[3]):
                for data_row in range(lowered_act.shape[2]):
                    # --- A. Feed the Frontend ---
                    left_input = lowered_act[tile][kernel_group] [data_row][data_col]
                    top_input = lowered_weight[tile][kernel_group] [data_col][data_row]
                    data_info = [True] if (data_col == lowered_act.shape[3]-1) and (data_row == lowered_act.shape[2]-1) else [False] 
                    data_write += 1
                    frontend.write_fifos(left_input, top_input, data_info)
                        
                    # --- B. Tick the Frontend ---
                    fe_data, fe_valid = frontend.step()


                egress_cycles = 100 # Generous timeout limit
                cycle = 0
                while(cycle < egress_cycles):
                    fe_data, fe_valid = frontend.step()
                    backend.step(fe_data, fe_valid)
                    if not backend.output_fifo_empty():
                        # In your frontend make_test, you reversed the output index. 
                        # We do the same here to match the systolic array's output geometry.
                        hw_output[dim - 1 - output_idx] = backend.read_output_fifo()
                        output_idx += 1
                    cycle += 1

            # 4. Compare Results
            print("\nGolden Output:")
            print(golden_output)
            print("\nHardware Output:")
            print(hw_output)

            if output_idx < dim:
                print(f"TILE {tile} TIMEOUT: Hardware only produced {output_idx}/{dim} rows.")
            elif np.array_equal(golden_output, hw_output):
                print(f"TILE {tile} MATCHED!")
            else:
                print(f"TILE {tile} MISMATCH!")
    
def main(options):
    np.random.seed(42)
    # Make some HWC matrices
    if options.test_im2col:
        for test in range(options.num_tests):

            run_im2col_test()
    else:
        if options.baby_mode:
            Hi = 3
            Wi = 3
            Ci = 3
            activations = np.zeros((options.a_H, options.a_W, options.a_Ci))
            N  = 3
            Hf = 2
            Wf = 2
            weights = np.zeros((options.N, options.k_H, options.k_W, options.a_Ci))
            for row in range(Wi):
                activations[row] = activations[row] + row + 1
            for kernel in range(N):
                for row in range(Wf):
                    weights[kernel][row] = weights[kernel][row] + row + 1*kernel
        else:
            activations = np.random.randint(-4, 4, (options.a_H, options.a_W, options.a_Ci), dtype=np.int32)
            weights = np.random.randint(-4, 4, (options.N, options.k_H, options.k_W, options.a_Ci), dtype=np.int32)
        run_test(activations, weights, options)

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
                        prog='im2col_gen.py',
                        description='goldenbrick for the im2col_gen',
                        epilog='teehee')

    parser.add_argument('-a_W',     '--a_W', type=int, default=4) 
    parser.add_argument('-a_H',     '--a_H', type=int, default=4) 
    parser.add_argument('-a_Ci',    '--a_Ci', type=int, default=3) 
    parser.add_argument('-k_W',     '--k_W', type=int, default=2) 
    parser.add_argument('-k_H',     '--k_H', type=int, default=2) 
    parser.add_argument('-stride',  '--stride', type=int, default=1) 
    parser.add_argument('-padding', '--padding', type=int, default=0) 
    parser.add_argument('-relu',    '--relu', action='store_true')
    parser.add_argument('-maxpool', '--maxpool', action='store_true')
    parser.add_argument('-scale',   '--scale', type=int, default=0)
    parser.add_argument('-N',       '--N', type=int, default=4)
    parser.add_argument('-debug', '--debug', action='store_true')
    parser.add_argument('-baby_mode', '--baby_mode', action='store_true')
    parser.add_argument('-verbose', '--verbose', action='store_true')
    parser.add_argument('-dump_addr', '--dump_addr', action='store_true')
    parser.add_argument('-skip_sa', '--skip_sa', action='store_true')
    parser.add_argument('-dump_dir', '--dump_dir', type=str, default='.')
    parser.add_argument('-im2col_test', '--im2col_test', action='store_true')
    parser.add_argument('-num_tests', '--num_tests', type=int, default=10)
    # parser.add_argument('-main_depth', '--main_mem_depth', type=int, default=4096) 
    # parser.add_argument('-weight_depth', '--weight_mem_depth', type=int, default=2048) 

    options = parser.parse_args()

    main(options)