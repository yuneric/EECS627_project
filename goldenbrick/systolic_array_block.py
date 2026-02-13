import numpy as np
import argparse
import sys
import os
import copy

# Add the common script to our path so we can get some epic func's
script_dir = os.path.dirname(__file__) 
scripts_path = os.path.join(script_dir, '../common') 
sys.path.append(scripts_path) 

from matgen import *
from systolic_array import SystolicArrayGolden
from accum_buf import configurable_fifo

# Delay buffer for a signal
class delay_buf:
    def __init__(self, max_delay):
        self.size = max_delay
        self.delay_buf = np.zeros((max_delay))

    def delay(self, val):
        output = self.delay_buf[-1]
        self.delay_buf[1:] = self.delay_buf[:-1]
        self.delay_buf[0] = val
        return output

# Skew buffer for systolic array
class skew_buf:
    def __init__(self, max_delay):
        self.size = max_delay
        self.delay_buf = np.zeros((max_delay, max_delay))

    def skew(self, input_col):
        output_col = np.zeros((self.size))
        for idx in range(self.size):
            output_col[idx] = self.delay_buf[idx][idx]
        self.delay_buf[:, 1:] = self.delay_buf[:, :-1]
        self.delay_buf[:, 0] = input_col
        return output_col

    def skew_alt(self, input_col):
        output_col = np.zeros((self.size))
        for idx in range(self.size):
            output_col[idx] = self.delay_buf[self.size - 1 - idx][idx]
        self.delay_buf[:, 1:] = self.delay_buf[:, :-1]
        self.delay_buf[:, 0] = input_col
        return output_col

# Systolic array with the buffering we desire so deeply
class systolic_array_frontend:
    """
    Cycle-Accurate Weight-Stationary Model with delay and weight loading
    """
    def __init__(self, SA_dim, input_fifo_depth, weight_fifo_depth, accum_buf_depth):
        self.SA_dim = SA_dim
        self.accum_buf_depth = accum_buf_depth  
        self.SA = SystolicArrayGolden(SA_dim, SA_dim)                           # Our systolic array :D
        self.input_buffer = configurable_fifo(input_fifo_depth, SA_dim)         # Input buffer, likely a async fifo in practice
        self.weight_buffer = configurable_fifo(weight_fifo_depth, SA_dim)       # Weight buffer, likely a async fifo
        self.accum_buffer_writing = np.zeros((self.accum_buf_depth, self.SA_dim))         # The accumulator buffer that is being written
        self.accum_buffer_reading = np.zeros((self.accum_buf_depth, self.SA_dim))         # The accumulator buffer that is being read
        self.input_skew = skew_buf((SA_dim))                                    # Buffer to skew data into the SA
        self.output_skew = skew_buf((SA_dim))                                   # Data skew out to realign SA data

        self.en_accum_delay_buf = delay_buf((1 + 2 + self.SA_dim + self.SA_dim))    # Need this so that the accumulator buffer only enables when theres actually data

        self.reset()

    def reset(self):
        self.SA.reset()
        self.input_buffer.reset()
        self.weight_buffer.reset()
        self.accum_addr = 0
        self.accum_buffer_writing = np.zeros((self.accum_buf_depth, self.SA_dim))
        self.accum_buffer_reading = np.zeros((self.accum_buf_depth, self.SA_dim))

        self.accum_buffer_primed = False
        self.accum_buffer_en     = 0
        self.delay_buf_input     = 0
        self.accum_buffer_sel    = 0

        self.partial_sum        = np.zeros(self.SA_dim) # (partial_sum) Reg that sits between SA skew and accum buffer
        self.array_output       = np.zeros(self.SA_dim) # (array_output) Reg that sits between SA and SA output skew
        self.array_input        = np.zeros(self.SA_dim) # (array_input) Reg that sits between SA input skew and SA
        self.skew_input         = np.zeros(self.SA_dim) # (skew_input) Reg that sits between SA and SA skew
          
        self.old_partial_sum    = 0

    def load_weight_row(self, row_idx):
        self.SA.weights[row_idx] = self.weight_buffer.read()

    def write_input_buffer(self, val):
        self.input_buffer.write(val)

    def write_weight_buffer(self, val):
        self.weight_buffer.write(val)

    def read_accum_buffer(self, addr):
        #return self.accum_buffer_done.read()
        return self.accum_buffer_reading[addr]

    def switch_accum_buffer(self):
        # Just switch the pointers
        tmp = self.accum_buffer_reading
        self.accum_buffer_reading = self.accum_buffer_writing
        self.accum_buffer_writing = tmp

    def step(self):
        # Accumulator buffer
        if(self.accum_buffer_en):
            # Only start doing reads and writes when data is available
            if(self.accum_buffer_primed):
                    self.accum_buffer_writing[self.accum_addr] = self.accum_buffer_reading[self.accum_addr] + self.partial_sum
                    self.accum_addr += 1
            else:
                # Wait til its full (primed) atleast once to start reading
                self.accum_buffer_writing[self.accum_addr] = self.partial_sum
                self.accum_addr += 1
            if(self.accum_addr == self.accum_buffer_writing.shape[0]):
                self.accum_buffer_primed = True
                self.accum_addr = 0
                self.switch_accum_buffer()
        self.accum_buffer_en = self.en_accum_delay_buf.delay(self.delay_buf_input) # (accum_buffer_en) Has to arrive at the same time as partial sum

        # Pipelined stages
        self.partial_sum = self.output_skew.skew_alt(self.array_output) # output data skew realignment
        self.array_output = self.SA.step(self.array_input)              # systolic array
        self.array_input = self.input_skew.skew(self.skew_input)        # input data skew
        if(not self.input_buffer.empty()):                              # input buffer data
            self.delay_buf_input = 1
            self.skew_input = self.input_buffer.read()
        else:
            self.delay_buf_input = 0
            self.skew_input = np.zeros((self.SA_dim))

