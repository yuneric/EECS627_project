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


def dim_check_fast(Hi, Wi, Ci, Co, Hf, Wf, stride, padding, maxpool=0):

    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)

    pad = 4 - (Wo % 4)
    Wo += pad
    pad = 4 - (Wo % 4)
    Ho += pad

    if(maxpool):
        Wo = Wo//2
        Ho = Ho//2
        
    # Need to account for the fact that we are zero padding channels
    words_needed_for_Ci = math.ceil(Ci/word_size)
    num_words_for_output_channels = math.ceil(Co/word_size)

    # Determine how much space our inputs, weights, and outputs take up
    max_weight_words = 2048
    max_act_words = 4096
    #activation_size = Hi * Wi * words_needed_for_Ci * word_size
    activation_words = Hi * Wi * words_needed_for_Ci
    #kernel_size_single =  Hf * Wf * words_needed_for_Ci * word_size
    kernel_words = Hf * Wf * words_needed_for_Ci
    #kernels_size = kernel_size_single * Co # We can operate on 8 kernels at a time
    #output_size = Wo * Ho * num_words_for_output_channels * word_size
    output_words = Wo * Ho * num_words_for_output_channels

    max_num_kernels = (Co // 64) * 8
    kernels_left = Co % 64
    if kernels_left >= 8:
        max_num_kernels += 8
    else:
        max_num_kernels += kernels_left

    weight_words = kernel_words * max_num_kernels
    if(max_act_words < activation_words):
        return 1

    if(max_act_words < output_words):
        return 1

    if(max_weight_words < weight_words):
        # print(max_num_kernels)
        # print(f'Hf: {Hf} Wf: {Wf} Ci: {Ci} Co: {Co}')
        return 1

    return 0

def run_im2col_gen(activations, weights, stride, padding, options):

    # Get our dimensions
    Hi, Wi, Ci = activations.shape
    Co, Hf, Wf, Ci = weights.shape
    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)

    words_needed_for_Ci = math.ceil(Ci/word_size)
    num_words_for_output_channels = math.ceil(Co/word_size)
    kernel_size_single =  Hf * Wf * words_needed_for_Ci * word_size
    num_rows_per_kernel = Hf * Wf * words_needed_for_Ci

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
    if main_mem.shape[0] > 4096:
        print(f"MAIN MEM TOO BIG rows: {main_mem.shape[0]}")
    if weight_mem.shape[0] > 2048*8:
        print(f"WEIGHT MEM TOO BIG rows: {weight_mem.shape[0]}")
        
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
    if options.verbose:
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
        im2col_test_file = open('im2col_test.txt', 'a')
    elif options.compute_test:
        im2col_test_file = open('comp_test_im2col.out', 'a')

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

                total = words_needed_for_Ci * Hf * Wf * dim
                cnt = 0
                kernels_in_group = 64 if (Co - kernels_processed >= 64) else (Co - kernels_processed)
                #print(kernels_in_group)
                array_wts_valid = [0] * num_arrays
                for kernel in range(kernels_in_group):
                    array_wts_valid[kernel//8] += 1
                if options.im2col_test:
                    # im2col_test_file.write(f'kernels_processed: {kernels_processed}\n')
                    # im2col_test_file.write(f'kgroup: {kernel_group}\n')
                    im2col_test_file.write(f'cfg_tile_H: {Hi:03x} cfg_tile_W: {Wi:03x} cfg_Hf: {Hf:03x} cfg_Wf: {Wf:03x} ' 
                                           f'cfg_stride: {stride:02b} cfg_padding: {padding:02b} cfg_words_ci: {words_needed_for_Ci:03x} '
                                           f'cfg_curr_kernel_group: {kernel_group:03x} cfg_num_kernels_per_group: {kernels_in_group:03x} '
                                           f'cfg_sub_tile_x: {tile_h:03x} cfg_sub_tile_y: {tile_v:03x} cfg_x_bound: {x_bound:02b} cfg_y_bound: {y_bound:01b} '
                                           f'total: {total:d}\n')
                # if options.compute_test:
                #     im2col_test_file.write(f'tile: ({tile_v},{tile_h})\n')


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

                                if options.im2col_test or options.compute_test:
                                    # [act_mem_address] [valid_out] [weight_mem_address] [valid_weight_bits] [data last bit]
                                    array_enable = [0] * 8
                                    for array in range(num_arrays):
                                        array_enable[array] = array_wts_valid[array] > row
                                    cnt += 1
                                    kernel_num = row + (dim) * kernel_group
                                    weight_mem_address = ((weight_pixel_x + weight_pixel_y*Wf) * words_needed_for_Ci) + word_idx + (kernel_num * num_rows_per_kernel)
                                    #im2col_test_file.write(f'{mem_address}\n')
                                    if(mem_address < 0 or mem_address > 2**12 - 1):
                                        mem_address = 0
                                    # if(weight_mem_address > 2047):
                                    #     print(weight_mem_address)
                                    #     print(Hi, Wi, Hf, Wf, Ci, Ho, Wo, Co)
                                    #     print(row, dim, kernel_group, weight_pixel_x, weight_pixel_y, Wf, words_needed_for_Ci, word_idx, kernel_num, num_rows_per_kernel)
                                    if(weight_mem_address < 0 or weight_mem_address > 2**11 - 1):
                                        weight_mem_address = 0
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
                kernels_processed = Co
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

def run_comp_over_test(activations, weights, stride, padding, maxpool, relu_en, scale, options):
    # GOO GOO GAH GAH mode
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
        stride = 1
        padding = 0

    # DO THE IM2COL_GEN
    # lowered_weight now has shape [num_arrays, kernel_groups, tile_num, rows, cols, word_size]
    lowered_act, lowered_weight = run_im2col_gen(activations, weights, stride, padding, options)

    # 1. GET THE GOLDEN NUMPY OFMAP FIRST
    # Doing this first so we can use its shape to build our empty reconstructed matrix
    correct_ofmap = do_cnn_layer(activations, weights, stride, padding)
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, word_size)
    # make the matrices a multiple of our 2x4 systolic array output
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, 2, 0) # pad the rows
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, 4, 1) # pad the cols
    
    # Apply backend processing to the golden model
    if relu_en: correct_ofmap = relu(correct_ofmap)
    correct_ofmap = scale_clip_real(correct_ofmap, scale)
    if maxpool: correct_ofmap = maxpool_real(correct_ofmap)

    # if options.verbose:
    #     print("ACTIVATIONS")
    #     print_HWC(activations)
    #     print("WEIGHTS")
    #     print_HWC(weights[0])
    #     print("NUMPY OFMAP")
    #     print_HWC(correct_ofmap)
        
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
    unpooled_W = correct_ofmap.shape[1] * (2 if maxpool else 1)
    tiles_in_width = math.ceil(unpooled_W / 4)

    # Simulate all arrays!
    Hi, Wi, Ci = activations.shape
    Co, Hf, Wf, Ci = weights.shape
    words_needed_for_Ci = math.ceil(Ci/word_size)
    words_needed_for_Co = math.ceil(Co/word_size)

    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)

    # Write the header to the stimuli file
    comp_test_in = open('comp_over_test.in', 'a')
    comp_test_out = open('comp_over_test.out', 'a')
    comp_test_in.write(f'comp_Hi: {Hi:03x} comp_Wi: {Wi:03x} comp_Hf: {Hf:03x} comp_Wf: {Wf:03x} comp_Ho: {Ho:03x} comp_Wo: {Wo:03x} '
                       f'comp_words_per_channel: {words_needed_for_Ci:03x} comp_num_kernels: {Co:03x} ' 
                       f'comp_stride: {stride:02b} comp_padding: {padding:02b} comp_maxpool_en: {maxpool:01b}\n')
    
    # Make an in code model of the output mem that we are creating so we can check our reconstruction
    output_mem = np.empty((correct_ofmap.shape), dtype=np.int8)
    output_mem = make_memory_model(output_mem, word_size)
    num_out_writes = 0
    num_out_writes_correct = output_mem.shape[0]

    for kernel_group in range(num_kernel_groups):
        for tile in range(num_tiles):
            for array in range(num_arrays):
                
                # Core MatMult for this specific array, group, and tile
                simulated = np.matmul(lowered_act_mats[kernel_group][tile], lowered_weight_mats[array][kernel_group][tile])

                # Pass through backend
                if relu_en: simulated = relu(simulated)
                simulated = scale_clip_sim(simulated, scale)
                if maxpool: simulated = maxpool_sim(simulated)
                
                # Format output dimensions based on maxpool
                if maxpool:
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

                # Write out our systolic array tile
                x = start_x
                y = start_y
                ch_word = ch_start
                for sa_row in range(simulated.shape[0]):
                    #for data in range(word_size):
                    for data in range(word_size-1, -1, -1):
                        comp_test_in.write(f'{simulated[sa_row][data].astype(np.uint8):02x}')
                    
                    # Also provide a destination address in the final memory model for testing purposes
                    valid_ch = ch_word // 8 < words_needed_for_Co
                    if valid_ch:
                        dst_addr = (x + y*correct_ofmap.shape[1]) * words_needed_for_Co + ch_word//8
                        output_mem[dst_addr] = simulated[sa_row]
                        num_out_writes += 1
                    else:
                        dst_addr = 0

                    comp_test_in.write(f' {x:03x} {y:03x} {ch_word:03x} {valid_ch:01b} {dst_addr:03x}')
                    comp_test_in.write('\n')
                    x += 1
                    if(x % tile_w == 0):
                        x = start_x
                        y += 1
                
                # Safety check: if our output channel padding means we generated more channels 
                # than the golden model technically holds, we slice it to fit.
                if ch_start < reconstructed_ofmap.shape[2]:
                    # Drop any excess padded channels for this tile if necessary
                    valid_ch = min(dim, reconstructed_ofmap.shape[2] - ch_start)
                    reconstructed_ofmap[start_y : start_y + tile_h, 
                                        start_x : start_x + tile_w, 
                                        ch_start : ch_start + valid_ch] = tile_out[:, :, :valid_ch]

    # if options.verbose:
    #     print("FULL RECONSTRUCTED SA OUTPUT")
    #     print_HWC(reconstructed_ofmap)

    if(num_out_writes != num_out_writes_correct):
        print("HOUSTON WE HAVE A PROBLEM")

    # Put it back so that element 0 is MSB and 7 is LSB
    output_mem = output_mem[:, ::-1]

    # 4. THE MOMENT OF TRUTH
    if np.array_equal(reconstructed_ofmap, correct_ofmap):
        # Write out the correct output matrix
        golden_out = make_memory_model(reconstructed_ofmap, word_size)
        x = 0
        y = 0
        ch_word = 0
        for word in range(golden_out.shape[0]):
            dst_addr = (x + y*correct_ofmap.shape[1]) * words_needed_for_Co + ch_word//8
            for data in range(word_size):
                comp_test_out.write(f'{golden_out[word][data].astype(np.uint8):02x}')
                if(output_mem[dst_addr][data] != golden_out[word][data]):
                    print("ERROR: golden mismatch between output_mem and golden_out")
                    print(f'dst_addr:{dst_addr} act:{output_mem[dst_addr]} exp:{golden_out[word]}')
            comp_test_out.write(f' {x:03x} {y:03x} {ch_word:03x} {dst_addr:03x}')
            comp_test_out.write('\n')
            ch_word += 8
            if(ch_word == words_needed_for_Co*dim):
                ch_word = 0
                x += 1
                if(x == correct_ofmap.shape[1]):
                    x = 0
                    y += 1
        #print(output_mem)
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
    comp_test_in.close()
    comp_test_out.close()

