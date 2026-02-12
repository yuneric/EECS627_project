import numpy as np
import argparse

# Made to mimic the SRAM array we use as our main on chip memory
class main_mem:
    def __init__(self, depth, word_size):
        self.depth = depth
        self.word_size = word_size
        self.num_arr_rd_wr = 4
        self.mem = np.zeros((2, self.num_arr_rd_wr, self.depth, self.word_size))
        self.config = '1:8'
        self.ping_pong_sel = 0

    def reset(self):
        self.mem = np.zeros((2, self.num_arr_rd_wr, self.depth, self.word_size))
        self.config = '1:8'
        self.ping_pong_sel = 0

    # Acceptable values '1:8', '1:4', '1:2'
    def configure(self, config):
        self.config = config

    def read(self, addr0, addr1, addr2, addr3):

        read0 = 0
        read1 = 0
        read2 = 0
        read3 = 0

        if(self.config == '1:8'):
            sram_sel  = addr0 & 3 # Get lowest 2 bits
            real_addr = addr0 >> 2
            read0 = read1 = read2 = read3 = self.mem[self.ping_pong_sel][sram_sel][real_addr]
        elif(self.config == '1:4'):
            if(addr0 != -1):
                sram_sel0 = addr0 & 1 # Get lowest bit
                real_addr0 = addr0 >> 1
                read0 = read2 = self.mem[self.ping_pong_sel][sram_sel0][real_addr0]

            if(addr1 != -1):
                sram_sel1 = (addr1 & 1) + 2 # Get lowest bit
                real_addr1 = addr1 >> 1
                read1 = read3 = self.mem[self.ping_pong_sel][sram_sel1][real_addr1]
        elif(self.config == '1:2'):
            if(addr0 != -1):
                read0 = self.mem[self.ping_pong_sel][0][addr0]
            if(addr1 != -1):
                read1 = self.mem[self.ping_pong_sel][1][addr1]
            if(addr2 != -1):
                read2 = self.mem[self.ping_pong_sel][2][addr2]
            if(addr3 != -1):
                read3 = self.mem[self.ping_pong_sel][3][addr3]
        else:
            print('Invalid mem config')
            exit(1)

        return read0, read1, read2, read3
    
    def write(self, addr0, d0, addr1, d1, addr2, d2, addr3, d3):
        if(self.config == '1:8'):
            sram_sel  = addr0 & 3 # Get lowest 2 bits
            real_addr = addr0 >> 2
            self.mem[self.ping_pong_sel][sram_sel][real_addr] = d0
        elif(self.config == '1:4'):
            if(addr0 != -1):
                sram_sel0 = addr0 & 1 # Get lowest bit
                real_addr0 = addr0 >> 1
                self.mem[self.ping_pong_sel][sram_sel0][real_addr0] = d0

            if(addr1 != -1):
                sram_sel1 = (addr1 & 1) + 2 # Get lowest bit
                real_addr1 = addr1 >> 1
                self.mem[self.ping_pong_sel][sram_sel1][real_addr1] = d1
        elif(self.config == '1:2'):
            if(addr0 != -1):
                self.mem[self.ping_pong_sel][0][addr0] = d0
            if(addr1 != -1):
                self.mem[self.ping_pong_sel][1][addr1] = d1
            if(addr2 != -1):
                self.mem[self.ping_pong_sel][2][addr2] = d2
            if(addr3 != -1):
                self.mem[self.ping_pong_sel][3][addr3] = d3
        else:
            print('Invalid mem config')
            exit(1)
        
    def switch(self):
        if(self.ping_pong_sel == 0):
            self.ping_pong_sel = 1
        else:
            self.ping_pong_sel = 0

# Basic weight SRAM
class weight_mem:
    def __init__(self, depth, word_size):
        self.depth = depth
        self.word_size = word_size
        self.mem = np.zeros((self.depth, self.word_size))

    def reset(self):
        self.mem = np.zeros((self.depth, self.word_size))

    def read(self, addr0, addr1, addr2, addr3):
        return self.mem[addr]
    
    def write(addr, d):
        self.mem[addr] = d


def main(options):
    test_entries = np.zeros((options.depth, options.word_size))
    for entry in range(options.depth):
        new_word = np.empty(options.word_size)
        for idx in range(options.word_size):
            new_word[idx] = entry + 1
        test_entries[entry] = new_word
        
    print(test_entries)

    mem = main_mem(options.depth, options.word_size)
    mem.reset()
    for entry in range(options.depth):
        mem.write(entry, test_entries[entry], -1, -1, -1, -1, -1, -1)

    mem.reset()
    mem.switch()
    for entry in range(options.depth):
        mem.write(entry, test_entries[entry], -1, -1, -1, -1, -1, -1)
        read0, read1, read2, read3 = mem.read(entry, -1, -1, -1)
        if(read0[0] != test_entries[entry][0]):
            print('Incorrect output')
            exit(1)

    mem.reset()
    mem.configure('1:4')
    for entry in range(options.depth):
        mem.write(entry, test_entries[entry], -1, -1, -1, -1, -1, -1)
        read0, read1, read2, read3 = mem.read(entry, -1, -1, -1)
        if(read0[0] != test_entries[entry][0]):
            print('Incorrect output')
            exit(1)

    mem.switch()
    for entry in range(options.depth):
        mem.write(-1, -1, entry, test_entries[entry]*10, -1, -1, -1, -1)
        read0, read1, read2, read3 = mem.read(-1, entry, -1, -1)
        if(read1[0] != test_entries[entry][0]*10):
            print('Incorrect output')
            exit(1)

    mem.reset()
    mem.configure('1:2')
    for entry in range(options.depth - 3):
        mem.write(entry, test_entries[entry], entry+1, test_entries[entry], entry+2, test_entries[entry], entry+3, test_entries[entry])
        read0, read1, read2, read3 = mem.read(entry, -1, -1, -1)
        if(read0[0] != test_entries[entry][0]):
            print('Incorrect output')
            exit(1)

    mem.switch()
    for entry in range(options.depth-3):
        mem.write(entry, test_entries[entry]*10, entry+1, test_entries[entry]*100, entry+2, test_entries[entry]*1000, entry+3, test_entries[entry]*10000)
        read0, read1, read2, read3 = mem.read(entry, entry+1, entry+2, entry+3)
        if(read0[0] != test_entries[entry][0]*10):
            print('Incorrect output')
            exit(1)
        if(read1[0] != test_entries[entry][0]*100):
            print('Incorrect output')
            exit(1)
        if(read2[0] != test_entries[entry][0]*1000):
            print('Incorrect output')
            exit(1)
        if(read3[0] != test_entries[entry][0]*10000):
            print('Incorrect output')
            exit(1)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
                        prog='mem_engine.py',
                        description='mem_goldenbrick kinda',
                        epilog='teehee')

    parser.add_argument('-w', '--word_size', type=int, default=2)   # rows in activations
    parser.add_argument('-d', '--depth', type=int, default=2)      # cols in activations

    options = parser.parse_args()

    main(options)
