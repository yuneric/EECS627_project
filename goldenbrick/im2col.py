import numpy as np
import argparse
import sys
import os
import math
import copy

# Add the common script to our path so we can get some epic func's
script_dir = os.path.dirname(__file__) 
scripts_path = os.path.join(script_dir, '../common') 
sys.path.append(scripts_path) 

from matgen import *
from systolic_array import SystolicArrayGolden
from accum_buf import accum_buf

def im2col(ifmap, filters, options):
    txt_file = open(options.txt_filename, 'w')
    if options.human_readable:
        txt_file.write(('#'*30) + '\n'  + 'IFMAP:\n')
        print_3D_matrix_str(txt_file, ifmap)
        print_mem(txt_file, ifmap)

        txt_file.write(('#'*30) + '\n' + 'FILTERS:\n')
        print_4D_matrix_str(txt_file, filters)
        print_mem(txt_file, filters)
    else:
        txt_file.write(('#'*30) + '\n'  + 'IFMAP:\n')
        print_3D_matrix(txt_file, ifmap)
        print_mem(txt_file, ifmap)

        txt_file.write(('#'*30) + '\n'  + 'FILTERS:\n')
        print_4D_matrix(txt_file, filters)
        print_mem(txt_file, filters)


        # Write the input hex files
        hex_file = open("ifmap_" + options.pre_hex_filename, 'w')
        write_hex_3D(ifmap, hex_file)
        hex_file.close()
        hex_file = open("filters_" + options.pre_hex_filename, 'w')
        write_hex_3D(filters, hex_file)
        hex_file.close()


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
        print_mem(txt_file, lowered_ifmap)
        txt_file.write(('#'*30) + '\n' + 'Lowered FILTERS:\n')
        print_2D_matrix_str(txt_file, lowered_filters)
        print_mem(txt_file, lowered_filters.transpose())
    else:
        txt_file.write(('#'*30) + '\n'  + 'Lowered IFMAP:\n')
        print_2D_matrix(txt_file, lowered_ifmap)
        print_mem(txt_file, lowered_ifmap)
        txt_file.write(('#'*30) + '\n'  + 'Lowered FILTERS:\n')
        print_2D_matrix(txt_file, lowered_filters)
        print_mem(txt_file, lowered_filters.transpose())

    ########################
    #  Convolve and Check  #
    ########################

    if not options.human_readable:
        # Do a 3D convolution on our inputs and get a golden result
        golden_result = np.empty((options.filters, Ho, Wo), dtype=np.int8)
        for filtr in range(options.filters):
            golden_result[filtr] = convolve_3D(ifmap, filters[filtr], options.stride)

        # Do matmult with my lowered matrices
        result = np.matmul(lowered_ifmap, lowered_filters)

        # Check that everything is correct
        result = np.transpose(result)
        result_vec = result.ravel()
        golden_result_vec = golden_result.ravel()
        for idx in range(Ho * Wo * options.filters):
            if (result_vec[idx] != golden_result_vec[idx]):
                print(f"IM2COL FAILED AT IDX: {idx}")
        result = np.transpose(result)
    

        # Write outputs
        txt_file.write(('#'*30) + '\n'  + 'Matmult Output:\n')
        print_2D_matrix(txt_file, result)
        print_mem(txt_file, result.transpose())

        txt_file.write(('#'*30) + '\n'  + '3D Convolution Output:\n')
        print_3D_matrix_CHW(txt_file, golden_result)
        print_mem(txt_file, golden_result)

        # Write the output hex files
        hex_file = open("ifmap_" + options.post_hex_filename, 'w')
        write_hex_3D(lowered_ifmap, hex_file)
        hex_file.close()

        hex_file = open("filters_" + options.post_hex_filename, 'w')
        write_hex_3D(lowered_filters.transpose(), hex_file)
        hex_file.close()

        # hex_file = open("output_" + options.post_hex_filename, 'w')
        # write_hex_3D(result.transpose(), hex_file)
        # hex_file.close()

    
    txt_file.close()

    return lowered_ifmap, lowered_filters

