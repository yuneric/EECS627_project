import numpy as np
import argparse
import sys
import os
import copy
import math

# Add the common script to our path so we can get some epic func's
script_dir = os.path.dirname(__file__) 
scripts_path = os.path.join(script_dir, '../common') 
sys.path.append(scripts_path) 

from matgen import *

from systolic_array_block_be import systolic_array_backend
from systolic_array_block_fe import systolic_array_frontend

#Notes:
# load activations -> mem_if(storing activations (output -> write sram)); read sram and write sram.
# loading weights -> dimensions
# N is only used for weights.

# 64 bit words -> int 8 -> how many 64 bits. -> data needed per pixel -> 0 pad the channels.

# tile_stride -> input tile -> 8x8 tiling matrix -> 4x4 section -> width of matrix -> next row.

# (indexing 2d 8x8) -> read in 4, (then have to do math to get to next row)


#tile_stride is just for loading/storing tile

#i_words_per_channel


class MMU:
    """
    Memory Management Unit
    Simulates hardware logic for loading weights and tiles from 
    off-chip memory into on-chip SRAMs via an AXI-like interface.
    """

    #instantiate mmu = model.
    def __init__(self, i_load_weights, i_load_tile, i_store_tile, i_N, i_W, i_H, i_words_per_channel, i_addr, i_tile_stride):
        # Configuration (Private)
        self._i_load_weights = i_load_weights #signal indicating if we're loading weights, loading or storing activation data
        self._i_load_tile = i_load_tile
        self._i_store_tile = i_store_tile
        self._i_N = i_N #the dimensions
        self._i_W = i_W
        self._i_H = i_H
        self._i_words_per_channel = i_words_per_channel #words per pixel
        self._i_addr = i_addr #the off chip memory address we want to read from.
        self._i_tile_stride = i_tile_stride #the tile stride which we'll care about when we load and store activation data

        # Status Registers
        self._o_done = 0 #indicates if we've sucessfully completed the mmu operation

        # SRAM Interface Registers for loading weights
        self._o_wgt_addr = 0
        self._o_wgt_wen = 0
        self._o_wgt_wdata = [0, 0] # [Low 32-bit, High 32-bit]
        self._o_wgt_sram_sel = 0

        # AXI Control Registers (Outputs)
        self._o_araddr = 0
        self._o_arlen = 0
        self._o_arvalid = 0
        
        # AXI Input "Pins" (Latched from Bus)
        self._i_arready = 0
        self._i_rdata = 0
        self._i_rvalid = 0
        self._i_rlast = 0

        #SRAM Interface Registers for loading activation data and storing to on-chip sram
        self._o_act_waddr = 0
        self._o_act_wen = 0
        self._o_act_wdata = [0, 0] # [Low 32-bit, High 32-bit]


    ##is done indicates when mmu operation is done
    @property
    def is_done(self): return self._o_done

    #output weights to weight srams
    @property
    def wgt_outputs(self):
        """Returns the current state of the Weight SRAM interface wires."""
        return {
            "wen": self._o_wgt_wen,
            "sel": self._o_wgt_sram_sel,
            "addr": self._o_wgt_addr,
            "data": tuple(self._o_wgt_wdata) # Tuple prevents external mutation
        }
    
    #output activation tile to mem sram
    @property
    def act_outputs(self):
        """Returns the current state of the activation tile SRAM interface wires."""
        return {
            "wen": self._o_act_wen,
            "addr": self._o_act_waddr,
            "data": tuple(self._o_wgt_wdata) # Tuple prevents external mutation
        }

    @property
    #sends signals out to axi arbiter for reading
    def axi_out(self):
        """Returns the current state of AXI Address channel wires."""
        return {
            "araddr": self._o_araddr,
            "arlen": self._o_arlen,
            "arvalid": self._o_arvalid
        }

    #arready is signaled by axi when it gets the read address
    def set_axi_arready(self, val):
        self._i_arready = val

    #read data and signals sent by axi
    def set_axi_read_data(self, data, valid, last):
        self._i_rdata = data
        self._i_rvalid = valid
        self._i_rlast = last

    #execution logic
    def run(self, bus):
        """Main procedural entry point."""
        if self._i_load_weights:
            self._execute_weight_load(bus)
        
        if self._i_load_tile:
            self._execute_load_tile(bus)

        self._o_done = 1

    def _execute_weight_load(self, bus):
        """
        Loads weights using interleaving logic:
        8 kernels to Bank 0, 8 kernels to Bank 1 ... 8 kernels to Bank 7, repeat.
        """
        #current off chip memory address
        current_mem_ptr = self._i_addr

        #the number of kernel
        num_kernel = self._i_N

        # # SRAM pointers and interleaving state
        sram_bank_addrs = [0] * 8
        curr_bank = 0

        for i in range(num_kernel):
            #the number of beats per kernel
            total_words = self._i_W * self._i_H * self._i_words_per_channel
            total_beats = total_words * 2
        

            #total number of beats received
            beats_received = 0

            while beats_received < total_beats:
                #can only do 256 beat bursts at a time
                burst_len = min(256, total_beats - beats_received)

                #setting address and burst length;
                #the beat size is already set in the initialization
                self._o_araddr = current_mem_ptr
                self._o_arlen = burst_len - 1
                self._o_arvalid = 1
                
                # Handshake with bus
                #send the request
                ready = bus.request_read(self._o_araddr, self._o_arlen)
                self.set_axi_arready(ready)

                if self._o_arvalid and self._i_arready:
                    #can turn off arvalid:
                    #if axi ready then, = self.o_arvalid could be off
                    self._o_arvalid = 0

                    # 2. AXI DATA PHASE
                    for b in range(burst_len):
                        # Fetch from bus
                        #NOTE: FOR RTL have to poll until rlast
                        rdata, rvalid, rlast = bus.get_data(beats_received)
                        self.set_axi_read_data(rdata, rvalid, rlast)

                        if self._i_rvalid:
                            # Pack 32-bit beats into 64-bit data register
                            # Even = Low, Odd = High
                            self._o_wgt_wdata[beats_received % 2] = self._i_rdata

                            if beats_received % 2 == 1:
                                # We have a full word: Drive SRAM signals
                                self._o_wgt_wen = 1
                                self._o_wgt_sram_sel = curr_bank
                                self._o_wgt_addr = sram_bank_addrs[curr_bank]
                                
                                # Inform bus/SRAM to latch the data
                                bus.latch_weight_sram_write(self.wgt_outputs)

                                # Internal bookkeeping
                                sram_bank_addrs[curr_bank] += 1
                                
                            else:
                                self._o_wgt_wen = 0

                            beats_received += 1

                #Update memory pointer (4 bytes per 32-bit beat)
                current_mem_ptr += (burst_len * 4)

            # Switch bank after 8 kernels
            if ((i + 1) % 8 == 0):
                curr_bank = (curr_bank + 1) % 8

    def _execute_load_tile(self, bus):
        """
        Load activation data from off chip memory and write into sram. we start at address 0, use W and H to figure out next jump.
        """

        #for load tile, we should go row by row:
        num_rows = self.i_H

        #current off chip memory address
        current_mem_ptr = self._i_addr

        #will help find the address we want to jump to after the rows are done
        jump_mem_ptr = self.i_addr

        #sram address to write to on chip memory
        sram_addr  = 0

        for i in range(num_rows)
            #the total words we need per row:
            total_words = self._i_W  * self._i_words_per_channel
            total_beats = total_words * 2

            #total number of beats received
            beats_received = 0
            
            #jump to the word we want to process new row.
            current_mem_ptr = jump_mem_ptr
        
            while beats_received < total_beats:
                #can only do 256 beat bursts at a time
                burst_len = min(256, total_beats - beats_received)

                #setting address and burst length;
                #the beat size is already set in the initialization
                self._o_araddr = current_mem_ptr
                self._o_arlen = burst_len - 1
                self._o_arvalid = 1
                
                # Handshake with bus
                #send the request
                ready = bus.request_read(self._o_araddr, self._o_arlen)
                self.set_axi_arready(ready)

                if self._o_arvalid and self._i_arready:
                    #can turn off arvalid:
                    #if axi ready then, = self.o_arvalid could be off
                    self._o_arvalid = 0

                    # 2. AXI DATA PHASE
                    for b in range(burst_len):
                        # Fetch from bus
                        #NOTE: FOR RTL have to poll until rlast
                        rdata, rvalid, rlast = bus.get_data(beats_received)
                        self.set_axi_read_data(rdata, rvalid, rlast)

                        if self._i_rvalid:
                            # Pack 32-bit beats into 64-bit data register
                            # Even = Low, Odd = High
                            self._o_act_wdata[beats_received % 2] = self._i_rdata

                            if beats_received % 2 == 1:
                                # We have a full word: Drive SRAM signals
                                self._o_act_wen = 1
                                self._o_act_waddr = sram_addr
                                
                                # Inform bus/SRAM to latch the data
                                bus.latch_weight_sram_write(self.act_outputs)

                                # Internal bookkeeping
                                sram_addr = sram_addr + 1
                            else:
                                self._o_act_wen = 0

                            beats_received += 1

                    # Update memory pointer (4 bytes per 32-bit beat)
                    current_mem_ptr += (burst_len * 4)
                
            #update jump
            jump_mem_ptr = jump_mem_ptr + self.i_tile_stride
                

    def _execute_store_tile(self, bus):
    # Placeholder for activation storing logic
        pass



