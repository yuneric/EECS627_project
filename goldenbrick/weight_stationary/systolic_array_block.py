import numpy as np
import argparse
import sys
import os
import copy

from systolic_array_block_be import systolic_array_backend
from systolic_array_block_fe import systolic_array_frontend

# The post processing for the systolic array
class systolic_array_block:
    def __init__(self,  input_dim, input_fifo_depth, weight_fifo_depth, accum_buf_dim):
        self.input_dim = input_dim # Size of systolic array, and width of basically everything
        self.input_fifo_depth = input_fifo_depth
        self.weight_fifo_depth = weight_fifo_depth
        self.accum_buf_dim = accum_buf_dim
        self.accum_buf_depth = accum_buf_dim**2
        self.reset()

    def reset(self):
        self.frontend = systolic_array_frontend(self.input_dim, self.input_fifo_depth, self.weight_fifo_depth, self.accum_buf_depth)
        self.backend = systolic_array_backend(self.input_dim, 8, self.accum_buf_dim)
        self.zero_input = np.zeros((self.input_dim))
        self.reading_accum_buffer = 0
        self.accum_rd_addr = 0

        self.frontend_done = 0

    # Sets the window of the output that we want
    def set_window(self, shift_val):
        self.backend.shift_val = shift_val

    # RELU!!!!!!!!!!!!!
    def enable_relu(self):
        self.backend.enable_relu()
    
    def disable_relu(self):
        self.backend.disable_relu()

    # Support k = 2, s = 2 maxpool
    def enable_maxpool(self):
        self.backend.enable_maxpool()

    def disable_maxpool(self):
        self.backend.disable_maxpool()

    def write_input_buffer(self, data, final_data):
        self.frontend.write_input_buffer(data, final_data)

    def write_weight_buffer(self, data):
        self.frontend.write_weight_buffer(data)

    def load_weight_row(self, row_idx):
        self.frontend.SA.weights[row_idx] = self.frontend.weight_buffer.read()

    def read_output_sram(self, addr):
        return self.backend.read_output_sram(addr)
    
    def step(self):
        if(self.frontend_done == 1 or self.reading_accum_buffer == 1):
            backend_input = self.frontend.read_accum_buffer(self.accum_rd_addr)
            self.reading_accum_buffer = 1
            self.accum_rd_addr += 1
            if(self.accum_rd_addr == self.frontend.accum_buf_depth):
                self.accum_rd_addr = 0
                self.reading_accum_buffer = 0

            backend_valid = 1
        else:
            backend_input = self.zero_input
            backend_valid = 0
    
        # Backend
        backend_done = self.backend.step(backend_input, backend_valid)

        # Frontend
        self.frontend_done = self.frontend.step()

        return backend_done


def make_test(test_num, num_mats, input_dim, input_fifo_depth, accum_buf_dim, relu, maxpool, scale, lower, upper):
    
    print(f'######## Test {test_num} #########')

    # SETUP TEST AND INPUTS AND SUCH
    # each input mat has enough rows to fill up the accum buf
    # num mats determines how many times we accumulate in the buffer
    accum_buf_depth = accum_buf_dim**2
    inputs = np.random.randint(lower, upper, (num_mats, accum_buf_depth, input_dim))

    weights = np.random.randint(lower, upper, (input_dim, input_dim))

    SA_block = systolic_array_block(input_dim, input_fifo_depth, input_dim, accum_buf_dim)

    SA_block.set_window(scale)
    if(maxpool):
        SA_block.enable_maxpool()
    if(relu):
        SA_block.enable_relu()

    # WRITE THE WEIGHT BUFFER
    for row in range(weights.shape[0]):
        SA_block.write_weight_buffer(weights[row])

    # LOAD THE WEIGHTS INTO THE ARRAY
    for row in range(weights.shape[0]):
        SA_block.load_weight_row(row)

    # RUN
    print('cycle | skew_input | array_input | array_output | accum_buffer_en | partial_sum | frontend_done | relu_output | scale_clip_output | maxpool_output | maxpool_valid_out | valid_data_in[1:0] | write_addr')
    num_inputs = inputs.shape[0]
    data_idx = 0
    done = 0
    mat_row = 0
    mat_num = 0
    final_mat = 0
    done_with_inputs = 0
    cycle = 0
    while(done == 0):
        print(f'{cycle} | {SA_block.frontend.skew_input} | {SA_block.frontend.array_input} | {SA_block.frontend.array_output} | {SA_block.frontend.accum_buffer_en} | {SA_block.frontend.partial_sum} | {SA_block.frontend_done} | {SA_block.backend.relu_output} | {SA_block.backend.scale_clip_output} | {SA_block.backend.maxpool_output} | {SA_block.backend.maxpool_valid_out} | {SA_block.backend.valid_data_in} | {SA_block.backend.write_addr}')
        done = SA_block.step()
        if(done_with_inputs == 0):
            if(final_mat == 0):
                SA_block.write_input_buffer(inputs[mat_num][row], 0)
                row += 1
                if(row == inputs.shape[1]):
                    mat_num += 1
                    if(mat_num == num_mats - 1):
                        final_mat = 1
                    row = 0
            else:
                if(row == inputs.shape[1] - 1):
                    SA_block.write_input_buffer(inputs[mat_num][row], 1)
                    done_with_inputs = 1
                else:
                    SA_block.write_input_buffer(inputs[mat_num][row], 0)
                row += 1
        cycle += 1
    print(f'{cycle} | {SA_block.frontend.skew_input} | {SA_block.frontend.array_input} | {SA_block.frontend.array_output} | {SA_block.frontend.accum_buffer_en} | {SA_block.frontend.partial_sum} | {SA_block.frontend_done} | {SA_block.backend.relu_output} | {SA_block.backend.scale_clip_output} | {SA_block.backend.maxpool_output} | {SA_block.backend.maxpool_valid_out} | {SA_block.backend.valid_data_in} | {SA_block.backend.write_addr}')


    # GET RESULT
    if(maxpool):
        num_output_rows = accum_buf_depth//4
    else:
        num_output_rows = accum_buf_depth
    result_arr = np.zeros((num_output_rows, input_dim))
    for output in range(num_output_rows):
        result_arr[output] = SA_block.backend.read_output_sram(output)

    # CALCULATE GOLDEN RESULT
    # golden_result = np.zeros((accum_buf_depth, accum_buf_depth, input_dim))
        
    # for mat in range(inputs.shape[0]):
    #     golden_result +=
    # for channel in range(channels):
    #     golden_result[:, :, channel] = maxpool2d(test_mat[:, :, channel])
        
    # golden_result_2d = convert3d_2d(golden_result)

    # if(relu):
    #     golden_result_2d[golden_result_2d<0] = 0

    # for entry in range(num_output_rows):
    #     golden_result_2d[entry] = SA_be.scale_and_clip(golden_result_2d[entry])

    # error = 0
    # for output in range(num_output_rows):
    #     for channel in range(channels):
    #         if(result_arr_2d[output][channel] != golden_result_2d[output][channel]):
    #             error = 1
    #             print('ERROR: doesnt match correct output')

    # if(error == 0):
    #     print('###### PASSED ######')
    # else:
    #     print(f'Input:\n{test_mat_2d}')
    #     print(f'Output:\n{result_arr_2d}')
    #     print(f'Correct Output:\n{golden_result_2d}')

    # return error
    
def main(options):
    print('############ TESTING BACKEND ##############')
    make_test(0, 5, 4, 4, 4, False, False, 0, -5, 5)


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
