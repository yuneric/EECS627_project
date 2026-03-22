import numpy as np
import argparse
import sys
import os
import copy

from systolic_array import SystolicArraySkewed
from fifo import configurable_fifo
from delay import delay_buf, skew_buf, serializer

# Systolic array with the buffering we desire so deeply
class systolic_array_frontend:
    """
    Cycle-Accurate output stationary with fifos
    """
    def __init__(self, dim, fifo_depth):
        self.dim = dim
        self.fifo_depth = fifo_depth
        self.array = SystolicArraySkewed(self.dim)                           # Our systolic array :D

        self.data_info_fifo = configurable_fifo(self.fifo_depth, 1)
        self.act_fifo = configurable_fifo(self.fifo_depth, self.dim)
        self.weight_fifo = configurable_fifo(self.fifo_depth, self.dim)

        self.act_serial_staged = []
        self.weight_serial_staged = []
        self.act_serializers = []
        self.weight_serializers = []
        for row in range(self.dim):
            self.act_serial_staged.append(np.zeros(self.dim))
            self.weight_serial_staged.append(np.zeros(self.dim))

            self.act_serializers.append(serializer(self.dim))
            self.weight_serializers.append(serializer(self.dim))

        self.reset()

    def reset(self):
        self.act_fifo.reset()
        self.weight_fifo.reset()
        for row in range(self.dim):
            self.act_serializers[row].reset()
            self.weight_serializers[row].reset()

        self.serializer_sel = 0
        self.data_cycles = self.dim
        self.data_staged = False
        self.flush_data = False
        self.output_cycles = 0


        self.needed_calc_cycles = 1 + 2 + self.dim * 2
        self.cycles_since_last_data = 0
        self.computation_done = False

        self.act_input = np.zeros(self.dim)
        self.weight_input = np.zeros(self.dim)

    def write_fifos(self, act_data, weight_data, data_info):
        self.act_fifo.write(act_data)
        self.weight_fifo.write(weight_data)
        self.data_info_fifo.write(data_info)

    # SIMULATES A SINGLE CYCLE
    def step(self):
        
        valid_out = 0
        if((self.flush_data) and (self.data_staged == 0) and (self.data_cycles == self.dim) and (self.computation_done)):
            #print('streaming output from array')
            output = self.array.step(self.act_input, self.weight_input, shift_out=1)
            valid_out = (self.output_cycles >= 1)
            self.output_cycles += 1
            if(self.output_cycles == self.dim + 1):
                self.output_cycles = 0
                self.flush_data = False
        else:
            #print('normal array function')
            output = self.array.step(self.act_input, self.weight_input, shift_out=0)

        # Need to know when the last bit of data is through
        if(not self.data_staged and (self.data_cycles == self.dim)):
            self.cycles_since_last_data += 1
            if(self.cycles_since_last_data >= self.needed_calc_cycles):
                self.computation_done = True
        else:
            self.cycles_since_last_data = 0
            self.computation_done = False

        # Serializer logic
        if(self.data_staged and (self.data_cycles == self.dim)):
            #print('staged data, loading it into serializers')
            # If the serializers are about to be empty and we have staged data, load it
            for row in range(self.dim):
                self.act_input[row] = self.act_serializers[row].step(shift=1, input_data=self.act_serial_staged[row], data_valid=1)
                self.weight_input[row] = self.weight_serializers[row].step(shift=1, input_data=self.weight_serial_staged[row], data_valid=1)
            self.data_staged = False # Data is not staged anymore
            self.data_cycles = 0     # Reset our data counter

        elif(not self.data_staged and (self.data_cycles == self.dim)):
            #print('no data')
            # We have no data
            for row in range(self.dim):
                self.act_input[row] = 0
                self.weight_input[row] = 0
            
        else:
            # Otherwise shift data out as normal and count how much data has been shifted out
            #print('shifting out')
            if(self.data_cycles < self.dim):
                self.data_cycles += 1
                for row in range(self.dim):
                    self.act_input[row] = self.act_serializers[row].step(shift=1, input_data=None, data_valid=0)
                    self.weight_input[row] = self.weight_serializers[row].step(shift=1, input_data=None, data_valid=0)
        
        # Data staging logic
        if((not self.act_fifo.empty()) and (not self.data_staged) and (not self.flush_data)):
            # Puts the data into our staging buffers for the serializers to keep them fed
            # Stop reading data if we need to flush
            #print('staging data')
            self.act_serial_staged[self.serializer_sel] = copy.deepcopy(self.act_fifo.read())
            self.weight_serial_staged[self.serializer_sel] = copy.deepcopy(self.weight_fifo.read())
            # If we have staged every row of data, reset for the next round
            self.serializer_sel += 1
            if(self.serializer_sel == self.dim):
                self.data_staged = True
                self.serializer_sel = 0
            # This determines if this is the last piece of data before we flush
            self.flush_data = self.data_info_fifo.read()[0]
        # else:
        #     # No ready data
        #     print('no ready data')
        #     #self.flush_data = 0
        
        return output, valid_out

