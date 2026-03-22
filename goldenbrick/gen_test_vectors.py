#!/usr/bin/env python3
"""
Generate test vectors and golden results for systolic array system testbench.
Writes hex files that the Verilog TB reads via $readmemh.

Test flow per case:
  1. Generate random A (activations) and W (weights) matrices
  2. Compute C = A * W (golden matmul)
  3. Apply ReLU if enabled: C[i] = max(0, C[i])
  4. Apply scale_clip: C[i] = clip(C[i] >> shift, -128, 127)
  5. Optionally apply maxpool
  6. Write stimulus (A rows, W cols) and golden output to hex files

The Verilog TB drives the frontend FIFO interface and compares outputs.
"""

import numpy as np
import os
import json

def to_twos_comp(val, bits):
    """Convert signed integer to two's complement hex string."""
    mask = (1 << bits) - 1
    return int(val) & mask

def pack_vector_hex(vec, elem_bits):
    """Pack a vector of signed ints into a single hex string (element 0 = LSB)."""
    total_bits = len(vec) * elem_bits
    packed = 0
    for i, v in enumerate(vec):
        packed |= to_twos_comp(int(v), elem_bits) << (i * elem_bits)
    return format(packed, '0{}x'.format(total_bits // 4))

def relu(mat):
    """Element-wise ReLU."""
    return np.maximum(mat, 0)

def scale_clip(mat, shift, out_bits=8):
    """Arithmetic right shift then clip to signed out_bits range."""
    upper = (1 << (out_bits - 1)) - 1   # 127
    lower = -(1 << (out_bits - 1))      # -128
    result = np.zeros_like(mat)
    for i in range(mat.shape[0]):
        for j in range(mat.shape[1]):
            shifted = int(mat[i][j]) >> shift
            result[i][j] = max(lower, min(upper, shifted))
    return result

def generate_simple_test_case(test_id, dim, data_len, act_range, weight_range,
                       relu_en, shift_by, maxpool_en, out_dir):
    """Generate one test case: stimulus files + golden output."""

    np.random.seed(42 + test_id)

    if(data_len % dim != 0):
        print("ERROR: data length is not a multiple of array dimension")
        exit(1)

    A = np.zeros((dim, data_len)).astype(np.int64)
    W = np.zeros((data_len, dim)).astype(np.int64)

    for row in range(dim):
        A[row, :] += row + 1

    for col in range(dim):
        W[:, col] += col + 1

    A = np.clip(A, -128, 127)
    W = np.clip(W, -128, 127)

    # Golden matmul (32-bit psum)
    C = np.matmul(A, W).astype(np.int64)

    # Backend golden model
    C_relu = relu(C).astype(np.int64) if relu_en else C.copy()
    C_scaled = scale_clip(C_relu, shift_by, 8).astype(np.int64)

    # During drain, the array outputs rows in reverse order (bottom row first).
    # The backend receives them in that order.
    # For maxpool disabled, the passthrough preserves that order.
    # The TB will capture them and reverse to normal row order for comparison.

    # Maxpool(N, Hf, Wf, Ci)
    if maxpool_en and dim >= 4:
        # Drain order (reversed rows) goes into maxpool.
        # Maxpool collects dim/2 rows into buf0, dim/2 into buf1, then 2x2 max.
        # The drain-order rows entering maxpool are: C_scaled[dim-1], C_scaled[dim-2], ..., C_scaled[0]
        drain_order = C_scaled[::-1, :]  # reversed row order
        buf0 = drain_order[:dim//2, :]
        buf1 = drain_order[dim//2:, :]
        n_out = dim // 4
        golden_out = np.zeros((n_out, dim), dtype=np.int64)
        for i in range(n_out):
            for ch in range(dim):
                p0 = buf0[2*i,   ch]
                p1 = buf0[2*i+1, ch]
                p2 = buf1[2*i,   ch]
                p3 = buf1[2*i+1, ch]
                golden_out[i, ch] = max(p0, p1, p2, p3)
        num_output_rows = n_out
    else:
        # No maxpool: output is in drain order (reversed).
        # TB captures in drain order, so golden should match drain order.
        golden_out = C_scaled[::-1, :]
        num_output_rows = dim

    # --- Write stimulus files ---
    prefix = os.path.join(out_dir, f"test{test_id}")

    # Activation rows (row 0 to dim-1, one per FIFO write)
    with open(f"{prefix}_act.hex", 'w') as f:
        for col_idx in range(0, data_len, dim):
            for row_idx in range(dim):
                f.write(pack_vector_hex(A[row_idx, col_idx:(col_idx+dim)], dim) + '\n')

    # Weight columns (col 0 to dim-1, one per FIFO write)
    with open(f"{prefix}_weight.hex", 'w') as f:
        for row_idx in range(0, data_len, dim):
            for col_idx in range(dim):
                f.write(pack_vector_hex(W[row_idx:(row_idx+dim), col_idx], dim) + '\n')

    # Golden output (in the order the TB will see them)
    with open(f"{prefix}_golden.hex", 'w') as f:
        for r in range(num_output_rows):
            f.write(pack_vector_hex(golden_out[r, :], 8) + '\n')

    # Raw psum golden (drain order = reversed rows) for array-only debug
    with open(f"{prefix}_psum_golden.hex", 'w') as f:
        for r in range(dim - 1, -1, -1):
            C_row = np.matmul(A, W)[r, :].astype(np.int64)
            f.write(pack_vector_hex(C_row, 32) + '\n')

    # Verilog-readable config (one hex value per line)
    with open(f"{prefix}_config.hex", 'w') as f:
        f.write(f"{dim:04x}\n") # array size
        f.write(f"{int(relu_en):04x}\n") # relu en
        f.write(f"{shift_by:04x}\n")     # scale amount
        f.write(f"{int(maxpool_en):04x}\n") # maxpool en
        f.write(f"{num_output_rows:04x}\n") # num output rows
        f.write(f"{data_len:04x}\n") # len of data

    # Human-readable info
    matmul_result = np.matmul(A, W)
    print(f"Test {test_id}: {dim}x{dim} matmul, relu={'ON' if relu_en else 'OFF'}, "
          f"shift={shift_by}, maxpool={'ON' if maxpool_en else 'OFF'}, "
          f"expect {num_output_rows} output rows, "
          f"data_len={data_len}")
    if(data_len <= 16):
        print(f"  A:\n{A}")
        print(f"  W:\n{W}")
    
    print(f"  A*W:\n{matmul_result}")
    if relu_en:
        print(f"  After ReLU:\n{relu(matmul_result)}")
    print(f"  After scale_clip (shift={shift_by}):\n{C_scaled}")
    print(f"  Golden output ({num_output_rows} rows, in output order):\n{golden_out}")
    print()

    return {
        'test_id': test_id,
        'dim': dim,
        'relu_en': int(relu_en),
        'shift_by': shift_by,
        'maxpool_en': int(maxpool_en),
        'num_output_rows': num_output_rows,
    }

def generate_test_case(test_id, dim, data_len, act_range, weight_range,
                       relu_en, shift_by, maxpool_en, out_dir):
    """Generate one test case: stimulus files + golden output."""

    np.random.seed(42 + test_id)

    if(data_len % dim != 0):
        print("ERROR: data length is not a multiple of array dimension")
        exit(1)

    A = np.random.randint(act_range[0], act_range[1] + 1, size=(dim, data_len)).astype(np.int64)
    W = np.random.randint(weight_range[0], weight_range[1] + 1, size=(data_len, dim)).astype(np.int64)

    A = np.clip(A, -128, 127)
    W = np.clip(W, -128, 127)

    # Golden matmul (32-bit psum)
    C = np.matmul(A, W).astype(np.int64)

    # Backend golden model
    C_relu = relu(C).astype(np.int64) if relu_en else C.copy()
    C_scaled = scale_clip(C_relu, shift_by, 8).astype(np.int64)

    # During drain, the array outputs rows in reverse order (bottom row first).
    # The backend receives them in that order.
    # For maxpool disabled, the passthrough preserves that order.
    # The TB will capture them and reverse to normal row order for comparison.

    # Maxpool
    if maxpool_en and dim >= 4:
        # Drain order (reversed rows) goes into maxpool.
        # Maxpool collects dim/2 rows into buf0, dim/2 into buf1, then 2x2 max.
        # The drain-order rows entering maxpool are: C_scaled[dim-1], C_scaled[dim-2], ..., C_scaled[0]
        drain_order = C_scaled[::-1, :]  # reversed row order
        buf0 = drain_order[:dim//2, :]
        buf1 = drain_order[dim//2:, :]
        n_out = dim // 4
        golden_out = np.zeros((n_out, dim), dtype=np.int64)
        for i in range(n_out):
            for ch in range(dim):
                p0 = buf0[2*i,   ch]
                p1 = buf0[2*i+1, ch]
                p2 = buf1[2*i,   ch]
                p3 = buf1[2*i+1, ch]
                golden_out[i, ch] = max(p0, p1, p2, p3)
        num_output_rows = n_out
    else:
        # No maxpool: output is in drain order (reversed).
        # TB captures in drain order, so golden should match drain order.
        golden_out = C_scaled[::-1, :]
        num_output_rows = dim

    # --- Write stimulus files ---
    prefix = os.path.join(out_dir, f"test{test_id}")

    # Activation rows (row 0 to dim-1, one per FIFO write)
    with open(f"{prefix}_act.hex", 'w') as f:
        for col_idx in range(0, data_len, dim):
            for row_idx in range(dim):
                f.write(pack_vector_hex(A[row_idx, col_idx:(col_idx+dim)], dim) + '\n')

    # Weight columns (col 0 to dim-1, one per FIFO write)
    with open(f"{prefix}_weight.hex", 'w') as f:
        for row_idx in range(0, data_len, dim):
            for col_idx in range(dim):
                f.write(pack_vector_hex(W[row_idx:(row_idx+dim), col_idx], dim) + '\n')

    # Golden output (in the order the TB will see them)
    with open(f"{prefix}_golden.hex", 'w') as f:
        for r in range(num_output_rows):
            f.write(pack_vector_hex(golden_out[r, :], 8) + '\n')

    # Raw psum golden (drain order = reversed rows) for array-only debug
    with open(f"{prefix}_psum_golden.hex", 'w') as f:
        for r in range(dim - 1, -1, -1):
            C_row = np.matmul(A, W)[r, :].astype(np.int64)
            f.write(pack_vector_hex(C_row, 32) + '\n')

    # Verilog-readable config (one hex value per line)
    with open(f"{prefix}_config.hex", 'w') as f:
        f.write(f"{dim:04x}\n") # array size
        f.write(f"{int(relu_en):04x}\n") # relu en
        f.write(f"{shift_by:04x}\n")     # scale amount
        f.write(f"{int(maxpool_en):04x}\n") # maxpool en
        f.write(f"{num_output_rows:04x}\n") # num output rows
        f.write(f"{data_len:04x}\n") # len of data

    # Human-readable info
    matmul_result = np.matmul(A, W)
    print(f"Test {test_id}: {dim}x{dim} matmul, relu={'ON' if relu_en else 'OFF'}, "
          f"shift={shift_by}, maxpool={'ON' if maxpool_en else 'OFF'}, "
          f"expect {num_output_rows} output rows, "
          f"data_len={data_len}")
    if(data_len <= 16):
        print(f"  A:\n{A}")
        print(f"  W:\n{W}")
    
    print(f"  A*W:\n{matmul_result}")
    if relu_en:
        print(f"  After ReLU:\n{relu(matmul_result)}")
    print(f"  After scale_clip (shift={shift_by}):\n{C_scaled}")
    print(f"  Golden output ({num_output_rows} rows, in output order):\n{golden_out}")
    print()

    return {
        'test_id': test_id,
        'dim': dim,
        'relu_en': int(relu_en),
        'shift_by': shift_by,
        'maxpool_en': int(maxpool_en),
        'num_output_rows': num_output_rows,
    }

def main():
    out_dir = "test_vectors"
    os.makedirs(out_dir, exist_ok=True)

    configs = []
    dim = 8

    # Test 0: Small values, no backend, basic matmul check
    configs.append(generate_simple_test_case(
        test_id=0, 
        dim=dim, data_len=dim,
        act_range=(-4, 4), weight_range=(-4, 4),
        relu_en=False, shift_by=0, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 1: ReLU on, no scale
    configs.append(generate_test_case(
        test_id=1, 
        dim=dim, data_len=dim,
        act_range=(-10, 10), weight_range=(-10, 10),
        relu_en=True, shift_by=0, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 2: Scale only (needs shift to fit int8)
    configs.append(generate_test_case(
        test_id=2, 
        dim=dim, data_len=dim,
        act_range=(-50, 50), weight_range=(-50, 50),
        relu_en=False, shift_by=4, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 3: ReLU + scale
    configs.append(generate_test_case(
        test_id=3, 
        dim=dim, data_len=dim,
        act_range=(-50, 50), weight_range=(-50, 50),
        relu_en=True, shift_by=4, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 4: Full pipeline with maxpool
    configs.append(generate_test_case(
        test_id=4, 
        dim=dim, data_len=dim,
        act_range=(-20, 20), weight_range=(-20, 20),
        relu_en=True, shift_by=4, maxpool_en=True,
        out_dir=out_dir
    ))

    # Test 5: Tiny values, no clipping
    configs.append(generate_test_case(
        test_id=5, 
        dim=dim, data_len=dim,
        act_range=(-3, 3), weight_range=(-3, 3),
        relu_en=False, shift_by=0, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 6: Large values, heavy clipping
    configs.append(generate_test_case(
        test_id=6, 
        dim=dim, data_len=dim,
        act_range=(-128, 127), weight_range=(-128, 127),
        relu_en=True, shift_by=8, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 7: Maxpool without relu
    configs.append(generate_test_case(
        test_id=7, 
        dim=dim, data_len=dim,
        act_range=(-20, 20), weight_range=(-20, 20),
        relu_en=False, shift_by=4, maxpool_en=True,
        out_dir=out_dir
    ))

    # CODE THAT IS MADE IN GODS IMAGE TAKES OVER NOW

    # Test 8: Bigger is better
    configs.append(generate_simple_test_case(
        test_id=8, 
        dim=dim, data_len=dim*2,
        act_range=(-64, 64), weight_range=(-64, 64),
        relu_en=False, shift_by=0, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 9: BIGGER
    configs.append(generate_test_case(
        test_id=9, 
        dim=dim, data_len=dim*10,
        act_range=(-128, 127), weight_range=(-128, 127),
        relu_en=False, shift_by=8, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 10: RAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGH
    configs.append(generate_test_case(
        test_id=10, 
        dim=dim, data_len=dim*100,
        act_range=(-128, 127), weight_range=(-128, 127),
        relu_en=False, shift_by=12, maxpool_en=False,
        out_dir=out_dir
    ))

    # Test 11: Bigger is better WHEN YOU MAX IT
    configs.append(generate_test_case(
        test_id=11, 
        dim=dim, data_len=dim*2,
        act_range=(-64, 64), weight_range=(-64, 64),
        relu_en=True, shift_by=8, maxpool_en=True,
        out_dir=out_dir
    ))

    # Test 12: BIGGER MAX IT
    configs.append(generate_test_case(
        test_id=12, 
        dim=dim, data_len=dim*10,
        act_range=(-128, 127), weight_range=(-128, 127),
        relu_en=True, shift_by=8, maxpool_en=True,
        out_dir=out_dir
    ))

    # Test 13: RAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGH MAX IT
    configs.append(generate_test_case(
        test_id=13, 
        dim=dim, data_len=dim*100,
        act_range=(-128, 127), weight_range=(-128, 127),
        relu_en=True, shift_by=12, maxpool_en=True,
        out_dir=out_dir
    ))

    # Write number of tests
    with open(os.path.join(out_dir, "num_tests.hex"), 'w') as f:
        f.write(f"{len(configs):02x}\n")

    print(f"Generated {len(configs)} test cases in {out_dir}/")


if __name__ == "__main__":
    main()