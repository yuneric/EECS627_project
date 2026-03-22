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

# (We no longer explicitly need to import matgen here since we parse the file, 
# but keeping it per your original code structure)
try:
    from matgen import *
except ImportError:
    pass

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

        #AXI READ REGISTERS
        # AXI Control Registers (Outputs)
        self._o_araddr = 0
        self._o_arlen = 0
        self._o_arvalid = 0
        
        # AXI Input "Pins" (Latched from Bus)
        self._i_arready = 0
        self._i_rdata = 0
        self._i_rvalid = 0
        self._i_rlast = 0

        #AXI WRITE REGISTERS (outputs)
        self._o_awaddr = 0
        self._o_awlen = 0
        self._o_awvalid = 0
        self._o_wdata = 0
        self._o_wlast = 0
        self._o_wvalid = 0
        self._o_bready = 0

        #ready signal from arbiter recognizes address
        self._i_awready = 0
        #the npu could move onto outputting the next set of data
        self._i_wready = 0
        #could move onto next
        self._i_bvalid = 0

        #SRAM Interface Registers for loading activation data and storing to on-chip sram
        self._o_act_waddr = 0
        self._o_act_wen = 0
        self._o_act_wdata = [0, 0] # [Low 32-bit, High 32-bit]

        #SRAM Internal Registers for storing activation data from on chip sram to off chip memory
        self._o_act_raddr = 0
        self._o_act_ren = 0


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
            "data": tuple(self._o_act_wdata) 
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

    #awready is signaled by axi when it gets the write address
    def set_axi_awready(self, val):
        self._i_awready = val

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
            
        if self._i_store_tile:
            self._execute_store_tile(bus)

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

                    # 2. AXI DATA PHASE (Hardware-Accurate Polling)
                    burst_done = False
                    while not burst_done:
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
                            
                            # Check RLAST to terminate burst state
                            if self._i_rlast:
                                burst_done = True

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
        num_rows = self._i_H

        #current off chip memory address
        current_mem_ptr = self._i_addr

        #will help find the address we want to jump to after the rows are done
        jump_mem_ptr = self._i_addr

        #sram address to write to on chip memory
        sram_addr  = 0

        for i in range(num_rows):
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

                    # 2. AXI DATA PHASE (Hardware-Accurate Polling)
                    burst_done = False
                    while not burst_done:
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
                                bus.latch_act_sram_write(self.act_outputs)

                                # Internal bookkeeping
                                sram_addr = sram_addr + 1
                            else:
                                self._o_act_wen = 0

                            beats_received += 1
                            
                            # Check RLAST to terminate burst state
                            if self._i_rlast:
                                burst_done = True

                    # Update memory pointer (4 bytes per 32-bit beat)
                    current_mem_ptr += (burst_len * 4)
                
            #update jump
            jump_mem_ptr = jump_mem_ptr + (self._i_tile_stride * self._i_words_per_channel * 8)


    def _execute_store_tile(self, bus):
        """
        store activation data from sram and write to off chip memory
        """

        #for store tile, we should go row by row:
        num_rows = self._i_H

        #current off chip memory address
        current_mem_ptr = self._i_addr

        #will help find the address we want to jump to after the rows are done
        jump_mem_ptr = self._i_addr

        #sram address to write to on chip memory
        sram_addr  = 0

        for i in range(num_rows):
            #this gives us the data that is supposed to be contiguous in off chip memory.
            total_words = self._i_W  * self._i_words_per_channel
            total_beats = total_words * 2

            #total number of beats sent
            beats_sent = 0
            
            #jump to the word we want to write to.
            current_mem_ptr = jump_mem_ptr
        
            while beats_sent < total_beats:
                #can only do 256 beat bursts at a time
                burst_len = min(256, total_beats - beats_sent)

                #setting address and burst length;
                #the beat size is already set in the initialization
                self._o_awaddr = current_mem_ptr
                self._o_awlen = burst_len - 1
                self._o_awvalid = 1
                
                # Handshake with bus
                #send the request
                ready = bus.request_write(self._o_awaddr, self._o_awlen)
                self.set_axi_awready(ready)

                if self._o_awvalid and self._i_awready:
                    #can turn off arvalid:
                    #if axi ready then, = self.o_awvalid could be off
                    self._o_awvalid = 0

                    # 2. AXI DATA PHASE (Hardware-Accurate Polling)
                    burst_done = False
                    burst_beat_count = 0
                    
                    while not burst_done:
                        # Fetch from bus
                        #NOTE: FOR RTL have to poll until rlast
                        # (We are writing to the bus instead of fetching, but keeping your comment!)
                        
                        # READ FROM ON-CHIP SRAM
                        self._o_act_ren = 1
                        self._o_act_raddr = sram_addr
                        sram_data = bus.read_act_sram(self._o_act_raddr)
                        
                        # Split 64-bit SRAM data into two 32-bit beats
                        low_32 = int(sram_data) & 0xFFFFFFFF
                        high_32 = (int(sram_data) >> 32) & 0xFFFFFFFF
                        
                        # Select which half to send based on beat count
                        self._o_wdata = low_32 if (beats_sent % 2 == 0) else high_32
                        self._o_wvalid = 1
                        
                        # Assert WLAST on the final beat of the burst
                        self._o_wlast = 1 if (burst_beat_count == burst_len - 1) else 0

                        #if received data
                        self._i_wready = bus.send_write_data(self._o_wdata, self._o_wlast)
                        write_received = self._i_wready
                        
                        if write_received and self._o_wvalid:
                            #if write is received then we can write the next write.

                            # Move to next SRAM word only after sending the High 32-bits (odd beat)
                            if beats_sent % 2 == 1:
                                sram_addr += 1 

                            beats_sent += 1
                            burst_beat_count += 1
                            
                            # Check RLAST to terminate burst state
                            # (For writing, we check wlast)
                            if self._o_wlast:
                                self._o_wvalid = 0
                                burst_done = True

                    # 3. B Phase (Write Response)
                    self._o_bready = 1
                    self._i_bvalid = bus.get_bresp()
                    if self._i_bvalid and self._o_bready:
                        self._o_bready = 0 # Handshake complete

                    # Update memory pointer (4 bytes per 32-bit beat)
                    current_mem_ptr += (burst_len * 4)
                
            #update jump
            jump_mem_ptr = jump_mem_ptr + (self._i_tile_stride * self._i_words_per_channel * 8)