def make_test(activations, weights, dim, fifo_depth, num_cycles=50):
    dut = systolic_array_frontend(dim, fifo_depth)
    print(f'Activations:\n{activations}')
    print(f'Weights:\n{weights}')
    
    data_idx = 0
    output_idx = 0
    output_arr = np.zeros((dim, dim))
    #print('cycle | left_input | top_input | dut.act_input | dut.weight_input | dut.flush_data | dut.data_staged')
    # print('sums')
    for cycle in range(num_cycles):
        left_input = np.zeros(dim)
        top_input = np.zeros(dim)
        data_info = False
        data, valid = dut.step()
        if(data_idx < dim and (not dut.act_fifo.full())):
            #print('WRITINGGGGGGGGGGG')
            left_input = activations[data_idx, :]
            top_input = weights[:, data_idx]
            data_idx += 1
            if(data_idx == dim):
                data_info = True
                #print('WRITINGGGGGGGGGGG LAST')
            dut.write_fifos(left_input, top_input, data_info)
        # print(f'{cycle} | {left_input} | {top_input} | {dut.act_input} | {dut.weight_input} | {dut.flush_data} | {dut.data_staged} | {dut.act_serial_staged} | {dut.weight_serial_staged}')
        # print(f'{cycle} | {left_input} | {top_input} | {dut.array.left_in} | {dut.array.top_in} | {dut.flush_data} | {dut.data_cycles} | {dut.output_cycles} | {dut.cycles_since_last_data} | {dut.needed_calc_cycles} | {dut.computation_done}')
        # print(dut.array.array.sum_v)
        if(valid == 1):
            output_arr[dim - 1 - output_idx] = data
            output_idx +=1

    # Check output
    golden_result = np.matmul(activations, weights)
    num_outputs = dim
    for row in range(num_outputs):
        for col in range(num_outputs):
            if(output_arr[row][col] != golden_result[row][col]):
                print("ERROR: Systolic array output doesn't match a matmult")
    print(f'Result:\n{output_arr}')
    print(f'Correct:\n{golden_result}')
    
# def make_tile_test(activations, weights, dim, fifo_depth, num_cycles=50):
#     dut = systolic_array_frontend(dim, fifo_depth)
#     act_shape = actications.shape
#     weight_shape = weights.shape
#     zero_padding_needed = act_shape[1] % dim
#     print(f'Activations:\n{activations}')
#     print(f'Weights:\n{weights}')
    
#     data_idx = 0
#     output_idx = 0
#     output_arr = np.zeros((dim, dim))
#     #print('cycle | left_input | top_input | dut.act_input | dut.weight_input | dut.flush_data | dut.data_staged')
#     # print('sums')
#     for cycle in range(num_cycles):
#         left_input = np.zeros(dim)
#         top_input = np.zeros(dim)
#         data_info = False
#         data, valid = dut.step()
#         if(data_idx < dim and (not dut.act_fifo.full())):
#             print('WRITINGGGGGGGGGGG')
#             left_input = activations[data_idx, :]
#             top_input = weights[:, data_idx]
#             data_idx += 1
#             if(data_idx == dim):
#                 data_info = True
#                 print('WRITINGGGGGGGGGGG LAST')
#             dut.write_fifos(left_input, top_input, data_info)
#         # print(f'{cycle} | {left_input} | {top_input} | {dut.act_input} | {dut.weight_input} | {dut.flush_data} | {dut.data_staged} | {dut.act_serial_staged} | {dut.weight_serial_staged}')
#         # print(f'{cycle} | {left_input} | {top_input} | {dut.array.left_in} | {dut.array.top_in} | {dut.flush_data} | {dut.data_cycles} | {dut.output_cycles} | {dut.cycles_since_last_data} | {dut.needed_calc_cycles} | {dut.computation_done}')
#         # print(dut.array.array.sum_v)
#         if(valid == 1):
#             output_arr[dim - 1 - output_idx] = data
#             output_idx +=1

#     # Check output
#     golden_result = np.matmul(activations, weights)
#     num_outputs = dim
#     for row in range(num_outputs):
#         for col in range(num_outputs):
#             if(output_arr[row][col] != golden_result[row][col]):
#                 print("ERROR: Systolic array output doesn't match a matmult")
#     print(f'Result:\n{output_arr}')
#     print(f'Correct:\n{golden_result}')

def main(options):
    print('############ TESTING FRONTEND #############')
    dim = 4
    fifo_depth = 4
    activations = np.array([[1, 1, 1, 1],
                            [2, 2, 2, 2],
                            [3, 3, 3, 3],
                            [4, 4, 4, 4]])
    weights = np.array([[1, 1, 1, 1],
                        [2, 2, 2, 2],
                        [3, 3, 3, 3],
                        [4, 4, 4, 4]])
    make_test(activations, weights, dim, fifo_depth)

    dim = 4
    fifo_depth = 4
    activations = np.random.randint(-4, 4, size=(dim, dim))     
    weights = np.random.randint(-4, 4, size=(dim, dim))
    make_test(activations, weights, dim, fifo_depth)

    dim = 8
    fifo_depth = 2
    activations = np.random.randint(-4, 4, size=(dim, dim))     
    weights = np.random.randint(-4, 4, size=(dim, dim))
    make_test(activations, weights, dim, fifo_depth)

if __name__ == "__main__":

    parser = argparse.ArgumentParser(
                        prog='systolic_array_block_fe.py',
                        description='goldenbrick for the systolic array block frontend',
                        epilog='teehee')

    parser.add_argument('-sa_dim', '--systolic_array_dim', type=int, default=4) 
    parser.add_argument('-in_buf', '--fifo_depth', type=int, default=4) 



    options = parser.parse_args()

    main(options)
