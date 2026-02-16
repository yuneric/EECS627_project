#!/usr/bin/env python3
"""
Parse backend_out.txt and generate hex files for Verilog testbench.
- tb_in_data.hex: relu_output values (input to DUT when relu_en=0)
- tb_exp_scale.hex: scale_clip_output values (expected output)

The testbench sends relu_output -> ReLU -> scale_clip
When relu_en=0 and shift_amt=0, output should match input (for small positive values).
"""

import re
import sys

def parse_array(s):
    """Parse a numpy-style array string like '[3 4 9 6 4 3 5 4]' or '[0. 0. 0.]'"""
    s = s.strip().strip('[]')
    s = ' '.join(s.split())
    vals = s.split()
    result = []
    for v in vals:
        try:
            v = v.rstrip('.')
            result.append(int(float(v)))
        except ValueError:
            result.append(0)
    return result

def to_twos_complement_hex(val, width_bits):
    """Convert signed integer to two's complement hex string"""
    if val < 0:
        val = (1 << width_bits) + val
    return format(val & ((1 << width_bits) - 1), f'0{width_bits // 4}x')

def main():
    with open('/afs/umich.edu/class/eecs627/w26/groups/group7/project/verilog/backend_out.txt', 'r') as f:
        lines = f.readlines()
    
    # Parse test by test, collecting (input, expected_output) pairs
    # Input = relu_output at cycle N
    # Expected = scale_clip_output at cycle N+1
    
    all_inputs = []
    all_expected = []
    current_test = -1
    current_dim = 8
    
    i = 0
    while i < len(lines):
        line = lines[i].rstrip('\n')
        
        # Detect test start
        if '######## Test' in line:
            match = re.search(r'Test (\d+)', line)
            if match:
                current_test = int(match.group(1))
            i += 1
            continue
        
        # Parse data lines
        if re.match(r'^\d+ \|', line):
            parts = line.split('|')
            if len(parts) >= 3:
                relu_str = parts[1].strip()
                scale_str = parts[2].strip()
                
                # Handle multi-line arrays (DIM=16 wraps)
                while relu_str.count('[') > relu_str.count(']') and i + 1 < len(lines):
                    i += 1
                    next_line = lines[i].rstrip('\n')
                    # This continuation line has relu continued, then scale
                    if '|' in next_line:
                        # Split and append
                        cont_parts = next_line.split('|')
                        relu_str += ' ' + cont_parts[0].strip()
                        if len(cont_parts) > 1:
                            scale_str = cont_parts[1].strip()
                    else:
                        relu_str += ' ' + next_line.strip()
                
                # Similarly handle scale_str multi-line
                while scale_str.count('[') > scale_str.count(']') and i + 1 < len(lines):
                    i += 1
                    next_line = lines[i].rstrip('\n')
                    if '|' in next_line:
                        cont_parts = next_line.split('|')
                        scale_str += ' ' + cont_parts[0].strip()
                    else:
                        scale_str += ' ' + next_line.strip()
                
                relu_arr = parse_array(relu_str)
                scale_arr = parse_array(scale_str)
                
                dim = len(relu_arr)
                
                # Only collect DIM=8 data (testbench is hardcoded for DIM=8)
                if dim == 8:
                    # Collect non-zero relu outputs as inputs
                    if not all(v == 0 for v in relu_arr):
                        all_inputs.append(relu_arr)
                    
                    # Collect non-zero scale outputs as expected
                    if not all(v == 0 for v in scale_arr):
                        all_expected.append(scale_arr)
        
        i += 1
    
    print(f"Parsed DIM=8 vectors: {len(all_inputs)} inputs, {len(all_expected)} expected outputs")
    
    # The scale output is delayed by 1 cycle from relu input
    # So expected[i] corresponds to input[i]
    # Verify lengths match
    n = min(len(all_inputs), len(all_expected))
    print(f"Using {n} matched pairs")
    
    # Write input data (32-bit signed)
    with open('/afs/umich.edu/class/eecs627/w26/groups/group7/project/verilog/tb_in_data.hex', 'w') as f:
        for arr in all_inputs[:n]:
            for val in arr:
                f.write(to_twos_complement_hex(val, 32) + '\n')
    
    # Write expected scale output (8-bit signed)
    with open('/afs/umich.edu/class/eecs627/w26/groups/group7/project/verilog/tb_exp_scale.hex', 'w') as f:
        for arr in all_expected[:n]:
            for val in arr:
                f.write(to_twos_complement_hex(val, 8) + '\n')
    
    print(f"\nGenerated files:")
    print(f"  tb_in_data.hex   - {n * 8} values (32-bit hex)")
    print(f"  tb_exp_scale.hex - {n * 8} values (8-bit hex)")
    print(f"\nUpdate your testbench: TEST_LEN = {n}")
    
    # Also show first few input/expected pairs for verification
    print(f"\nFirst input vector:    {all_inputs[0]}")
    print(f"First expected output: {all_expected[0]}")

if __name__ == '__main__':
    main()