# =====================================================================
# UPDATED MOCK SYSTEM
# =====================================================================
class MockSystem:
    def __init__(self, weights_mem, act_mem, wgt_base_addr=0x0, act_base_addr=0x1000):
        self.weight_srams = [np.zeros(2048, dtype=np.uint64) for _ in range(8)]
        self.mem_sram = np.zeros(2048, dtype=np.uint64)

        # Create a massive simulated byte-addressable off-chip memory
        self.off_chip_mem = {}

        # Pack Weights
        wgt_uint32 = weights_mem.astype(np.int8).flatten().view(np.uint32)
        for i, beat in enumerate(wgt_uint32):
            self.off_chip_mem[wgt_base_addr + (i * 4)] = beat

        # Pack Activations
        act_uint32 = act_mem.astype(np.int8).flatten().view(np.uint32)
        for i, beat in enumerate(act_uint32):
            self.off_chip_mem[act_base_addr + (i * 4)] = beat

        # Internal tracking for AXI bursts
        self.current_read_addr = 0
        self.read_beats_remaining = 0
        
        self.current_write_addr = 0
        self.write_beats_remaining = 0

    # --- READ METHODS ---
    def request_read(self, addr, length):
        self.current_read_addr = addr
        self.read_beats_remaining = length + 1 
        return 1

    def get_data(self, beat_idx):
        data = self.off_chip_mem.get(self.current_read_addr, 0)
        self.current_read_addr += 4 
        valid = 1
        self.read_beats_remaining -= 1
        last = 1 if (self.read_beats_remaining <= 0) else 0 
        return data, valid, last

    # --- WRITE METHODS (NEW) ---
    def request_write(self, addr, length):
        """Latches the starting address for an AXI write burst."""
        self.current_write_addr = addr
        self.write_beats_remaining = length + 1
        return 1
    
    #We just write data this doesn't work for store tiles because there are bursts
    def send_write_data(self, data, last):
        """Receives a 32-bit beat from the MMU and stores it in physical memory."""
        self.off_chip_mem[self.current_write_addr] = data
        self.current_write_addr += 4
        self.write_beats_remaining -= 1
        return 1
        
    def get_bresp(self):
        """Returns BVALID once the burst is fully written."""
        return 1 if (self.write_beats_remaining <= 0) else 0

    # --- SRAM LATCHING METHODS ---
    def latch_weight_sram_write(self, signals):
        if signals["wen"]:
            low, high = signals["data"]
            combined = (int(high) << 32) | int(low)
            self.weight_srams[signals["sel"]][signals["addr"]] = np.uint64(combined)

    def latch_act_sram_write(self, signals):
        if signals["wen"]:
            low, high = signals["data"]
            combined = (int(high) << 32) | int(low)
            self.mem_sram[signals["addr"]] = np.uint64(combined)

    def read_weight_sram(self, bank, addr):
        return self.weight_srams[bank][addr]

    def read_act_sram(self, addr):
        return self.mem_sram[addr]

