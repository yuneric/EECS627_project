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

# systolic array with the buffering we desire so deeply
class systolic_array_buffered:
    """
    Cycle-Accurate Weight-Stationary Model with delay and weight loading
    """
    def __init__(self, SA_dim, input_fifo_depth, weight_fifo_depth, accum_buf_depth):
        self.SA_dim = SA_dim
        self.SA = SystolicArrayGolden(SA_dim, SA_dim)
        self.input_buffer = configurable_fifo(input_fifo_depth, SA_dim)
        self.weight_buffer = configurable_fifo(weight_fifo_depth, SA_dim)
        self.accum_buffer = configurable_fifo(accum_buf_depth, SA_dim)
        self.input_skew = skew_buf((SA_dim))
        self.output_skew = skew_buf((SA_dim))
        self.reset()

    def reset(self):
        self.SA.reset()
        self.input_buffer.reset()
        self.weight_buffer.reset()
        self.accum_buffer.reset()
        self.accum_buffer_count = 0
        self.accum_buffer_primed = False
        self.accum_buffer_en     = False
        self.partial_sum = np.zeros(self.SA_dim)
        self.new_partial_sum = np.zeros(self.SA_dim)
        self.old_partial_sum = np.zeros(self.SA_dim)
        self.array_output = np.zeros(self.SA_dim)
        self.array_input = np.zeros(self.SA_dim)
        self.skew_input = np.zeros(self.SA_dim)
        self.old_partial_sum = 0

    def load_weight_row(self, row_idx):
        self.SA.weights[row_idx] = self.weight_buffer.read()

    def write_input_buffer(self, val):
        self.input_buffer.write(val)

    def write_weight_buffer(self, val):
        self.weight_buffer.write(val)

    def read_accum_buffer(self):
        return self.accum_buffer.read()

    def accum_buffer_enable(self):
        self.accum_buffer_en = True

    def step(self):
        if(self.accum_buffer_en):
            self.new_partial_sum = self.old_partial_sum + self.partial_sum
            if(self.accum_buffer_primed):
                self.old_partial_sum = self.accum_buffer.read_write(self.new_partial_sum)
            else:
                self.accum_buffer.write(self.new_partial_sum)
                if(self.accum_buffer.full()):
                    self.accum_buffer_primed = True
                    self.old_partial_sum = self.accum_buffer.read()
        self.partial_sum = self.output_skew.skew_alt(self.array_output)
        self.array_output = self.SA.step(self.array_input)
        self.array_input = self.input_skew.skew(self.skew_input)
        if(not self.input_buffer.empty()):
            self.skew_input = self.input_buffer.read()
        else:
            self.skew_input = np.zeros((self.SA_dim))
        # print(self.skew_input)
        # print(self.array_input)
        # print(self.array_output)
        # print(self.partial_sum)

        

def main(options):
    test_inputs = np.zeros((options.systolic_array_dim, options.systolic_array_dim)) + 1
    test_weights =  np.zeros((options.systolic_array_dim, options.systolic_array_dim)) + 1

    golden_output = np.matmul(test_inputs, test_weights)

    SA_dut = systolic_array_buffered(options.systolic_array_dim, options.input_buffer_depth, options.weight_buffer_depth, options.accum_buffer_depth)

    SA_dut.reset()

    for row in range(options.systolic_array_dim):
        SA_dut.write_weight_buffer(copy.deepcopy(test_inputs[row]))

    for row in range(options.systolic_array_dim):
        SA_dut.load_weight_row(row)

    # inpute buf delay + skew delay + systolic array delay
    en_accum_cycle =    1 + \
                        options.systolic_array_dim  + \
                        1 + \
                        options.systolic_array_dim  + \
                        2 + \
                        1

    num_cycles =    50

    for data_idx in range(options.systolic_array_dim):
        new_row = test_inputs[data_idx] + data_idx
        SA_dut.write_input_buffer(new_row)

    for data_idx in range(options.systolic_array_dim):
        new_row = test_inputs[data_idx] + data_idx
        SA_dut.write_input_buffer(new_row)

    print('cycle | skew_input | array_input | array_output | partial_sum | old_partial_sum | new_partial_sum')
    for cycle in range(num_cycles):
        print(f'{cycle} | {SA_dut.skew_input} | {SA_dut.array_input} | {SA_dut.array_output} | {SA_dut.partial_sum} | {SA_dut.old_partial_sum} | {SA_dut.new_partial_sum}')
        if(cycle == en_accum_cycle):
            SA_dut.accum_buffer_enable()
        SA_dut.step()

    output_mat = np.zeros((options.systolic_array_dim, options.systolic_array_dim))

    for row in range(options.systolic_array_dim):
        output_mat[row] = SA_dut.read_accum_buffer()

    print(output_mat)
    
    


if __name__ == "__main__":

    parser = argparse.ArgumentParser(
                        prog='systolic_array_block.py',
                        description='goldenbrick for the systolic array blocks',
                        epilog='teehee')

    parser.add_argument('-sa_dim', '--systolic_array_dim', type=int, default=4) 
    parser.add_argument('-in_buf', '--input_buffer_depth', type=int, default=4) 
    parser.add_argument('-w_buf', '--weight_buffer_depth', type=int, default=4) 
    parser.add_argument('-acc_buf', '--accum_buffer_depth', type=int, default=4) 


    options = parser.parse_args()

    main(options)