def run_test(activations, weights, stride, padding, options):
    # GOO GOO GAH GAH
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
        stride = 1
        padding = 0

    # DO THE IM2COL_GEN
    # lowered_weight now has shape [num_arrays, kernel_groups, tile_num, rows, cols, word_size]
    lowered_act, lowered_weight = run_im2col_gen(activations, weights, stride, padding, options)
    
    # this part had a bit of gemini help to speed up its development, thanks gemini
    if not options.debug:
        print(f'Maxpool: {options.maxpool}')
        print(f'Relu: {options.relu}')
        print(f'Scale: {options.scale}')
        # 1. GET THE GOLDEN NUMPY OFMAP FIRST
        # Doing this first so we can use its shape to build our empty reconstructed matrix
        correct_ofmap = do_cnn_layer(activations, weights, stride, padding)
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

def run_im2col_test(activations, weights, stride, padding, options):
    # GOO GOO GAH GAH
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
        stride = 1
        padding = 0
    Hi = 32
    Wi = 32
    Ci = 8
    activations = np.zeros((Hi, Wi, Ci))
    N  = 32
    Hf = 3
    Wf = 3
    weights = np.random.randint(-5, 5, (N, Hf, Wf, Ci), dtype=np.int8)
    activations = np.random.randint(-5, 5, (Hi, Wi, 3), dtype=np.int8)
    activations = pad_channels_to_word_size(activations, 8)
    stride = 1
    padding = 1
    maxpool = 1
    relu_en = 1
    scale = 0

    run_im2col_gen(activations, weights, stride, padding, options)