# =====================================================================
# FILE PARSER UTILITY
# =====================================================================
def parse_matgen_out(filepath):
    """Parses matgen_test.out to extract dimensions and memory models."""
    dims = {}
    act_mem = []
    wgt_mem = []
    mode = None
    
    if not os.path.exists(filepath):
        raise FileNotFoundError(f"Could not find {filepath}. Please run the generator script first.")

    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            
            if line.startswith("Activation matrix:"):
                mode = "act_dim"
            elif line.startswith("Weight kernels:"):
                mode = "wgt_dim"
            elif line.startswith("Activation mem model:"):
                mode = "act_mem"
            elif line.startswith("Weights mem model:"):
                mode = "wgt_mem"
                
            elif line.startswith("Matrix Dim:") and mode == "act_dim":
                cleaned = line.split(":")[1].replace('(', '').replace(')', '').strip()
                dims['H'], dims['W'], dims['C'] = [int(x) for x in cleaned.split(',')]
            elif line.startswith("Matrix Dim:") and mode == "wgt_dim":
                cleaned = line.split(":")[1].replace('(', '').replace(')', '').strip()
                dims['N'] = [int(x) for x in cleaned.split(',')][0]
                
            elif mode == "act_mem" and line.startswith('['):
                cleaned = line.replace('[', '').replace(']', '')
                if cleaned:
                    act_mem.append([int(x) for x in cleaned.split()])
            elif mode == "wgt_mem" and line.startswith('['):
                cleaned = line.replace('[', '').replace(']', '')
                if cleaned:
                    wgt_mem.append([int(x) for x in cleaned.split()])
                    
    return dims, np.array(act_mem, dtype=np.int8), np.array(wgt_mem, dtype=np.int8)

def parse_matrix_dims(filepath):
    dims = {}
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith("Matrix Dim:"):
                cleaned = line.split(":")[1].replace("(", "").replace(")", "").strip()
                vals = [int(x.strip()) for x in cleaned.split(",")]
                if len(vals) == 3:
                    dims["H"], dims["W"], dims["C"] = vals
                elif len(vals) == 4:
                    dims["N"], dims["H"], dims["W"], dims["C"] = vals
                break
    return dims


