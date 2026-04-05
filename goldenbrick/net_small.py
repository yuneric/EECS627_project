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

class SMNet():
    def __init__(self):
        Ci = 8
        Co = 16
        Hf = 3 
        Wf = 3 
        self.weights_l1 = np.random.randint(-5, 5, (Co, Hf, Wf, Ci), dtype=np.int8)

        Ci = 16
        Co = 32
        Hf = 3 
        Wf = 3 
        self.weights_l2 = np.random.randint(-5, 5, (Co, Hf, Wf, Ci), dtype=np.int8)

        Ci = 32
        Co = 64
        Hf = 2 
        Wf = 2 
        self.weights_l3 = np.random.randint(-5, 5, (Co, Hf, Wf, Ci), dtype=np.int8)

    def run(self, input_image):
        self.input_image = input_image

        # Layer 1 Dataflow: Conv -> ReLU -> Requantize -> Pool
        # input HWC:    32x32x8
        # weights NHWC: 16x3x3x8
        # output HWC:   32x32x16 -> 16x16x16
        self.output_l1 = do_cnn_layer(ifmap=self.input_image, kernels=self.weights_l1, stride=1, padding=1)
        self.output_l1 = relu(self.output_l1)
        self.output_l1 = scale_clip_real(mat=self.output_l1, shift=4, out_bits=8)
        self.output_l1 = maxpool_real(self.output_l1).astype(np.int8)
        
        # Layer 2 Dataflow: Conv -> ReLU -> Requantize
        # input HWC:    16x16x16
        # weights NHWC: 32x3x3x16
        # output HWC:   16x16x32
        self.output_l2 = do_cnn_layer(ifmap=self.output_l1, kernels=self.weights_l2, stride=1, padding=1)
        self.output_l2 = relu(self.output_l2)
        self.output_l2 = scale_clip_real(mat=self.output_l2, shift=3, out_bits=8).astype(np.int8)
        
        # Layer 3 Dataflow: Conv -> ReLU -> Requantize
        # input HWC:    16x16x32
        # weights NHWC: 64x2x2x32
        # output HWC:   8x8x64
        self.output_l3 = do_cnn_layer(ifmap=self.output_l2, kernels=self.weights_l3, stride=2, padding=0)
        self.output_l3 = relu(self.output_l3)
        self.output_l3 = scale_clip_real(mat=self.output_l3, shift=2, out_bits=8).astype(np.int8)
        
        return self.output_l3

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
        
def run_and_export(model, image_size, model_name):
    print(f"--- Running {model_name} ---")
    
    # 1. Generate Input Image (Batch=1, Channels=3, H, W)
    input_rgb = np.random.randint(-5, 5, (image_size, image_size, 3), dtype=np.int8)
    
    # 2. Pad to word size
    input_padded = pad_channels_to_word_size(input_rgb, word_size)
    
    # 3. Run the Golden CNN
    output = model.run(input_padded)

    # 4. Generate the .mem files for the tb
    model.make_fmap_mem_files('net_small_fmap.mem')
    model.make_weight_mem_files('net_small_wgt.mem')

# Instantiate models
small_net = SMNet()

# Run Small Net with 32x32 image
run_and_export(small_net, image_size=32, model_name="SMNet")