import numpy as np
import argparse
import sys
import os
import copy

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

    print(f'Output: \n {output_mat}')
    
def main(options):
    print('############ TESTING FRONTEND #############')
    test_frontend(options)


if __name__ == "__main__":

    parser = argparse.ArgumentParser(
                        prog='systolic_array_block_fe.py',
                        description='goldenbrick for the systolic array block frontend',
                        epilog='teehee')

    parser.add_argument('-sa_dim', '--systolic_array_dim', type=int, default=8) 
    parser.add_argument('-in_buf', '--input_buffer_depth', type=int, default=16) 
    parser.add_argument('-w_buf', '--weight_buffer_depth', type=int, default=16) 
    parser.add_argument('-acc_buf', '--accum_buffer_depth', type=int, default=8) 


    options = parser.parse_args()

    main(options)