def parse_mem_model_txt(filepath):
    rows = []
    with open(filepath, 'r') as f:
        for line in f:
            line = line.strip()
            if line.startswith("["):
                cleaned = line.replace("[", "").replace("]", "").strip()
                if cleaned:
                    rows.append([int(x) for x in cleaned.split()])
    return np.array(rows, dtype=np.int8)
# =====================================================================
# TESTBENCH
# =====================================================================
if __name__ == "__main__":
    print("\n--- Starting MMU Simulation ---")
    
    # print("[Parsing matgen_test.out...]")
    # dims, activation_mem, weights_mem = parse_matgen_out('matgen_test.out')
    
    # N = dims['N']
    # H = dims['H']
    # W = dims['W']
    # C = dims['C']
    # print("[Parsing mmu_vectors/test0 ...]")

    vec_dir = "mmu_vectors/test1"

    act_dims = parse_matrix_dims(os.path.join(vec_dir, "activation_matrix.txt"))
    wgt_dims = parse_matrix_dims(os.path.join(vec_dir, "weight_kernels.txt"))

    activation_mem = parse_mem_model_txt(os.path.join(vec_dir, "act_mem_model.txt"))
    weights_mem = parse_mem_model_txt(os.path.join(vec_dir, "wgt_mem_model.txt"))

    N = wgt_dims['N']
    H = act_dims['H']
    W = act_dims['W']
    C = act_dims['C']
    print(f"Parsed Dimensions: N={N}, H={H}, W={W}, C={C}")

    #there could be more channels than 8, so this is how many channels.
    #or less.
    words_per_channel = math.ceil(C / 8)

    WGT_BASE = 0x0
    ACT_BASE = 0x1000
    STORE_BASE = 0x2000  # We will test writing data out to this new address!

    bus = MockSystem(weights_mem, activation_mem, wgt_base_addr=WGT_BASE, act_base_addr=ACT_BASE)

    # --- TEST 1: LOAD WEIGHTS ---
    print("\n[Running Weight Load...]")
    mmu_wgt = MMU(
        i_load_weights=1, i_load_tile=0, i_store_tile=0, 
        i_N=N, i_W=W, i_H=H, i_words_per_channel=words_per_channel, 
        i_addr=WGT_BASE, i_tile_stride=0
    )
    mmu_wgt.run(bus)

    # --- TEST 2: LOAD 2x2 SUB-TILE ---
    print("[Running 2x2 Sub-Tile Load...]")
    #The W is the Width of the kernels, how many words in 64 bits that get the 
    #8 is the number of bytes.
    feature_map_stride = W
    tile_W = 2
    tile_H = 2

    mmu_act_load = MMU(
        i_load_weights=0, i_load_tile=1, i_store_tile=0, 
        i_N=0, i_W=tile_W, i_H=tile_H, i_words_per_channel=words_per_channel, 
        i_addr=ACT_BASE, i_tile_stride=feature_map_stride
    )
    mmu_act_load.run(bus)

    # --- TEST 3: STORE THE TILE OUT TO A NEW OFF-CHIP ADDRESS ---
    print("[Running Store Tile...]")
    mmu_act_store = MMU(
        i_load_weights=0, i_load_tile=0, i_store_tile=1, 
        i_N=0, i_W=tile_W, i_H=tile_H, i_words_per_channel=words_per_channel, 
        i_addr=STORE_BASE, i_tile_stride=feature_map_stride
    )
    mmu_act_store.run(bus)

    # --- VERIFICATION ---
    print("\n" + "="*50)
    print("              VERIFICATION RESULTS")
    print("="*50)
    
    # 1. Check Weights
    expected_w0 = weights_mem[0].astype(np.int8).view(np.uint64)[0]
    w0 = bus.read_weight_sram(0, 0)
    print(f"Weight [Bank 0, Addr 0]")
    print(f"  Expected Hex: {hex(expected_w0)}")
    print(f"  Actual Hex:   {hex(w0)}")
    
    print("\n--- Load Sub-Tile Verification: 2x2 Tile ---")

    # SRAM 0: Row 0, Col 0 (Line 0 in text file)
    #first pixel
    #two words per pixel
    expected_sram0 = activation_mem[0].astype(np.int8).view(np.uint64)[0]
    actual_sram0 = bus.read_act_sram(0)
    print(f"Tile Row 0, Col 0 (SRAM Addr 0):")
    print(f"  Expected: {hex(expected_sram0):>18} | Actual: {hex(actual_sram0):>18}")

    expected_sram1 = activation_mem[1].astype(np.int8).view(np.uint64)[0]
    actual_sram1 = bus.read_act_sram(1)
    print(f"Tile Row 0, Col 0 (cont):")
    print(f"  Expected: {hex(expected_sram1):>18} | Actual: {hex(actual_sram1):>18}")

    ##second pixel is going to be third entry in expected sram
    expected_sram2 = activation_mem[2].astype(np.int8).view(np.uint64)[0]
    actual_sram2 = bus.read_act_sram(2)
    print(f"Tile Row 1, Col 0 (SRAM Addr 2):")
    print(f"  Expected: {hex(expected_sram2):>18} | Actual: {hex(actual_sram2):>18}")

    #seconf pixel cont.
    expected_sram3 = activation_mem[3].astype(np.int8).view(np.uint64)[0]
    actual_sram3 = bus.read_act_sram(3)
    print(f"Tile Row 1, Col 0 (cont):")
    print(f"  Expected: {hex(expected_sram3):>18} | Actual: {hex(actual_sram3):>18}")

    #third pixel -> here is the jump
    expected_sram4 = activation_mem[6].astype(np.int8).view(np.uint64)[0]
    actual_sram4 = bus.read_act_sram(4)
    print(f"Tile Row 1, Col 1:")
    print(f"  Expected: {hex(expected_sram4):>18} | Actual: {hex(actual_sram4):>18}")


    #third pixel -> here is the jump
    expected_sram5 = activation_mem[7].astype(np.int8).view(np.uint64)[0]
    actual_sram5 = bus.read_act_sram(5)
    print(f"Tile Row 1, Col 1: Cont.")
    print(f"  Expected: {hex(expected_sram5):>18} | Actual: {hex(actual_sram5):>18}")
    

    # 3. Check Store Tile (Off-Chip Memory was successfully written to)
    print("\n--- Store Tile Verification ---")
    
    # Read the two 32-bit beats we wrote back to off-chip memory at STORE_BASE
    stored_low_beat = bus.off_chip_mem.get(STORE_BASE, 0)
    stored_high_beat = bus.off_chip_mem.get(STORE_BASE + 4, 0)
    
    # Recombine them to check against our SRAM data
    stored_recombined = (int(stored_high_beat) << 32) | int(stored_low_beat)
    
    print(f"Data Written to Off-Chip Memory (STORE_BASE 0x2000):")
    print(f"  What we expect (Data from SRAM Addr 0): {hex(actual_sram0)}")
    print(f"  What was actually written to Off-Chip:  {hex(stored_recombined)}")


      # Read the two 32-bit beats we wrote back to off-chip memory at STORE_BASE
    stored_low_beat = bus.off_chip_mem.get(STORE_BASE + 8, 0)
    stored_high_beat = bus.off_chip_mem.get(STORE_BASE + 12, 0)
    
    # Recombine them to check against our SRAM data
    stored_recombined = (int(stored_high_beat) << 32) | int(stored_low_beat)
    
    print(f"Data Written to Off-Chip Memory (next store):")
    print(f"  What we expect (Data from SRAM Addr 1): {hex(actual_sram1)}")
    print(f"  What was actually written to Off-Chip:  {hex(stored_recombined)}")

      # Read the two 32-bit beats we wrote back to off-chip memory at STORE_BASE
    stored_low_beat = bus.off_chip_mem.get(STORE_BASE + 16, 0)
    stored_high_beat = bus.off_chip_mem.get(STORE_BASE + 20, 0)
    
    # Recombine them to check against our SRAM data
    stored_recombined = (int(stored_high_beat) << 32) | int(stored_low_beat)
    
    print(f"Data Written to Off-Chip Memory (next store):")
    print(f"  What we expect (Data from SRAM Addr 2): {hex(actual_sram2)}")
    print(f"  What was actually written to Off-Chip:  {hex(stored_recombined)}")


      # Read the two 32-bit beats we wrote back to off-chip memory at STORE_BASE
    stored_low_beat = bus.off_chip_mem.get(STORE_BASE + 24, 0)
    stored_high_beat = bus.off_chip_mem.get(STORE_BASE + 28, 0)
    
    # Recombine them to check against our SRAM data
    stored_recombined = (int(stored_high_beat) << 32) | int(stored_low_beat)
    
    print(f"Data Written to Off-Chip Memory (next store):")
    print(f"  What we expect (Data from SRAM Addr 3): {hex(actual_sram3)}")
    print(f"  What was actually written to Off-Chip:  {hex(stored_recombined)}")

    # Read the two 32-bit beats we wrote back to off-chip memory at STORE_BASE
    stored_low_beat = bus.off_chip_mem.get(STORE_BASE + 32, 0)
    stored_high_beat = bus.off_chip_mem.get(STORE_BASE + 36, 0)
    
    # Recombine them to check against our SRAM data
    stored_recombined = (int(stored_high_beat) << 32) | int(stored_low_beat)
    
    print(f"Data Written to Off-Chip Memory (next store):")
    print(f"  What we expect (Data from SRAM Addr 4): {hex(actual_sram4)}")
    print(f"  What was actually written to Off-Chip:  {hex(stored_recombined)}")


    # Read the two 32-bit beats we wrote back to off-chip memory at STORE_BASE
    stored_low_beat = bus.off_chip_mem.get(STORE_BASE + 40, 0)
    stored_high_beat = bus.off_chip_mem.get(STORE_BASE + 44, 0)
    
    # Recombine them to check against our SRAM data
    stored_recombined = (int(stored_high_beat) << 32) | int(stored_low_beat)
    
    print(f"Data Written to Off-Chip Memory (next store):")
    print(f"  What we expect (Data from SRAM Addr 5): {hex(actual_sram5)}")
    print(f"  What was actually written to Off-Chip:  {hex(stored_recombined)}")



    if mmu_wgt.is_done and mmu_act_load.is_done and mmu_act_store.is_done:
        print("\nSimulation Status: DONE")


    ## nanda added this, want to compare 
    print("\n--- Full Weight SRAM Dump (nonzero entries) ---")
    for bank in range(8):
        for addr in range(2048):
            val = bus.read_weight_sram(bank, addr)
            if int(val) != 0:
                print(f"bank={bank} addr={addr} data={hex(int(val))}")

    
    print("Weights mem model = [")

    for bank in range(8):
        for addr in range(2048):
            val = bus.read_weight_sram(bank, addr)
            val_int = int(val)
            
            if val_int != 0:
                row_weights = []
                
                # Extract 8 bytes (Little-Endian)
                for i in range(8):
                    # Shift and mask to get the specific byte
                    byte = (val_int >> (i * 8)) & 0xFF
                    
                    # Convert from Unsigned 8-bit to Signed 8-bit
                    if byte >= 128:
                        byte -= 256
                    
                    row_weights.append(byte)
                
                # Format the output to look like a Python list
                formatted_row = ", ".join(f"{w:2}" for w in row_weights)
                print(f"    [{formatted_row}]")

    print("]")



    #now print in file:
    filename = "../verilog/mmu/tb/golden_brick_wgt_mem_model_sram_dump.txt"

    print(f"Extracting SRAM to {filename}...")

    with open(filename, "w") as f:
        f.write("Weights mem model: \n[")
        
        for bank in range(8):
            for addr in range(2048):
                val = bus.read_weight_sram(bank, addr)
                val_int = int(val)
                
                if val_int != 0:
                    row_weights = []
                    
                    # Extract 8 bytes (Little-Endian)
                    for i in range(8):
                        # Shift and mask to get the specific byte (LSB is index 0)
                        byte = (val_int >> (i * 8)) & 0xFF
                        
                        # Convert from Unsigned 8-bit to Signed 8-bit (Two's Complement)
                        if byte >= 128:
                            byte -= 256
                        
                        row_weights.append(byte)
                    
                    # Format the row: e.g., [ 0, -2,  1, -2,  1,  3, -2,  3]
                    formatted_row = " ".join(f"{w:2}" for w in row_weights)
                    
                    # Write to file and also print to console to show progress
                    line = f"[{formatted_row}]\n"
                    f.write(line)
                    print(line, end="")

        f.write("]\n")

    print(f"\nDone! File '{filename}' has been created.")
        



    with open(f"../verilog/mmu/tb/golden_brick_weight_sram_dump.txt", "w") as f:
        f.write("--- Full Weight SRAM Dump (nonzero entries) ---\n")
        
        for bank in range(8):
            # Optional: Add a separator for each bank in the file
            f.write(f"\n==== BANK {bank} ====\n")
            
            for addr in range(2048):
                val = bus.read_weight_sram(bank, addr)
                val_int = int(val)
                
                if val_int != 0:
                    # Formatting string for consistency
                    entry = f"bank={bank} addr={addr} data={hex(val_int)}\n"
                    
                    # Print to screen to monitor progress
                    print(entry, end="")
                    # Write to the file
                    f.write(entry)

    print(f"\nDump complete. All nonzero entries saved to golden_brick_weight_sram_dump.txt")


    # print("\n==== ACT SRAM DUMP ====")
    # for addr in range(2048):
    #     val = bus.read_act_sram(addr)
    #     if int(val) != 0:
    #         print(f"addr={addr} data={int(val):016x}")

    
    with open("../verilog/mmu/tb/golden_brick_act_sram_dump.txt", "w") as f:
        f.write("==== ACT SRAM DUMP ====\n") # to match the rtl output
        
        for addr in range(2048):
            val = bus.read_act_sram(addr)
            val_int = int(val)
            
            if val_int != 0:
                # Format the string exactly as you had it
                output_line = f"addr={addr} data={val_int:016x}\n"
                
                # Print to console so you can still see progress
                print(output_line, end="")
                
                # Write to the file
                f.write(output_line)

    print("\nDump complete. Saved to golden_brick_act_sram_dump.txt")
    os.makedirs(vec_dir, exist_ok=True)

    with open(os.path.join(vec_dir, "golden_act_sram.hex"), "w") as f:
        for addr in range(tile_H * tile_W * words_per_channel):
            val = int(bus.read_act_sram(addr))
            f.write(f"{val:016x}\n")

    total_store_words = tile_H * tile_W * words_per_channel
    total_store_beats = total_store_words * 2

    with open(os.path.join(vec_dir, "golden_store_axi32.hex"), "w") as f:
        #for beat in range(total_store_beats):
        #print the entirety of memory from the base address
        for beat in range(260096):
            addr = STORE_BASE + (beat * 4)
            val = int(bus.off_chip_mem.get(addr, 0))
            f.write(f"{val:08x}\n")

    #print the entirety of off-chip memory actually to check:
    with open(os.path.join(vec_dir, "golden_weight_sram_dump.txt"), "w") as f:
        for bank in range(8):
            for addr in range(2048):
                val = int(bus.read_weight_sram(bank, addr))
                if val != 0:
                    f.write(f"bank={bank} addr={addr} data={val:016x}\n")

    print(f"\nGolden outputs written into {vec_dir}/")