# MOCK SYSTEM (Bus & SRAM Simulation)
class MockSystem:
    """
    Simulates the external hardware environment.
    Contains no knowledge of the MMU internal state.
    """
    def __init__(self):
        # 8 SRAM banks, each 2048 words deep (stored as 64-bit uints)
        self.weight_srams = [np.zeros(2048, dtype=np.uint64) for _ in range(8)]

        #holds the activation data
        self.mem_sram = [np.zeros(2048, dtype=np.uint64)]

        #off chip memory(currently not using but have to use to test store weights)
        self.off_chip_mem = [np.zeros(2048, dtype=np.uint64)]

    def request_read(self, addr, length):
        """Simulates the ARREADY handshake."""
        return 1 # Always ready for simplicity

    def get_data(self, beat_idx):
        """Simulates AXI R-channel data."""
        data = 0x1000 + beat_idx
        valid = 1
        last = 1 if (beat_idx % 256 == 255) else 0
        return data, valid, last

    def latch_weight_sram_write(self, signals):
        """Simulates the physical SRAM latching data on WEN high."""
        if signals["wen"]:
            low, high = signals["data"]
            combined = (high << 32) | low
            self.weight_srams[signals["sel"]][signals["addr"]] = combined

    def read_weight_sram(self, bank, addr):
        return self.weight_srams[bank][addr]