class systolic_array_backend:
    def __init__(self,  channels, output_val_bits, input_dim):
        self.channels = channels   # Number of channels in the input
        self.input_dim = input_dim # H/W of input matrices in each channel

        # Assuming twos complement
        self.output_val_bits = output_val_bits # Number of bits that should be in the output
        self.output_upper_bound = 2**(output_val_bits-1) - 1
        self.output_lower_bound = -(2**(output_val_bits-1))

        self.reset()

    def reset(self):
        self.relu_en = 0
        self.shift_val = 0
        self.maxpool_en = 0

        self.relu_input = np.zeros((self.channels))
        self.scale_clip_output = np.zeros((self.channels))

        # Setup maxpool
        self.maxpool_output = np.zeros((self.channels))
        self.maxpool_valid_out = 0
        self.maxpool_ready_in = 0
        self.valid_data_in = np.zeros((3))
        self.reset_maxpool()

        # Output data buffer
        self.write_addr = 0
        self.output_sram = np.zeros((self.input_dim**2, self.channels))

    def reset_maxpool(self):
        self.input_pixel = 0
        self.fill_line_buf = 0
        self.done_fill = 0
        self.stream_output = 0
        self.stream_output_pixel = 0
        self.input_line_buffer0 = np.zeros((self.input_dim, self.channels))
        self.input_line_buffer1 = np.zeros((self.input_dim, self.channels))
        self.output_line_buffer0 = np.zeros((self.input_dim//2, self.channels))
        self.output_line_buffer1 = np.zeros((self.input_dim//2, self.channels))
        self.output_line_buffer_final = np.zeros((self.input_dim//2, self.channels))

    # Sets the window of the output that we want
    def set_window(self, shift_val):
        self.shift_val = shift_val

    def relu(self, word):
        output = word
        # Pass through if not enabled
        if(self.relu_en):
            output = np.zeros((self.channels))
            for idx in range(self.channels):
                if(word[idx] < 0):
                    output[idx] = 0
                else:
                    output[idx] = word[idx]
        return output

    # Scales the value to the window then clamps the output
    def scale_and_clip(self, input_word):
        output = np.zeros((self.channels))
        for idx in range(self.channels):
            # Scale
            big_val = input_word[idx]
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
    
    # Support k = 2, s = 2 maxpool
    def enable_maxpool(self):
        self.reset()
        self.maxpool_en = 1

    def disable_maxpool(self):
        self.maxpool_en = 0

    def maxpool(self, input_word, valid_data=1):
        #print(f'input_pixel : {self.input_pixel} fill_input_line_buf: {self.fill_line_buf} | done_fill : {self.done_fill} | stream_output: {self.stream_output} |')
        output = input_word
        valid_out = 0 # is the current output valid?

        # Pass through if not enabled
        if(self.maxpool_en):
            if(self.stream_output == 0):
                if(self.done_fill == 0):
                    if(valid_data == 0):
                        # Do nothing
                        return None, valid_out
                    if(self.fill_line_buf == 0):
                        self.input_line_buffer0[self.input_pixel] = input_word
                        self.input_pixel += 1
                        if(self.input_pixel == self.input_dim):
                            self.input_pixel = 0
                            self.fill_line_buf = 1
                    else:
                        self.input_line_buffer1[self.input_pixel] = input_word
                        self.input_pixel += 1
                        if(self.input_pixel == self.input_dim):
                            self.input_pixel = 0
                            self.fill_line_buf = 0
                            self.done_fill = 1
                else:
                    # Do the maxpool
                    for pixel in range(self.output_line_buffer0.shape[0]):
                        for channel in range(self.channels):
                            self.output_line_buffer0[pixel][channel] = max(self.input_line_buffer0[pixel*2][channel], self.input_line_buffer0[(pixel*2)+1][channel])
                            self.output_line_buffer1[pixel][channel] = max(self.input_line_buffer1[pixel*2][channel], self.input_line_buffer1[(pixel*2)+1][channel])
                            self.output_line_buffer_final[pixel][channel] = max(self.output_line_buffer0[pixel][channel], self.output_line_buffer1[pixel][channel])
                    self.stream_output = 1
            else:
                output = self.output_line_buffer_final[self.stream_output_pixel]
                valid_out = 1
                self.stream_output_pixel += 1
                if(self.stream_output_pixel == self.input_dim//2):
                    self.reset_maxpool()
        
        return output, valid_out
    
    # def maxpool(self, input_word):
    #     #print(f'input_pixel : {self.input_pixel} fill_input_line_buf: {self.fill_line_buf} | done_fill : {self.done_fill} | stream_output: {self.stream_output} |')
    #     output = input_word

    #     # Pass through if not enabled
    #     if(self.maxpool_en):
    #         if(self.stream_output == 0):
    #             if(self.done_fill == 0):
    #                 if(self.fill_line_buf == 0):
    #                     self.input_line_buffer0[self.input_pixel] = input_word
    #                     self.input_pixel += 1
    #                     if(self.input_pixel == self.input_dim):
    #                         self.input_pixel = 0
    #                         self.fill_line_buf = 1
    #                 else:
    #                     self.input_line_buffer1[self.input_pixel] = input_word
    #                     self.input_pixel += 1
    #                     if(self.input_pixel == self.input_dim):
    #                         self.input_pixel = 0
    #                         self.fill_line_buf = 0
    #                         self.done_fill = 1
    #             else:
    #                 # Do the maxpool
    #                 for pixel in range(self.output_line_buffer0.shape[0]):
    #                     for channel in range(self.channels):
    #                         self.output_line_buffer0[pixel][channel] = max(self.input_line_buffer0[pixel*2][channel], self.input_line_buffer0[(pixel*2)+1][channel])
    #                         self.output_line_buffer1[pixel][channel] = max(self.input_line_buffer1[pixel*2][channel], self.input_line_buffer1[(pixel*2)+1][channel])
    #                         self.output_line_buffer_final[pixel][channel] = max(self.output_line_buffer0[pixel][channel], self.output_line_buffer1[pixel][channel])
    #                 self.stream_output = 1
    #         else:
    #             output = self.output_line_buffer_final[self.stream_output_pixel]
    #             self.stream_output_pixel += 1
    #             if(self.stream_output_pixel == self.input_dim//2):
    #                 self.reset_maxpool()
    #     return output

    # For testing purposes
    def run_maxpool(self, arr):
        row_length = self.input_dim
        num_inputs_for_maxpool = self.input_dim * 2
        num_output_rows = (self.input_dim//2)**2
        output_pixels_per_group = self.input_dim//2
        groups = self.input_dim//2

        output_arr = np.zeros((num_output_rows, self.channels))

        for group in range(groups):
            # Load in self.input_dim*2 inputs
            for input_num in range(num_inputs_for_maxpool):
                #self.maxpool(arr[input_num + group*num_inputs_for_maxpool])
                self.maxpool(arr[input_num + group*num_inputs_for_maxpool], 1)

            # Calculation step
            #self.maxpool(None)
            self.maxpool(None, 0)

            # Now we will have self.input_dim//2 outputs
            for output in range(output_pixels_per_group):
                # output_arr[output + group*output_pixels_per_group] = self.maxpool(None)
                output_arr[output + group*output_pixels_per_group], tmp = self.maxpool(None, 0)
        
        return output_arr

    def read_output_sram(self, addr):
        return self.output_sram[addr]
    
    def step(input_word, input_valid):
        # Pipeline
        # Output SRAM
        if(self.maxpool_valid_out == 1):
            self.output_sram[write_addr] = self.maxpool_output
            write_addr += 1
        
        # Maxpool
        self.valid_data_in[2] = self.valid_data_in[1]
        self.maxpool_output, self.maxpool_valid_out = self.maxpool(scale_clip_output, self.maxpool_valid_data_in[2])
        
        # Scale and Clip
        self.valid_data_in[1] = self.valid_data_in[0]
        self.scale_clip_output = self.scale_and_clip(relu_output)
        
        # Relu
        self.valid_data_in[0] = input_valid
        self.relu_output = self.relu(input_word)

def test_frontend(options):
    # TEST FRONTEND
    # INITIALIZE
    test_inputs = np.zeros((options.systolic_array_dim, options.systolic_array_dim))
    for row in range(test_inputs.shape[0]):
        test_inputs[row][:] = row + 1
    test_weights =  np.zeros((options.systolic_array_dim, options.systolic_array_dim)) + 1
    golden_output = np.matmul(test_inputs, test_weights)

    SA_fe = systolic_array_frontend(options.systolic_array_dim, options.input_buffer_depth, options.weight_buffer_depth, options.accum_buffer_depth)
    SA_fe.reset()

    # WRITE THE WEIGHT BUFFER
    for row in range(options.systolic_array_dim):
        SA_fe.write_weight_buffer(copy.deepcopy(test_weights[row]))

    # LOAD THE WEIGHTS INTO THE ARRAY
    for row in range(options.systolic_array_dim):
        SA_fe.load_weight_row(row)

    # NUM CYCLES TO RUN
    num_cycles = 50

    # LOAD SOME DATA TWICE
    for data_idx in range(options.systolic_array_dim):
        new_row = test_inputs[data_idx]
        SA_fe.write_input_buffer(new_row)

    for data_idx in range(options.systolic_array_dim):
        new_row = test_inputs[data_idx]
        SA_fe.write_input_buffer(new_row)

    # RUN THE BLOCK
    print('cycle | skew_input | array_input | array_output | accum_buffer_en | partial_sum')
    for cycle in range(num_cycles):
        print(f'{cycle} | {SA_fe.skew_input} | {SA_fe.array_input} | {SA_fe.array_output} | {SA_fe.accum_buffer_en} | {SA_fe.partial_sum}')
        SA_fe.step()

    output_mat = np.zeros((options.systolic_array_dim, options.systolic_array_dim))

    # # WRITE SOME NEW INPUTS
    # for row in range(options.accum_buffer_depth*2):
    #     new_row = np.zeros((options.systolic_array_dim)) + 1
    #     SA_fe.write_input_buffer(new_row)

    # # RUN THE BLOCK
    # for cycle in range(num_cycles):
    #     print(f'{cycle} | {SA_fe.skew_input} | {SA_fe.array_input} | {SA_fe.array_output} | {SA_fe.accum_buffer_en} | {SA_fe.partial_sum}')
    #     SA_fe.step()
        
    # READ THE OUTPUT FROM BUF
    for row in range(options.systolic_array_dim):
        output_mat[row] = SA_fe.read_accum_buffer(row)

    # CHECK FOR CORRECTNESS
    for row in range(golden_output.shape[0]):
        for col in range(golden_output.shape[1]):
            # Mult by two since we ran it twice
            if(output_mat[row][col] != golden_output[row][col]*2):
                print('ERROR: first test failed')

    # # SWITCH ACCUM BUFFERS
    # SA_fe.switch_accum_buffer()

    # # READ THE OUTPUT FROM BUF 2
    # for row in range(options.systolic_array_dim):
    #     output_mat[row] = SA_fe.read_accum_buffer(row)

    print(output_mat)

def test_backend(options):
    
    # TEST BACKEND
    # TEST RELU, SCALING AND SHIFTING
    SA_be = systolic_array_backend(8, 8, 8)

    test = np.zeros(8) + 256
    print(test)
    print(SA_be.relu(test))
    print(SA_be.scale_and_clip(test))

    test = np.zeros(8) - 256
    print(test)
    print(SA_be.relu(test))
    print(SA_be.scale_and_clip(test))

    SA_be.set_window(4)
    test = np.zeros(8) + 256
    print(test)
    print(SA_be.scale_and_clip(test))

    test = np.zeros(8) - 256
    print(test)
    print(SA_be.scale_and_clip(test))

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
        output[row], tmp = SA_be.maxpool(test_arr[row])
    
    print(f'input:\n{test_arr}')
    print(f'output:\n{output}')

    # test maxpool 2x2x4 -> 1x1x4
    print('testing 2x2x4 -> 1x1x4')
    SA_be.enable_maxpool()
    result = SA_be.run_maxpool(test_arr)
    print(f'result:\n{result}')

    # TEST 2
    # test maxpool 4x4x4 -> 2x2x4
    print('testing 4x4x4 -> 2x2x4')
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

def convert3d_2d(arr):
    rows, cols, channels = arr.shape
    return arr.reshape(rows*cols, channels)
    

def main(options):
    print('############ TESTING FRONTEND #############')
    test_frontend(options)
    #print('############ TESTING BACKEND #############')
    #test_backend(options)


if __name__ == "__main__":

    parser = argparse.ArgumentParser(
                        prog='systolic_array_block.py',
                        description='goldenbrick for the systolic array blocks',
                        epilog='teehee')

    parser.add_argument('-sa_dim', '--systolic_array_dim', type=int, default=8) 
    parser.add_argument('-in_buf', '--input_buffer_depth', type=int, default=16) 
    parser.add_argument('-w_buf', '--weight_buffer_depth', type=int, default=16) 
    parser.add_argument('-acc_buf', '--accum_buffer_depth', type=int, default=8) 


    options = parser.parse_args()

    main(options)
