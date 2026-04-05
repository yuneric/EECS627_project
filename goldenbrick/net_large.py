import numpy as np
import argparse
import sys
import os
import copy
import random

# Add the common script to our path so we can get some epic func's
script_dir = os.path.dirname(__file__) 
scripts_path = os.path.join(script_dir, '../common') 
sys.path.append(scripts_path) 

from matgen import *

input_mem_base  = 0x2000_0000
weight_mem_base = 0x2100_0000

np.random.seed(42)

class LGNet():
    def __init__(self): 
        self.stride_l1  = 1
        self.padding_l1 = 1
        self.scale_l1   = 6
        self.weights_l1 = np.random.randint(-5, 5, (16, 17, 17, 8), dtype=np.int8)

        self.stride_l2  = 1
        self.padding_l2 = 3
        self.scale_l2   = 5
        self.weights_l2 = np.random.randint(-5, 5, (32, 11, 11, 16), dtype=np.int8)

        self.stride_l3  = 2
        self.padding_l3 = 1
        self.scale_l3   = 4
        self.weights_l3 = np.random.randint(-5, 5, (64, 6, 6, 32), dtype=np.int8)

        self.stride_l4  = 1
        self.padding_l4 = 0
        self.scale_l4   = 3
        self.weights_l4 = np.random.randint(-5, 5, (64, 3, 3, 64), dtype=np.int8)

        self.stride_l5  = 1
        self.padding_l5 = 0
        self.scale_l5   = 2
        self.weights_l5 = np.random.randint(-5, 5, (128, 3, 3, 64), dtype=np.int8)


    def run(self, input_image):
        self.input_image = input_image

        # Layer 1 Dataflow: Conv -> ReLU -> Requantize
        # input HWC:    128x128x8
        # weights NHWC: 16x17x17x8
        # output HWC:   112x112x16
        self.output_l1 = do_cnn_layer(ifmap=self.input_image, kernels=self.weights_l1, stride=self.stride_l1, padding=self.padding_l1)
        self.output_l1 = relu(self.output_l1)
        self.output_l1 = scale_clip_real(mat=self.output_l1, shift=self.scale_l1, out_bits=8).astype(np.int8)
        
        # Layer 2 Dataflow: Conv -> ReLU -> Requantize -> Pool
        # input HWC:    112x112x16
        # weights NHWC: 32x11x11x16
        # output HWC:   108x108x32 -> 54x54x32
        self.output_l2 = do_cnn_layer(ifmap=self.output_l1, kernels=self.weights_l2, stride=self.stride_l2, padding=self.padding_l2)
        self.output_l2 = relu(self.output_l2)
        self.output_l2 = scale_clip_real(mat=self.output_l2, shift=self.scale_l2, out_bits=8)
        self.output_l2 = maxpool_real(self.output_l2).astype(np.int8)
        
        # Layer 3 Dataflow: Conv -> ReLU -> Requantize
        # input HWC:    54x54x32
        # weights NHWC: 64x6x6x32
        # output HWC:   26x26x64
        self.output_l3 = do_cnn_layer(ifmap=self.output_l2, kernels=self.weights_l3, stride=self.stride_l3, padding=self.padding_l3)
        self.output_l3 = relu(self.output_l3)
        self.output_l3 = scale_clip_real(mat=self.output_l3, shift=self.scale_l3, out_bits=8).astype(np.int8)
        
        # Layer 4 Dataflow: Conv -> ReLU -> Requantize -> Pool
        # input HWC:    26x26x64
        # weights NHWC: 64x3x3x64
        # output HWC:   24x24x64 -> 12x12x64
        self.output_l4 = do_cnn_layer(ifmap=self.output_l3, kernels=self.weights_l4, stride=self.stride_l4, padding=self.padding_l4)
        self.output_l4 = relu(self.output_l4)
        self.output_l4 = scale_clip_real(mat=self.output_l4, shift=self.scale_l4, out_bits=8)
        self.output_l4 = maxpool_real(self.output_l4).astype(np.int8)

        # Layer 5 Dataflow: Conv -> ReLU -> Requantize
        # input HWC:    12x12x64
        # weights NHWC: 128x3x3x64
        # output HWC:   10x10x128
        self.output_l5 = do_cnn_layer(ifmap=self.output_l4, kernels=self.weights_l5, stride=self.stride_l5, padding=self.padding_l5)
        self.output_l5 = relu(self.output_l5)
        self.output_l5 = scale_clip_real(mat=self.output_l5, shift=self.scale_l5, out_bits=8).astype(np.int8)

        return self.output_l5

    def write_mem(self, mat, file):
        address = 0
        wgt_mem = make_cpu_memory_model(matrix=mat, cpu_word_size=4)
        for word in wgt_mem:
            for data in word:
                file.write(f'{data.astype(np.uint8):02x}')
            address += 4
            file.write('\n')
        return address

    def make_weight_mem_files(self, filename):
        with open(filename, 'w') as file:
            layer1_address = self.write_mem(self.weights_l1, file) + weight_mem_base
            print(f'Weight layer 1 address end: 0x{layer1_address:08x} Shape: {self.weights_l1.shape} Size: {self.weights_l1.nbytes / 1024:.2f} kB')

            layer2_address = self.write_mem(self.weights_l2, file) + layer1_address
            print(f'Weight layer 2 address end: 0x{layer2_address:08x} Shape: {self.weights_l2.shape} Size: {self.weights_l2.nbytes / 1024:.2f} kB')

            layer3_address = self.write_mem(self.weights_l3, file) + layer2_address
            print(f'Weight layer 3 address end: 0x{layer3_address:08x} Shape: {self.weights_l3.shape} Size: {self.weights_l3.nbytes / 1024:.2f} kB')

            layer4_address = self.write_mem(self.weights_l4, file) + layer3_address
            print(f'Weight layer 4 address end: 0x{layer4_address:08x} Shape: {self.weights_l4.shape} Size: {self.weights_l4.nbytes / 1024:.2f} kB')

            layer5_address = self.write_mem(self.weights_l5, file) + layer4_address
            print(f'Weight layer 5 address end: 0x{layer5_address:08x} Shape: {self.weights_l5.shape} Size: {self.weights_l5.nbytes / 1024:.2f} kB')

    def make_fmap_mem_files(self, filename):
        with open(filename, 'w') as file:
            input_address = self.write_mem(self.input_image, file) + input_mem_base
            print(f'Input  fmap    address end: 0x{input_address:08x} Shape: {self.input_image.shape} Size: {self.input_image.nbytes / 1024:.2f} kB')

            layer1_output_address = self.write_mem(self.output_l1, file) + input_address
            print(f'Output layer 1 address end: 0x{layer1_output_address:08x} Shape: {self.output_l1.shape} Size: {self.output_l1.nbytes / 1024:.2f} kB')

            layer2_output_address = self.write_mem(self.output_l2, file) + layer1_output_address
            print(f'Output layer 2 address end: 0x{layer2_output_address:08x} Shape: {self.output_l2.shape} Size: {self.output_l2.nbytes / 1024:.2f} kB')

            layer3_output_address = self.write_mem(self.output_l3, file) + layer2_output_address
            print(f'Output layer 3 address end: 0x{layer3_output_address:08x} Shape: {self.output_l3.shape} Size: {self.output_l3.nbytes / 1024:.2f} kB')

            layer4_output_address = self.write_mem(self.output_l4, file) + layer3_output_address
            print(f'Output layer 4 address end: 0x{layer4_output_address:08x} Shape: {self.output_l4.shape} Size: {self.output_l4.nbytes / 1024:.2f} kB')

            layer5_output_address = self.write_mem(self.output_l5, file) + layer4_output_address
            print(f'Output layer 5 address end: 0x{layer5_output_address:08x} Shape: {self.output_l5.shape} Size: {self.output_l5.nbytes / 1024:.2f} kB')
        
def run_and_export(model, image_size, model_name):
    print(f"--- Running {model_name} ---")
    
    # 1. Generate Input Image (Batch=1, Channels=3, H, W)
    input_rgb = np.random.randint(-5, 5, (image_size, image_size, 3), dtype=np.int8)
    
    # 2. Pad to 8 Channels
    input_padded = pad_channels_to_word_size(input_rgb, 8)
    
    # 3. Run the Golden Math (Now includes ReLU and Requantization)
    output = model.run(input_padded)

    model.make_fmap_mem_files('net_large_fmap.mem')
    model.make_weight_mem_files('net_large_wgt.mem')

# Instantiate models
large_net = LGNet()

# Run Small Net with 128x128 image
run_and_export(large_net, image_size=128, model_name="LGNet")