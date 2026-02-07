import numpy as np
import argparse
import sys
import os

# Add the common script to our path so we can get some epic func's
script_dir = os.path.dirname(__file__) 
scripts_path = os.path.join(script_dir, '../common') 
sys.path.append(scripts_path) 

from matgen import *

def im2col(ifmap, filters, options):
    txt_file = open(options.txt_filename, 'w')
    if options.human_readable:
        txt_file.write(('#'*30) + '\n'  + 'IFMAP:\n')
        print_3D_matrix_str(txt_file, ifmap)
        txt_file.write('\n')
        txt_file.write(('#'*30) + '\n' + 'FILTERS:\n')
        print_4D_matrix_str(txt_file, filters)
        txt_file.write('\n')
    else:
        txt_file.write(('#'*30) + '\n'  + 'IFMAP:\n')
        print_3D_matrix(txt_file, ifmap)
        txt_file.write('\n')
        txt_file.write(('#'*30) + '\n'  + 'FILTERS:\n')
        print_4D_matrix(txt_file, filters)
        txt_file.write('\n')

    # Ifmap dims
    Hi = ifmap.shape[0]
    Wi = ifmap.shape[1]
    # Filters dims
    Hf = filters.shape[1]
    Wf = filters.shape[2]
    # Channels
    Ci = ifmap.shape[2]
    stride = options.stride
    # Outputs dims
    Wo, Ho = calc_output_dim(Wi, Hi, Wf, Hf, stride)
    Co = options.filters

    # Get a 1D view like we would in hardware mem
    ifmap_vec = ifmap.ravel()
    filters_vec = filters.ravel()

    # Lowered input feature map
    lowered_ifmap_H = Ho * Wo
    lowered_ifmap_W = Hf * Wf * Ci
    if options.human_readable:
        lowered_ifmap = np.empty((lowered_ifmap_H, lowered_ifmap_W), dtype='<U10')
    else:
        lowered_ifmap = np.zeros((lowered_ifmap_H, lowered_ifmap_W), dtype=np.int8)

    # Lowered filters
    lowered_filters_H = lowered_ifmap_W
    lowered_filters_W = options.filters
    if options.human_readable:
        lowered_filters = np.empty((lowered_filters_H, lowered_filters_W), dtype='<U10')
    else:
        lowered_filters = np.zeros((lowered_filters_H, lowered_filters_W), dtype=np.int8)

    # Try to do the im2col like the hardware would do
    ''' 
    In effect we want to take every patch of the input (ifmap) that the weights (filters)
    pass over during convolution, and unravel them into a row of a new ifmap matrix. Each filter
    is then unraveled into a column of the new filters matrix. When this finishes, we 
    should have 2D matrices that we can multiply normally. This duplicates inputs that we 
    feed, but we will be doing this as we read mem out of our buffer and pass to the
    systolic array. In effect we create this input on the fly.
    '''

    ######################
    # Lowering the ifmap #
    ######################

    # Convolution pixel parameters
    pixel_row = 0           # top left pixel row
    pixel_col = 0           # top left pixel col 
    base_pixel_address = 0  # top left pixel address in ifmap_vec
    output_col = 0          # the column of the output that we are currently generating inputs for

    # Each row of the lowered ifmap represents one patch (1 patch = 1 output) of the 3D convolution
    for row in range(lowered_ifmap_H):
        # ex. pixel_num_start = 0
        #    ifmap
        #  /patch\                                 filter
        # [|0<  1|  2                             [0,0  0,1
        #  |3   4|  5                              1,0  1,1]
        #   6   7   8]
        pixel_num_start = pixel_row*Wi + pixel_col
        pixel_num = pixel_num_start
        filter_row = 0
        filter_col = 0
        # Each col of the lowered ifmap represents a pixel in the patch
        for col in range(0, lowered_ifmap_W, Ci):
            address = pixel_num * Ci
            # Move all channels of one pixel
            lowered_ifmap[row][col:col+Ci] = ifmap_vec[address:address+Ci]

            # Update pixel num 
            # ex. pixel_num = 0->1->3->4
            if(filter_col == Wf - 1):
                filter_col = 0
                filter_row += 1
                pixel_num = pixel_num_start + filter_row*Wi
            else:
                filter_col += 1
                pixel_num += 1

        # Get the top left pixel row and col for the next convolution
        output_col += 1
        if(output_col == Wo):
            pixel_row += stride
            pixel_col = 0
            output_col = 0
        else:
            pixel_col += stride
        base_pixel_address = (pixel_row*Wi + pixel_col) * Ci
    
    ########################
    # Lowering the filters #
    ########################

    # Rotate the matrix so that the assignment is nicer
    lowered_filters = np.transpose(lowered_filters)
    for filt in range(lowered_filters_W):
        base_address = filt*lowered_filters_H
        end_adress = base_address + lowered_filters_H
        lowered_filters[filt][:] = filters_vec[base_address:end_adress]
    # Undo rotation
    lowered_filters = np.transpose(lowered_filters)

    if options.human_readable:
        txt_file.write(('#'*30) + '\n'  + 'Lowered IFMAP:\n')
        print_2D_matrix_str(txt_file, lowered_ifmap)
        txt_file.write('\n')
        txt_file.write(('#'*30) + '\n' + 'Lowered FILTERS:\n')
        print_2D_matrix_str(txt_file, lowered_filters)
        txt_file.write('\n')
    else:
        txt_file.write(('#'*30) + '\n'  + 'Lowered IFMAP:\n')
        print_2D_matrix(txt_file, lowered_ifmap)
        txt_file.write('\n')
        txt_file.write(('#'*30) + '\n'  + 'Lowered FILTERS:\n')
        print_2D_matrix(txt_file, lowered_filters)
        txt_file.write('\n')

    ########################
    #  Convolve and Check  #
    ########################

    if not options.human_readable:
        # Do a 3D convolution on our inputs and get a golden result
        golden_result = np.empty((options.filters, Ho, Wo), dtype=np.int8)
        for filtr in range(options.filters):
            golden_result[filtr] = convolve_3D(ifmap, filters[filtr])

        # Do matmult with my lowered matrices
        result = np.matmul(lowered_ifmap, lowered_filters)

        # Check that everything is correct
        result = np.transpose(result)
        result_vec = golden_result.ravel()
        golden_result_vec = golden_result.ravel()
        for idx in range(Ho * Wo * options.filters):
            if (result_vec[idx] != golden_result_vec[idx]):
                print(f"IM2COL FAILED AT IDX: {idx}")
        result = np.transpose(result)
    

        # Write outputs
        txt_file.write(('#'*30) + '\n'  + 'Matmult Output:\n')
        print_2D_matrix(txt_file, result)
        txt_file.write('\n')
        txt_file.write(('#'*30) + '\n'  + '3D Convolution Output:\n')
        print_3D_matrix_CHW(txt_file, golden_result)
        txt_file.write('\n')


    