def run_compute_test(activations, weights, stride, padding, maxpool, relu_en, scale, options):
    # GOO GOO GAH GAH mode
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
        stride = 1
        padding = 0

    # DO THE IM2COL_GEN
    # lowered_weight now has shape [num_arrays, kernel_groups, tile_num, rows, cols, word_size]
    lowered_act, lowered_weight = run_im2col_gen(activations, weights, stride, padding, options)

    # 1. GET THE GOLDEN NUMPY OFMAP FIRST
    # Doing this first so we can use its shape to build our empty reconstructed matrix
    correct_ofmap = do_cnn_layer(activations, weights, stride, padding)
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, word_size)
    # make the matrices a multiple of our 2x4 systolic array output
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, 2, 0) # pad the rows
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, 4, 1) # pad the cols
    
    # Apply backend processing to the golden model
    if relu_en: correct_ofmap = relu(correct_ofmap)
    correct_ofmap = scale_clip_real(correct_ofmap, scale)
    if maxpool: correct_ofmap = maxpool_real(correct_ofmap)

    if options.verbose:
        print("ACTIVATIONS")
        print_HWC(activations)
        print("WEIGHTS")
        print_HWC(weights[0])
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
    unpooled_W = correct_ofmap.shape[1] * (2 if maxpool else 1)
    tiles_in_width = math.ceil(unpooled_W / 4)

    # Simulate all arrays!
    Hi, Wi, Ci = activations.shape
    Co, Hf, Wf, Ci = weights.shape
    words_needed_for_Ci = math.ceil(Ci/word_size)
    words_needed_for_Co = math.ceil(Co/word_size)

    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)

    comp_test_act_in = open('comp_test_act.in', 'a')
    comp_test_wt_in = open('comp_test_wt.in', 'a')
    comp_test_mat_out = open('comp_test_mat.out', 'a')

    # Write the header to the activations file
    comp_test_act_in.write(f'comp_Hi: {Hi:03x} comp_Wi: {Wi:03x} comp_Hf: {Hf:03x} comp_Wf: {Wf:03x} comp_Ho: {Ho:03x} comp_Wo: {Wo:03x} '
                       f'comp_words_per_channel: {words_needed_for_Ci:03x} comp_num_kernels: {Co:03x} ' 
                       f'comp_stride: {stride:02b} comp_padding: {padding:02b} '
                       f'comp_maxpool_en: {maxpool:01b} comp_relu_en: {relu_en:01b} comp_scale_amt: {scale:05b}\n')

    # Write the activations
    activations_mem_model = make_memory_model(activations, word_size)
    for word in range(activations_mem_model.shape[0]):
        for data in range(word_size):
            comp_test_act_in.write(f'{activations_mem_model[word][data].astype(np.uint8):02x}')
        comp_test_act_in.write('\n')

    # Write the weights
    weights_mem_model = make_memory_model(weights, word_size)
    for word in range(weights_mem_model.shape[0]):
        for data in range(word_size):
            comp_test_wt_in.write(f'{weights_mem_model[word][data].astype(np.uint8):02x}')
        comp_test_wt_in.write('\n')

    # Write the output matrix
    golden_out = make_memory_model(correct_ofmap, word_size)
    for word in range(golden_out.shape[0]):
        for data in range(word_size):
            comp_test_mat_out.write(f'{golden_out[word][data].astype(np.uint8):02x}')
        comp_test_mat_out.write('\n')
        # print(output_mem)

    comp_test_act_in.close()
    comp_test_wt_in.close()
    comp_test_mat_out.close()

    # Make an in code model of the output mem that we are creating so we can check our reconstruction
    output_mem = np.empty((correct_ofmap.shape), dtype=np.int8)
    output_mem = make_memory_model(output_mem, word_size)
    num_out_writes = 0
    num_out_writes_correct = output_mem.shape[0]

    comp_test_tiles_out = open('comp_test_tiles.out', 'a')
    for kernel_group in range(num_kernel_groups):
        for tile in range(num_tiles):
            for array in range(num_arrays):
                
                # Core MatMult for this specific array, group, and tile
                simulated = np.matmul(lowered_act_mats[kernel_group][tile], lowered_weight_mats[array][kernel_group][tile])

                # Pass through backend
                if relu_en: simulated = relu(simulated)
                simulated = scale_clip_sim(simulated, scale)
                if maxpool: simulated = maxpool_sim(simulated)
                
                # Format output dimensions based on maxpool
                if maxpool:
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

                # Write out our systolic array tile
                x = start_x
                y = start_y
                ch_word = ch_start
                for sa_row in range(simulated.shape[0]):
                    #for data in range(word_size):
                    for data in range(word_size-1, -1, -1):
                        comp_test_tiles_out.write(f'{simulated[sa_row][data].astype(np.uint8):02x}')
                    
                    # Also provide a destination address in the final memory model for testing purposes
                    valid_ch = ch_word // 8 < words_needed_for_Co
                    if valid_ch:
                        dst_addr = (x + y*correct_ofmap.shape[1]) * words_needed_for_Co + ch_word//8
                        output_mem[dst_addr] = simulated[sa_row]
                        num_out_writes += 1
                    else:
                        dst_addr = 0

                    comp_test_tiles_out.write(f' {x:03x} {y:03x} {ch_word:03x} {valid_ch:01b} {dst_addr:03x}')
                    comp_test_tiles_out.write('\n')
                    x += 1
                    if(x % tile_w == 0):
                        x = start_x
                        y += 1
                
                # Safety check: if our output channel padding means we generated more channels 
                # than the golden model technically holds, we slice it to fit.
                if ch_start < reconstructed_ofmap.shape[2]:
                    # Drop any excess padded channels for this tile if necessary
                    valid_ch = min(dim, reconstructed_ofmap.shape[2] - ch_start)
                    reconstructed_ofmap[start_y : start_y + tile_h, 
                                        start_x : start_x + tile_w, 
                                        ch_start : ch_start + valid_ch] = tile_out[:, :, :valid_ch]

    # if options.verbose:
    #     print("FULL RECONSTRUCTED SA OUTPUT")
    #     print_HWC(reconstructed_ofmap)

    if(num_out_writes != num_out_writes_correct):
        print("HOUSTON WE HAVE A PROBLEM")

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
    comp_test_tiles_out.close()