#test
if __name__ == "__main__":
    print("--- Starting MMU Simulation ---")
    
    # 1. Initialize MMU
    # Load 128 words (should fill 8 words in all 8 banks, twice)
    # # N=8, W=4, H=4 => 128 words => 256 beats.
    # mmu = MMU(i_load_weights=1, i_load_tile=0, i_store_tile=0,
    #           i_N=8, i_W=4, i_H=4, i_words_per_channel=1,
    #           i_addr=0x8000, i_tile_stride=0)

    mmu = MMU(i_load_weights=1, i_load_tile=0, i_store_tile=0, i_N=64, i_W=16, i_H=16, i_words_per_channel=1, i_addr=0x0, i_tile_stride=0)
    bus = MockSystem()

    # 2. Initialize Bus/SRAM
    bus = MockSystem()

    # 3. Run
    mmu.run(bus)

    # 4. Verification
    print("         VERIFICATION RESULTS")

    w0 = bus.read_weight_sram(0, 0)
    print(f"[FIRST] Bank 0, Addr 0:    {hex(w0)} | Expected: 0x100100001000")

    w_switch = bus.read_weight_sram(1, 0)
    print(f"[SWITCH] Bank 1, Addr 0:   {hex(w_switch)} | Expected: 0x100100001000")

    val_last = bus.read_weight_sram(7, 0)
    print(f"[LAST] Bank 7, Addr 0: {hex(val_last)} | Expected: 0x100100001000")

    if mmu.is_done:
        print("\nSimulation Status: DONE")