class im2col_engin:
    def __init__(self, ifmap, filters, stride, SA_dim, buf_dim):
        self.SA_dim = SA_dim
        self.word_size = SA_dim
        self.stride = stride

        # Systolic array
        self.systolic_array_shape = (SA_dim, SA_dim)
        self.systolic_array = SystolicArrayGolden(SA_dim, SA_dim)

        # Accumulation buffer
        if(buf_entries < SA_dim):
            print(f"ERROR: Buf entries < SA_dim")
            exit(0)
        self.buf_dim = buf_dim
        self.accum_buf = accum_buf(buf_dim**2, self.word_size)
        self.accum_buf.reset(buf_dim**2)

        self.init_mem(ifmap, filters)

    def init_mem(self, ifmap, filters):
        self.Hi = ifmap.shape[0] # height ifmap
        self.Wi = ifmap.shape[1] # width ifmap
        self.Ci = ifmap.shape[2] # input channels

        self.Nf = filters.shape[0]  # num filters
        self.Hf = filters.shape[1]  # height filters
        self.Wf = filters.shape[2]  # width filters

        self.Wo, self.Ho = calc_output_dim(self.Wi, self.Hi, self.Wf, self.Hf, self.stride)

        ifmap_1D = ifmap.ravel()
        filters_1D = filters.ravel()
        main_mem = np.concatenate((ifmap_1D, filters_1D))

        # Generate a memory layout of words of word_size (where word_size is the number of data elements)
        # Channels are padded with 0's if they dont fill the whole word
        word = [[] for _ in range(self.word_size)]
        self.mem = []
        word_idx = 0
        print(main_mem)
        for idx in range(main_mem.shape[0]):
            word[word_idx] = main_mem[idx]
            if(((idx + 1) % self.Ci) == 0):
                # Do zero padding
                zero_pad = self.word_size - word_idx - 1
                for zero_idx in range(zero_pad):
                    word[self.word_size - zero_idx - 1] = 0
                self.mem.append(copy.deepcopy(word))
                word_idx = 0
            elif(word_idx == self.word_size - 1):
                # Finished a word
                self.mem.append(copy.deepcopy(word))
                word_idx = 0
            else:
                word_idx += 1
        print(self.mem)
        
        self.channel_words = int(math.ceil(self.Ci / self.word_size))
        self.ifmap_base_address = 0
        self.filters_base_address = self.Hi * self.Wi * self.channel_words

    def run_im2col(self):
        weights = np.zeros(self.systolic_array_shape)
        # Outermost loop is the tiling of the output matrix
        for output_row in range(0, self.Ho, self.buf_dim):
            for output_col in range(0, self.Wo, self.buf_dim):
                
        # Load a channel of pixels for (SA_dim) filters
        
        


            


def main(options):
    np.random.seed(options.seed)
    if options.human_readable:
        mat_ifmap = mat_gen_3D(options.ifmap_rows, options.ifmap_cols, options.channels)
        mat_filters = mat_gen_4D(options.filters_rows, options.filters_cols, options.channels, options.filters)
    else:
        mat_ifmap = rand_mat_gen_3D(options.ifmap_rows, options.ifmap_cols, options.channels, options.lower_bound, options.upper_bound)
        mat_filters = rand_mat_gen_4D(options.filters_rows, options.filters_cols, options.channels, options.filters, options.lower_bound, options.upper_bound)

    im2col(mat_ifmap, mat_filters, options)
    im2col_obj = im2col_engin(mat_ifmap, mat_filters, options.stride, 4, 4*4)

if __name__ == "__main__":


    parser = argparse.ArgumentParser(
                        prog='im2col.py',
                        description='goldenbrick im2col algorithm',
                        epilog='teehee')

    parser.add_argument('-i_row', '--ifmap_rows', type=int, default=3)     # rows in activations
    parser.add_argument('-i_col', '--ifmap_cols', type=int, default=3)     # cols in activations
    parser.add_argument('-f_row', '--filters_rows', type=int, default=2)     # rows in filter
    parser.add_argument('-f_col', '--filters_cols', type=int, default=2)     # cols in filter
    parser.add_argument('-f_num', '--filters', type=int, default=2)       # number of filters
    parser.add_argument('-c', '--channels', type=int, default=3)      # input channels
    parser.add_argument('-str', '--stride', type=int, default=1)      # stride for matrix convolution
    # parser.add_argument('-word', '--word_size', type=int, default=8)      # word size for main mem

    parser.add_argument('-l', '--lower_bound', type=int, default=-2)    # lower bound of values
    parser.add_argument('-u', '--upper_bound', type=int, default=2)     # upper bound of values
    parser.add_argument('-s', '--seed', type=int, default=42)             # random values seed
    parser.add_argument('-hr', '--human_readable', action='store_true')   # make it so that humans can read it

    parser.add_argument('-v', '--verbose',                          # verbose output
                        action='store_true')

    parser.add_argument('-prehex', '--pre_hex_filename',        # name of hex output file
                        type=str, default='pre_im2col.hex')
    parser.add_argument('-posthex', '--post_hex_filename',      # name of hex output file
                        type=str, default='post_im2col.hex')

    parser.add_argument('-txt', '--txt_filename',               # name of txt output file
                        type=str, default='im2col.matrix.txt')


    options = parser.parse_args()

    main(options)