def run_top_test(activations, weights, stride, padding, maxpool, relu_en, scale, options):
    # GOO GOO GAH GAH mode
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
        stride = 1
        padding = 0
        maxpool = 0

    # 1. GET THE GOLDEN NUMPY OFMAP FIRST
    # Doing this first so we can use its shape to build our empty reconstructed matrix
    correct_ofmap = do_cnn_layer(activations, weights, stride, padding)
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, word_size)
    # make the matrices a multiple of our 2x4 systolic array output
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, 2, 0) # pad the rows
    correct_ofmap = pad_channels_to_word_size(correct_ofmap, 4, 1) # pad the cols
    
    # Apply backend processing to the golden model
    if relu_en: correct_ofmap = relu(correct_ofmap)
    correct_ofmap = scale_clip_real(correct_ofmap, scale)
    if maxpool: correct_ofmap = maxpool_real(correct_ofmap)

    if options.verbose:
        print("NUMPY OFMAP")
        print_HWC(correct_ofmap)

    # Print our test info
    Hi, Wi, Ci = activations.shape
    Co, Hf, Wf, Ci = weights.shape
    words_needed_for_Ci = math.ceil(Ci/word_size)
    words_needed_for_Co = math.ceil(Co/word_size)

    #Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)
    Ho = correct_ofmap.shape[0]
    Wo = correct_ofmap.shape[1]

    top_test_cfg = open('top_test.cfg', 'w')
    top_test_mem = open('top_test.mem', 'w')

    # Write the header to the activations file
    top_test_cfg.write(f'comp_Hi: {Hi:03x}\ncomp_Wi: {Wi:03x}\ncomp_Hf: {Hf:03x}\ncomp_Wf: {Wf:03x}\ncomp_Ho: {Ho:03x}\ncomp_Wo: {Wo:03x}\n'
                       f'comp_Ci: {Ci:03x}\n'
                       f'comp_num_kernels: {Co:03x}\n' 
                       f'words_needed_for_Ci: {words_needed_for_Ci:03x}\nwords_needed_for_Co: {words_needed_for_Co:03x}\n'
                       f'comp_stride: {stride:02b}\ncomp_padding: {padding:02b}\n'
                       f'comp_maxpool_en: {maxpool:01b}\ncomp_relu_en: {relu_en:01b}\ncomp_scale_amt: {scale:05b}\n')

    # Write the activations
    act_start_addr = 0
    act_end_addr = 0
    cpu_word_size = 4
    activations_mem_model = make_cpu_memory_model(activations, cpu_word_size)
    for word in range(activations_mem_model.shape[0]):
        for data in range(cpu_word_size):
            top_test_mem.write(f'{activations_mem_model[word][data].astype(np.uint8):02x}')
            act_end_addr += 1
        top_test_mem.write('\n')

    # Write the weights
    wt_start_addr = act_end_addr
    wt_end_addr = wt_start_addr
    weights_mem_model = make_cpu_memory_model(weights, cpu_word_size)
    for word in range(weights_mem_model.shape[0]):
        for data in range(cpu_word_size):
            top_test_mem.write(f'{weights_mem_model[word][data].astype(np.uint8):02x}')
            wt_end_addr += 1
        top_test_mem.write('\n')

    # Write the output matrix
    output_start_addr = wt_end_addr
    output_end_addr = output_start_addr
    golden_out = make_cpu_memory_model(correct_ofmap, cpu_word_size)
    for word in range(golden_out.shape[0]):
        for data in range(cpu_word_size):
            top_test_mem.write(f'{golden_out[word][data].astype(np.uint8):02x}')
            output_end_addr += 1 
        top_test_mem.write('\n')

    top_test_mem.close()

    top_test_cfg.write(f'act_start_addr:    {act_start_addr:08x}\n')
    top_test_cfg.write(f'act_end_addr:      {act_end_addr:08x}\n')
    top_test_cfg.write(f'wt_start_addr:     {wt_start_addr:08x}\n')
    top_test_cfg.write(f'wt_end_addr:       {wt_end_addr:08x}\n')
    top_test_cfg.write(f'output_start_addr: {output_start_addr:08x}\n')
    top_test_cfg.write(f'output_end_addr:   {output_end_addr:08x}\n')

    top_test_cfg.close()