def main(options):
    np.random.seed(options.seed)
    if options.human_readable:
        mat_ifmap = mat_gen_3D(options.ifmap_rows, options.ifmap_cols, options.channels)
        mat_filters = mat_gen_4D(options.filters_rows, options.filters_cols, options.channels, options.filters)
    else:
        mat_ifmap = rand_mat_gen_3D(options.ifmap_rows, options.ifmap_cols, options.channels, options.lower_bound, options.upper_bound)
        mat_filters = rand_mat_gen_4D(options.filters_rows, options.filters_cols, options.channels, options.filters, options.lower_bound, options.upper_bound)
    im2col(mat_ifmap, mat_filters, options)

if __name__ == "__main__":


    parser = argparse.ArgumentParser(
                        prog='im2col.py',
                        description='goldenbrick im2col algorithm',
                        epilog='teehee')

    parser.add_argument('-i_r', '--ifmap_rows', type=int, default=3)     # rows in activations
    parser.add_argument('-i_c', '--ifmap_cols', type=int, default=3)     # cols in activations
    parser.add_argument('-f_r', '--filters_rows', type=int, default=2)     # rows in filter
    parser.add_argument('-f_c', '--filters_cols', type=int, default=2)     # cols in filter
    parser.add_argument('-f_n', '--filters', type=int, default=2)       # number of filters
    parser.add_argument('-c', '--channels', type=int, default=3)      # input channels
    parser.add_argument('-str', '--stride', type=int, default=1)      # stride for matrix convolution

    parser.add_argument('-l', '--lower_bound', type=int, default=-2)    # lower bound of values
    parser.add_argument('-u', '--upper_bound', type=int, default=2)     # upper bound of values
    parser.add_argument('-s', '--seed', type=int, default=42)             # random values seed
    parser.add_argument('-hr', '--human_readable', action='store_true')   # make it so that humans can read it

    parser.add_argument('-v', '--verbose',                          # verbose output
                        action='store_true')

    parser.add_argument('-prehex', '--pre_hex_filename',        # name of hex output file
                        type=str, default='pre_im2col.hex')
    parser.add_argument('-posthex', '--post_hex_filename',        # name of hex output file
                        type=str, default='post_im2col.hex')

    parser.add_argument('-txt', '--txt_filename',        # name of txt output file
                        type=str, default='imm2col.txt')


    options = parser.parse_args()

    main(options)
