import numpy as np
import argparse
import sys
import os

# Basically a configurable dualport fifo
class configurable_fifo:
    def __init__(self, depth, word_size):
        self.depth = depth
        self.word_size = word_size
        self.reset()

    def reset(self):
        self.wr_ptr = 0
        self.wr_side = True
        self.rd_ptr = 0
        self.rd_side = True
        self.loop_count = self.depth
        self.buf = np.zeros((self.depth, self.word_size))

    def loop(self, loop_count):
        self.reset()
        self.loop_count = loop_count

    def read(self):
        # print(f"rd_ptr = {self.rd_ptr} rd_side = {self.rd_side}")
        # print(f"wr_ptr = {self.wr_ptr} wr_side = {self.wr_side}")
        if(self.empty()):
            print('Tried to read from an empty buffer')
        else:
            val = self.buf[self.rd_ptr]
            self.rd_ptr += 1
            if(self.rd_ptr == self.loop_count):
                self.rd_ptr = 0
                self.rd_side = not self.rd_side
            return val
    
    def write(self, val):
        # print(f"rd_ptr = {self.rd_ptr} rd_side = {self.rd_side}")
        # print(f"wr_ptr = {self.wr_ptr} wr_side = {self.wr_side}")
        if(self.full()):
            print('Tried to write to a full buffer!')
        else:
            self.buf[self.wr_ptr] = val
            self.wr_ptr += 1
            if(self.wr_ptr == self.loop_count):
                self.wr_ptr = 0
                self.wr_side = not self.wr_side
        # print(self.buf)
        

    def read_write(self, wr_val):
        val = self.read()
        self.write(wr_val)
        #print(self.buf)
        return val

    def empty(self):
        if((self.rd_ptr == self.wr_ptr) and (self.rd_side == self.wr_side)):
            return True
        else:
            return False

    def full(self):
        if((self.rd_ptr == self.wr_ptr) and (self.rd_side != self.wr_side)):
            return True
        else:
            return False

def main(options):
    test_entries = np.zeros((options.depth, options.word_size))
    for entry in range(options.depth):
        new_word = np.empty(options.word_size)
        for idx in range(options.word_size):
            new_word[idx] = entry
        test_entries[entry] = new_word
        
    print(test_entries)

    buf = configurable_fifo(options.depth, options.word_size)
    buf.loop(options.depth)

    if(not buf.empty()):
        print('Error: Should be empty')

    for entry in range(options.depth):
        buf.write(test_entries[entry])
        if(buf.empty()):
            print('Error: Should not be empty')

    if(not buf.full()):
        print('Error: Should be full')

    for entry in range(options.depth):
        read_val = buf.read()
        if(buf.full()):
            print('Error: Should not be full')
        for val in range(options.word_size):
            if (read_val[val] != test_entries[entry][val]):
                print(f"Read val {read_val[val]} != {test_entries[entry][val]} : Incorrect")
    
    for entry in range(options.depth):
        new_entry = np.zeros(options.word_size)
        new_entry += 255
        read_val = buf.read_write(new_entry)
    
    buf.loop(5)

    for entry in range(options.depth):
        buf.write(test_entries[entry])

    for entry in range(options.depth):
        read_val = buf.read()
        print(read_val)

if __name__ == "__main__":


    parser = argparse.ArgumentParser(
                        prog='accum_buf.py',
                        description='goldenbrick accumulator buffer',
                        epilog='teehee')

    parser.add_argument('-w', '--word_size', type=int, default=8)   # rows in activations
    parser.add_argument('-d', '--depth', type=int, default=16)      # cols in activations

    options = parser.parse_args()

    main(options)
