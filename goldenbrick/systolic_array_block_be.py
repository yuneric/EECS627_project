import numpy as np
import argparse
import sys
import os
import copy

from fifo import configurable_fifo

# The post processing for the systolic array
class systolic_array_backend:
    def __init__(self,  dim, bits):
        self.dim = dim # H/W of systolic array

        # Assuming twos complement
        self.output_bits = bits # Number of bits that should be in the output
        self.output_upper_bound = 2**(self.output_bits-1) - 1
        self.output_lower_bound = -(2**(self.output_bits-1))

        self.reset()

    def reset(self):
        self.relu_en    = 0
        self.shift_val  = 0
        self.maxpool_en = 0

        # Setup pipeline
        self.relu_output       = np.zeros((self.dim))
        self.scale_clip_output = np.zeros((self.dim))
        self.maxpool_output    = np.zeros((self.dim))
        self.maxpool_valid_out = 0
        self.valid_data_in     = np.zeros((2))
        self.reset_maxpool()

        # Output data buffer
        self.output_fifo = configurable_fifo(self.dim, self.dim)

    def reset_maxpool(self):
        # Control signals 
        self.done_fill      = 0
        self.fill_line_buf  = 0
        self.stream_output  = 0

        # Counters
        self.input_pixel    = 0
        self.stream_output_pixel = 0

        # Line buffers
        self.input_line_buffer0       = np.zeros((self.dim, self.dim))
        self.input_line_buffer1       = np.zeros((self.dim, self.dim))
        self.output_line_buffer0      = np.zeros((self.dim//2, self.dim))
        self.output_line_buffer1      = np.zeros((self.dim//2, self.dim))
        self.output_line_buffer_final = np.zeros((self.dim//4, self.dim))

    # Sets the window of the output that we want
    def set_window(self, shift_val):
        self.shift_val = shift_val

    # If negative -> 0
    def relu(self, data):
        output = data
        # Pass through if not enabled
        if(self.relu_en):
            output = np.zeros((self.dim))
            for idx in range(self.dim):
                if(data[idx] < 0):
                    output[idx] = 0
                else:
                    output[idx] = data[idx]
        return output

    # Scales the value to the window then clamps the output
    def scale_and_clip(self, data):
        output = np.zeros((self.dim))
        for idx in range(self.dim):
            # Scale
            big_val = data[idx]
            truncated_val = (int(big_val) >> self.shift_val)

            # Clip
            out_val = truncated_val
            if(truncated_val > self.output_upper_bound):
                out_val = self.output_upper_bound
            elif(truncated_val < self.output_lower_bound):
                out_val = self.output_lower_bound
            output[idx] = out_val
        return output

    # RELU!!!!!!!!!!!!!
    def enable_relu(self):
        self.relu_en = 1
    
    def disable_relu(self):
        self.relu_en = 0

    # Support k = 2, s = 2 maxpool
    def enable_maxpool(self):
        self.reset_maxpool()
        # ex. want a 2x4 x 8 channels output
        self.num_output_writes = self.dim//4
        self.maxpool_en = 1

    def disable_maxpool(self):
        # ex. want a 1x2 8 channels output
        self.num_output_writes = self.dim
        self.maxpool_en = 0

    def maxpool_step(self, data, valid_data=1):
        #print(f'input_pixel : {self.input_pixel} fill_input_line_buf: {self.fill_line_buf} | done_fill : {self.done_fill} | stream_output: {self.stream_output} |')
        output = data # REMEMBER, EACH DATA CHUNK IS MULTIPLE CHANNELS OF ONE OUTPUT PIXEL
        valid_out = 0 # is the current output data valid?
        
        # Pass through if not enabled
        if(self.maxpool_en):
            # Supports filling buffers and exporting final buffer in the same cycle
            output = None

            # State machine for output
            if(self.stream_output == 1):
                # If maxpool is done, stream it out
                output = self.output_line_buffer_final[self.stream_output_pixel]
                valid_out = 1
                self.stream_output_pixel += 1
                if(self.stream_output_pixel == self.num_output_writes):
                    #self.reset_maxpool()
                    self.stream_output_pixel = 0
                    self.stream_output = 0
            # endif stream_output

            # State machine for filling line buffers and eventual maxpool
            if(self.done_fill == 1 and self.stream_output == 0):
                # If done filling buffers do the maxpool
                for pixel in range(self.output_line_buffer_final.shape[0]):
                    for channel in range(self.dim):
                        # Max adjacent (col) pixels
                        self.output_line_buffer0[pixel][channel] = max(self.input_line_buffer0[pixel*2][channel], self.input_line_buffer0[(pixel*2)+1][channel])
                        self.output_line_buffer1[pixel][channel] = max(self.input_line_buffer1[pixel*2][channel], self.input_line_buffer1[(pixel*2)+1][channel])
                        # Max pixels from different rows
                        self.output_line_buffer_final[pixel][channel] = max(self.output_line_buffer0[pixel][channel], self.output_line_buffer1[pixel][channel])
                self.stream_output = 1
                self.done_fill = 0
                # Can do the first pixel of the next row
                if(valid_data == 1):
                    self.input_line_buffer0[self.input_pixel] = data
                    self.input_pixel += 1
                    if(self.input_pixel == self.dim):
                        self.input_pixel = 0
                        self.fill_line_buf = 1
            else:
                # If not done filling the line buffers
                if(valid_data == 1):
                    if(self.fill_line_buf == 0):
                        self.input_line_buffer0[self.input_pixel] = data
                        self.input_pixel += 1
                        if(self.input_pixel == self.dim//2):
                            self.input_pixel = 0
                            self.fill_line_buf = 1
                    else:
                        self.input_line_buffer1[self.input_pixel] = data
                        self.input_pixel += 1
                        if(self.input_pixel == self.dim//2):
                            self.input_pixel = 0
                            self.fill_line_buf = 0
                            self.done_fill = 1
                    # endif fill_line_b_uf
                # endif valid_data
            # endif done_fill
        #endif maxpool_en
        else:
            valid_out = valid_data

        
        return output, valid_out

    # # For testing purposes
    # def run_maxpool(self, arr):
    #     row_length = self.dim
    #     num_inputs_for_maxpool = self.dim
    #     num_output_rows = (self.input_dim//2)**2
    #     output_pixels_per_group = self.input_dim//2
    #     groups = self.input_dim//2

    #     output_idx = 0
    #     output_arr = np.zeros((num_output_rows, self.channels))

    #     for group in range(groups):
    #         # Load in self.input_dim*2 inputs (step self.input_dim*2 times)
    #         for input_num in range(num_inputs_for_maxpool):
    #             # Output data is only valid when valid_out is high
    #             output_data, valid_out = self.maxpool_step(arr[input_num + group*num_inputs_for_maxpool], 1)
    #             if(valid_out == 1):
    #                 output_arr[output_idx] = output_data
    #                 output_idx += 1

    #     # Calculation step ( to actually perform maxpool on the last set of data)
    #     self.maxpool_step(None, 0)

    #     # Get the rest of the data
    #     for pixel in range(output_pixels_per_group):
    #         output_data, valid_out = self.maxpool_step(None, 0)
    #         if(valid_out == 1):
    #             output_arr[output_idx] = output_data
    #             output_idx += 1

    #     return output_arr

    # Method for getting data out of the output buffer
    def read_output_fifo(self):
        return self.output_fifo.read()

    def output_fifo_empty(self):
        return self.output_fifo.empty()
    
    # SIMULATES A SINGLE CYCLE
    def step(self, input_data, input_valid):
        # Pipeline
        # Output SRAM
        if(self.maxpool_valid_out == 1):
            self.output_fifo.write(self.maxpool_output)
        
        # Maxpool
        self.maxpool_output, self.maxpool_valid_out = self.maxpool_step(self.scale_clip_output, self.valid_data_in[1])
        
        # Scale and Clip
        self.valid_data_in[1] = self.valid_data_in[0]
        self.scale_clip_output = self.scale_and_clip(self.relu_output)
        
        # Relu
        self.valid_data_in[0] = input_valid
        if(input_valid == 1):
            self.relu_output = self.relu(input_data)
        else:
            self.relu_output = np.zeros(self.dim)

def test_relu(options):
    # TEST RELU, SCALING AND SHIFTING
    SA_be = systolic_array_backend(8, 8, 8)

    test = np.zeros(8) + 256
    SA_be.enable_relu()
    print(f'input: {test}')
    print(f'relu: {SA_be.relu(test)}')
    print(f'scale by 1 and clip {SA_be.scale_and_clip(test)}')

    test = np.zeros(8) - 256
    print(f'input: {test}')
    print(f'relu: {SA_be.relu(test)}')
    print(f'scale by 1 and clip {SA_be.scale_and_clip(test)}')

    SA_be.set_window(4)
    test = np.zeros(8) + 256
    print(f'input: {test}')
    print(f'scale by 4 and clip {SA_be.scale_and_clip(test)}')

    test = np.zeros(8) - 256
    print(f'input: {test}')
    print(f'scale by 4 and clip {SA_be.scale_and_clip(test)}')

def test_maxpool(options):
    # TEST MAXPOOL
    # TEST 1
    SA_be = systolic_array_backend(4, 8, 2)
    # each row is a pixel in the flattened output
    # each col is a channel of output
    # 2x2x4 input
    test_arr = np.array([[1, 1, 1, 1],
                         [2, 2, 2, 2],
                         [3, 3, 3, 3],
                         [4, 4, 4, 4]])
    # 1x1x4 output
    correct_output = np.array([4, 4, 4, 4])

    # test pass through
    print('testing passthrough')
    output = np.zeros((4,4))
    for row in range(test_arr.shape[0]):
        output[row], tmp = SA_be.maxpool_step(test_arr[row])
    
    print(f'input:\n{test_arr}')
    print(f'output:\n{output}')

    # test maxpool 2x2x4 -> 1x1x4
    print('testing 1 2x2x4 -> 1x1x4')
    SA_be.enable_maxpool()
    result = SA_be.run_maxpool(test_arr)
    print(f'result:\n{result}')

    # TEST 2
    # test maxpool 4x4x4 -> 2x2x4
    print('testing 2 4x4x4 -> 2x2x4')
    SA_be = systolic_array_backend(4, 8, 4)
    SA_be.enable_maxpool()
    test_arr = np.array([[0,  5, 2, 1],
                         [1, -1, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [2, -1, 2, 1],
                         [0,  6, 2, 1],
                         [3,  7, 2, 1],
                         [0,  6, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [0, -1, 2, 1],
                         [4,  8, 2, 1]])
    correct_output = np.array([ [1, 5, 2, 1],
                                [2, 6, 2, 1],
                                [3, 7, 2, 1],
                                [4, 8, 2, 1]])
    result = SA_be.run_maxpool(test_arr)
    print(f'input:\n{test_arr}')
    print(f'result:\n{result}')

    # TEST 3
    print('testing 3 4x4x4 -> 2x2x4')
    rows = 4
    cols = 4
    channels = 4
    test_mat = np.random.randint(0, 10, (rows, cols, channels))

    golden_result = np.zeros((rows//2, cols//2, channels))
    for channel in range(channels):
        golden_result[:, :, channel] = maxpool2d(test_mat[:, :, channel])
    golden_result_transformed = convert3d_2d(golden_result)

    SA_be = systolic_array_backend(channels, 8, rows)
    transformed_mat = convert3d_2d(test_mat)
    SA_be.enable_maxpool()
    result = SA_be.run_maxpool(transformed_mat)

    # print(test_mat)
    # print(transformed_mat)
    # print(golden_result_transformed)
    # print(result)
    for row in range(rows*cols//4):
        for channel in range(channels):
            if(result[row][channel] != golden_result_transformed[row][channel]):
                print('ERROR: doesnt match correct output')

    # TEST 4
    print('testing 4 16x16x8 -> 8x8x16')
    rows = 16
    cols = 16
    channels = 8
    test_mat = np.random.randint(0, 10, (rows, cols, channels))

    golden_result = np.zeros((rows//2, cols//2, channels))
    for channel in range(channels):
        golden_result[:, :, channel] = maxpool2d(test_mat[:, :, channel])
    golden_result_transformed = convert3d_2d(golden_result)

    SA_be = systolic_array_backend(channels, 8, rows)
    transformed_mat = convert3d_2d(test_mat)
    SA_be.enable_maxpool()
    result = SA_be.run_maxpool(transformed_mat)

    # print(test_mat)
    # print(transformed_mat)
    # print(golden_result_transformed)
    # print(result)
    for row in range(rows*cols//4):
        for channel in range(channels):
            if(result[row][channel] != golden_result_transformed[row][channel]):
                print('ERROR: doesnt match correct output')

def make_test(test_num, bits, relu, scale, lower, upper, num_cycles=20):
    
    print(f'######## Test {test_num} #########')

    rows = 2 
    cols = 4
    channels = 8
    test_mat = np.random.randint(lower, upper, (rows, cols, channels))

    SA_be = systolic_array_backend(8, bits)
    test_mat_2d = convert3d_2d(test_mat)
    num_inputs = test_mat_2d.shape[0]

    print('cycle | relu_output | scale_clip_output | maxpool_output | maxpool_valid_out | valid_data_in[1:0] | write_addr')
    data_idx = 0
    SA_be.enable_maxpool()
    SA_be.set_window(scale)
    if(relu):
        SA_be.enable_relu()

    for cycle in range(num_cycles):
        print(f'{cycle} | {SA_be.relu_output} | {SA_be.scale_clip_output} | {SA_be.maxpool_output} | {SA_be.maxpool_valid_out} | {SA_be.valid_data_in}')
        if(data_idx < num_inputs):
            SA_be.step(test_mat_2d[data_idx], 1)
            data_idx += 1
        else:
            SA_be.step(None, 0)
        cycle += 1
    print(f'{cycle} | {SA_be.relu_output} | {SA_be.scale_clip_output} | {SA_be.maxpool_output} | {SA_be.maxpool_valid_out} | {SA_be.valid_data_in}')

    num_output_rows = rows//2 * cols//2 
    result_arr_2d = np.zeros((num_output_rows, channels))
    for output in range(num_output_rows):
        result_arr_2d[output] = SA_be.read_output_fifo()

    golden_result = np.zeros((rows//2, cols//2, channels))
        
    for channel in range(channels):
        golden_result[:, :, channel] = maxpool2d(test_mat[:, :, channel])
        
    golden_result_2d = convert3d_2d(golden_result)

    if(relu):
        golden_result_2d[golden_result_2d<0] = 0

    for entry in range(num_output_rows):
        golden_result_2d[entry] = SA_be.scale_and_clip(golden_result_2d[entry])

    error = 0
    for output in range(num_output_rows):
        for channel in range(channels):
            if(result_arr_2d[output][channel] != golden_result_2d[output][channel]):
                error = 1
                print('ERROR: doesnt match correct output')

    
    if(error == 0):
        print('###### PASSED ######')
    else:
        print(f'Input:\n{test_mat_2d}')
        print(f'Output:\n{result_arr_2d}')
        print(f'Correct Output:\n{golden_result_2d}')

    return error

def make_test_no_max(test_num, dim, bits, relu, scale, lower, upper, num_cycles=20):
    
    print(f'######## Test {test_num} #########')

    # Test mat is output from systolic array
    test_mat = np.random.randint(lower, upper, (dim, dim))

    SA_be = systolic_array_backend(dim, bits)

    print('cycle | relu_output | scale_clip_output | maxpool_output | maxpool_valid_out | valid_data_in[1:0] | write_addr')
    SA_be.set_window(scale)
    if(relu):
        SA_be.enable_relu()

    data_row = 0
    cycle = 0
    num_rows = dim
    for cycle in range(num_cycles):
        print(f'{cycle} | {SA_be.relu_output} | {SA_be.scale_clip_output} | {SA_be.maxpool_output} | {SA_be.maxpool_valid_out} | {SA_be.valid_data_in}')
        if(data_row < num_rows):
            SA_be.step(test_mat[data_row], 1)
            data_row += 1
        else:
            SA_be.step(None, 0)
        cycle += 1
    print(f'{cycle} | {SA_be.relu_output} | {SA_be.scale_clip_output} | {SA_be.maxpool_output} | {SA_be.maxpool_valid_out} | {SA_be.valid_data_in}')

    num_output_rows = dim
    result_arr = np.zeros((dim, dim))
    for output in range(num_output_rows):
        result_arr[output] = SA_be.read_output_fifo()


    golden_result = test_mat

    if(relu):
        golden_result[golden_result<0] = 0

    for entry in range(num_output_rows):
        golden_result[entry] = SA_be.scale_and_clip(golden_result[entry])

    error = 0
    for row in range(num_output_rows):
        for channel in range(dim):
            if(result_arr[row][channel] != golden_result[row][channel]):
                error = 1
                print('ERROR: doesnt match correct output')

    if(error == 0):
        print('###### PASSED ######')
    else:
        print(f'Input:\n{test_mat}')
        print(f'Output:\n{result_arr}')
        print(f'Correct Output:\n{golden_result}')

    return error


def test_backend_cycle(options):
    num_failed = 0

    # No scaling needed
    num_failed += make_test(0, 8, False, 0, 0, 10)
    num_failed += make_test(1, 8, True,   0, 0, 10)
    num_failed += make_test(2, 8, False,  0, -10, 10)
    num_failed += make_test(3, 8, True,   0, -10, 10)

    # scaling needed
    num_failed += make_test(4, 8, False,  0, -1000, 1000)
    num_failed += make_test(5, 8, True,   0, -1000, 1000)


    # Test passthrough
    num_failed += make_test_no_max(6, 4, 8, False, 4, -1000, 1000)
    num_failed += make_test_no_max(7, 16, 8, False, 4, -1000, 1000)

    print(f'num_failed = {num_failed}')
     

def test_backend(options):
    # TEST BACKEND
    # test_relu(options)
    # test_maxpool(options)
    test_backend_cycle(options)
    
# Thanks gemini
def maxpool2d(input_array):
    """
    Performs a 2x2 maxpool with stride 2 on a 2D NumPy array.
    """
    h, w = input_array.shape
    
    # Ensure dimensions are even for a 2x2/s=2 pool
    # If odd, you'd typically pad or crop the array
    h_out, w_out = h // 2, w // 2
    
    # Reshape into (h_out, 2, w_out, 2)
    # This groups every 2x2 block into its own dimensions
    reshaped = input_array[:h_out*2, :w_out*2].reshape(h_out, 2, w_out, 2)
    
    # Take the max across the 2nd and 4th axes (the 2x2 blocks)
    return reshaped.max(axis=(1, 3))

# Use this to convert our mats from 3D H*W*C format to 2D HWC format
# Basically every channel (filter output) becomes its own column
def convert3d_2d(arr):
    rows, cols, channels = arr.shape
    return arr.reshape(rows*cols, channels)
    
def main(options):
    print('############ TESTING BACKEND ##############')
    test_backend(options)


if __name__ == "__main__":

    parser = argparse.ArgumentParser(
                        prog='systolic_array_block.py',
                        description='goldenbrick for the systolic array blocks',
                        epilog='teehee')

    # parser.add_argument('-sa_dim', '--systolic_array_dim', type=int, default=8) 
    # parser.add_argument('-in_buf', '--input_buffer_depth', type=int, default=16) 
    # parser.add_argument('-w_buf', '--weight_buffer_depth', type=int, default=16) 
    # parser.add_argument('-acc_buf', '--accum_buffer_depth', type=int, default=8) 


    options = parser.parse_args()

    main(options)