def random_input_gen():
    
    test_not_valid = 1
    while(test_not_valid):
        # Get our dimensions
        Hi = random.randint(4, 256)
        Wi = random.randint(4, 256)
        Hf = random.randint(1, Hi//2 + 1)
        Wf = random.randint(1, Wi//2 + 1)
        Ci  = random.randint(1, 256)
        Co  = random.randint(1, 256)
        stride = random.randint(1, 2)
        padding = random.randint(0, 3)

        test_not_valid = dim_check_fast(Hi, Wi, Ci, Co, Hf, Wf, stride, padding)

    bound = random.randint(1, 512)
    activations = np.random.randint(0-bound, bound, (Hi, Wi, Ci), dtype=np.int32)
    weights = np.random.randint(0-bound, bound, (Co, Hf, Wf, Ci), dtype=np.int32)
    return activations, weights, stride, padding

def random_input_gen_all():
    
    test_not_valid = 1
    while(test_not_valid):
        # Get our dimensions
        # Hi = random.randint(4, 256)
        # Wi = random.randint(4, 256)
        # Hf = random.randint(1, Hi//2 + 1)
        # Wf = random.randint(1, Wi//2 + 1)
        # Ci  = random.randint(1, 256)
        # Co  = random.randint(1, 256)
        # stride = random.randint(1, 2)
        # padding = random.randint(0, 3)
        # maxpool = random.randint(0, 1)
        # relu = random.randint(0, 1)
        # scale = random.randint(0, 31)
        Hi = random.randint(4, 64)
        Wi = random.randint(4, 64)
        Hf = random.randint(1, Hi//2 + 1)
        Wf = random.randint(1, Wi//2 + 1)
        Ci  = random.randint(1, 128)
        Co  = random.randint(1, 128)
        stride = random.randint(1, 2)
        padding = random.randint(0, 3)
        maxpool = random.randint(0, 1)
        relu = random.randint(0, 1)
        scale = random.randint(0, 4)

        test_not_valid = dim_check_fast(Hi, Wi, Ci, Co, Hf, Wf, stride, padding, maxpool)

    bound = random.randint(1, 10)
    activations = np.random.randint(0-bound, bound, (Hi, Wi, Ci), dtype=np.int32)
    weights = np.random.randint(0-bound, bound, (Co, Hf, Wf, Ci), dtype=np.int32)
    return activations, weights, stride, padding, maxpool, relu, scale

def print_info(activations, weights, stride, padding, maxpool, relu, scale):
    # Determine how much space our inputs, weights, and outputs take up
    Hi, Wi, Ci = activations.shape
    Co, Hf, Wf, Ci = weights.shape
    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride, padding)
    print(f'Input shape: Hi: {Hi} Wi: {Wi} Ci: {Ci}')
    print(f'Kernel shape: Hf: {Hf} Wf: {Wf} Ci: {Ci} Co: {Co}')
    print(f'Output shape real: Ho: {Ho} Wo: {Wo} Co: {Co}')
    pad = 4 - (Wo % 4)
    Wo += pad
    pad = 4 - (Wo % 4)
    Ho += pad
    if(maxpool):
        Wo = Wo//2
        Ho = Ho//2
    words_needed_for_Ci = math.ceil(Ci/word_size)
    num_words_for_output_channels = math.ceil(Co/word_size)
    activation_size = Hi * Wi * words_needed_for_Ci * word_size
    kernel_size_single =  Hf * Wf * words_needed_for_Ci * word_size
    num_rows_per_kernel = Hf * Wf * words_needed_for_Ci
    kernels_size = kernel_size_single * Co # We can operate on 8 kernels at a time
    output_size = Wo * Ho * num_words_for_output_channels * word_size


    print(f'Stride: {stride} Padding: {padding}')
    print(f"words needed for channels: {words_needed_for_Ci} ")

    print(f'main mem size for inputs/outputs: {main_mem_size//1024} kB')
    print(f'weight mem size for weights: {weight_mem_size//1024} kB')
    print(f'weight mem size for weights total: {8*weight_mem_size//1024} kB')

    print(f"activation size: {activation_size//1024} kB")
    print(f"kernels size: {kernels_size//1024} kB")
    print(f"output size: {output_size//1024} kB")

    print(f'Maxpool: {maxpool}')
    print(f'Relu: {relu}')
    print(f'Scale: {scale}')

def main(options):
    # np.random.seed(42)
    # random.seed(10)

    if options.seed == -1:
        # Default: Keep original deterministic behavior for old Make targets
        np.random.seed(42)
        random.seed(10)
    else:
        # Regression mode: Use the seed provided by the bash script
        np.random.seed(options.seed)
        random.seed(options.seed)
    
    if options.im2col_test:
        # Testing for im2col_gen
        im2col_test_file = open('im2col_test.txt', 'w')
        im2col_test_file.close()
        for test in range(options.num_tests):
            activations, weights, stride, padding = random_input_gen()
            print(f'Test #{test}')
            print_info(activations, weights, stride, padding, 0, 0, 0)
            run_im2col_test(activations, weights, stride, padding, options)
    elif options.comp_over_test:
        # Testing for comp_overseer
        comp_test_in = open('comp_over_test.in', 'w')
        comp_test_out = open('comp_over_test.out', 'w')
        comp_test_in.close()
        comp_test_out.close()
        for test in range(options.num_tests):
            activations, weights, stride, padding, maxpool, relu, scale = random_input_gen_all()
            print(f'Test #{test}')
            print_info(activations, weights, stride, padding, maxpool, relu, scale)
            comp_test_in = open('comp_over_test.in', 'a')
            comp_test_out = open('comp_over_test.out', 'a')
            comp_test_in.write(f'test: {test:04d} ')
            comp_test_out.write(f'test: {test:04d} x y ch_start addr\n')
            comp_test_in.close()
            comp_test_out.close()
            run_comp_over_test(activations, weights, stride, padding, maxpool, relu, scale, options)
    elif options.compute_test:
        # Testing for comp_overseer
        comp_test_act_in    = open('comp_test_act.in', 'w')
        comp_test_act_in.close()
        comp_test_wt_in     = open('comp_test_wt.in', 'w')
        comp_test_wt_in.close()
        comp_test_tiles_out = open('comp_test_tiles.out', 'w')
        comp_test_tiles_out.close()
        comp_test_mat_out   = open('comp_test_mat.out', 'w')
        comp_test_mat_out.close()
        comp_test_im2col_out   = open('comp_test_im2col.out', 'w')
        comp_test_im2col_out.close()
        for test in range(options.num_tests):
            activations, weights, stride, padding, maxpool, relu, scale = random_input_gen_all()
            print(f'Test #{test}')
            print_info(activations, weights, stride, padding, maxpool, relu, scale)

            comp_test_act_in = open('comp_test_act.in', 'a')
            comp_test_act_in.write(f'test: {test:0d}\n')
            comp_test_act_in.close()

            comp_test_wt_in = open('comp_test_wt.in', 'a')
            comp_test_wt_in.write(f'test: {test:0d}\n')
            comp_test_wt_in.close()

            comp_test_tiles_out = open('comp_test_tiles.out', 'a')
            comp_test_tiles_out.write(f'test: {test:0d}\n')
            comp_test_tiles_out.close()

            comp_test_mat_out = open('comp_test_mat.out', 'a')
            comp_test_mat_out.write(f'test: {test:0d}\n')
            comp_test_mat_out.close()

            comp_test_im2col_out = open('comp_test_im2col.out', 'a')
            comp_test_im2col_out.write(f'test: {test:0d}\n')
            comp_test_im2col_out.close()

            run_compute_test(activations, weights, stride, padding, maxpool, relu, scale, options)
    elif options.top_test:
        activations, weights, stride, padding, maxpool, relu, scale = random_input_gen_all()
        print_info(activations, weights, stride, padding, maxpool, relu, scale)
        run_top_test(activations, weights, stride, padding, maxpool, relu, scale, options)
    else:
        # Make some HWC matrices
        activations = np.random.randint(-4, 4, (options.a_H, options.a_W, options.a_Ci), dtype=np.int32)
        weights = np.random.randint(-4, 4, (options.N, options.k_H, options.k_W, options.a_Ci), dtype=np.int32)
        run_test(activations, weights, options.stride, options.padding, options)
        #run_comp_over_test(activations, weights, options.stride, options.padding, options.maxpool, options.relu, options.scale, options)

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
    parser.add_argument('-padding', '--padding', type=int, default=1) 
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
    parser.add_argument('-num_tests', '--num_tests', type=int, default=1)
    parser.add_argument('-comp_over_test', '--comp_over_test', action='store_true')
    parser.add_argument('-compute_test', '--compute_test', action='store_true')
    parser.add_argument('-top_test', '--top_test', action='store_true')
    parser.add_argument('-seed', '--seed', type=int, default=-1) #adding this for top tests.
    # parser.add_argument('-main_depth', '--main_mem_depth', type=int, default=4096) 
    # parser.add_argument('-weight_depth', '--weight_mem_depth', type=int, default=2048) 

    options = parser.parse_args()

    main(options)