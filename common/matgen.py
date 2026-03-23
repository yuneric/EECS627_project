import numpy as np
from scipy import signal

# Global constants
dim = 8
num_arrays = 8
#num_arrays = 8
word_size = 8
bit_size = 8
main_mem_depth = 4096 #32kB each
#main mem depth by word size
main_mem_size = main_mem_depth * word_size
weight_mem_depth = 2048 #16kB each
weight_mem_size = weight_mem_depth * word_size

def int8_to_hex(val):
    return f"{val.view(dtype=np.uint8):02X}"

def calc_output_dim(Wi, Hi, Wf, Hf, stride, padding):
    Wo = ((Wi + 2*padding - Wf) // stride) + 1
    Ho = ((Hi + 2*padding - Hf) // stride) + 1
    return Wo, Ho

def convert_HWC_to_CHW(matrix):
    return np.transpose(matrix, (2,0,1))

def convert_CHW_to_HWC(matrix):
    return np.transpose(matrix, (1,2,0))

def convert_NCHW_to_NHWC(matrix):
    return np.transpose(matrix, (0,2,3,1))

def print_HWC(matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    depth = dims[2]
    print(f'Matrix Dim: {dims}')
    for mat_idx in range(depth):
        print(f'channel = {mat_idx}')
        for row in range(rows):
            for col in range(cols):
                print(f'{matrix[row][col][mat_idx]:>5}', end=' ' )
            print('')
    print('')

def debug_mat_gen_HWC(rows, cols, depth):
    matrix = np.empty((rows, cols, depth), dtype='<U10')
    for mat_idx in range(depth):
        for row in range(rows):
            for col in range(cols):
                matrix[row][col][mat_idx] = str(row*cols + col) + str(chr(ord('a') + mat_idx))
    return matrix

def debug_mat_gen_NHWC(rows, cols, depth, N):
    matrix = np.empty((N, rows, cols, depth), dtype='<U10')
    for filt in range(N):
        for mat_idx in range(depth):
            for row in range(rows):
                for col in range(cols):
                    matrix[filt][row][col][mat_idx] = str(filt) + '.' + str(row*cols + col) + str(chr(ord('a') + mat_idx))
    return matrix


# thanks gemini
def pad_channels_to_word_size(arr, word_size, axis=-1):
    """
    Zero-pads the specified axis of the array to be a multiple of word_size.
    
    Args:
        arr (np.ndarray): Input array (activations or weights).
        word_size (int): The alignment size (e.g., 8).
        axis (int): The dimension to pad. 
                    Use -1 for HWC activations.
                    Use 1 for NCHW weights (to pad Ci).
                    Use 0 for NCHW weights (to pad Co/N).
    
    Returns:
        np.ndarray: The zero-padded array.
    """
    channels = arr.shape[axis]
    remainder = channels % word_size
    
    if remainder == 0:
        return arr

    padding_needed = word_size - remainder
    
    # Construct padding config: list of (before, after) tuples for each dim
    pad_width = [(0, 0)] * arr.ndim
    pad_width[axis] = (0, padding_needed)
    
    return np.pad(arr, pad_width, mode='constant', constant_values=0)

# Takes a numpy matrix in HWC format, pads the channels and turns it into a memory matrix (depth x word_size)
def make_memory_model(HWC_matrix, word_size):
    mem_model = pad_channels_to_word_size(HWC_matrix, word_size)
    mem_model = mem_model.reshape((-1, word_size))
    return mem_model

# Does a 3D convolution with all filters
def do_cnn_layer(ifmap, kernels, stride=1, padding=0):
    # Technically we want "correlation" because "convolution" actually flips the matrix 180
    padded_ifmap = np.pad(ifmap, ((padding, padding), (padding, padding), (0, 0)))
    #print_HWC(padded_ifmap)
    #print(ifmap.shape[1], ifmap.shape[0], kernels.shape[2], kernels.shape[1], stride, padding)
    Wo, Ho = calc_output_dim(ifmap.shape[1], ifmap.shape[0], kernels.shape[2], kernels.shape[1], stride, padding)
    #print(Wo, Ho)
    ofmap = np.empty((Ho, Wo, kernels.shape[0]), dtype=np.int32)
    # print(Wo, Ho)
    for kernel in range(kernels.shape[0]):
        ofmap[:, :, kernel] = do_convolution(padded_ifmap, kernels[kernel], stride)
    return ofmap

# Does a 3D convolution
def do_convolution(ifmap, kernel, stride=1):
    # Technically we want "correlation" because "convolution" actually flips the matrix 180
    result = signal.correlate(ifmap, kernel, mode='valid')
    # 3D to 2D
    result = result.squeeze()
    # print(result)
    result = result[::stride, ::stride]
    # print(result)
    return result


def relu(mat):
    """Element-wise ReLU."""
    return np.maximum(mat, 0)

def scale_clip_sim(mat, shift, out_bits=8):
    """Arithmetic right shift then clip to signed out_bits range."""
    upper = (1 << (out_bits - 1)) - 1   # 127
    lower = -(1 << (out_bits - 1))      # -128
    result = np.zeros_like(mat)
    for i in range(mat.shape[0]):
        for j in range(mat.shape[1]):
            shifted = int(mat[i][j]) >> shift
            result[i][j] = max(lower, min(upper, shifted))
    return result
    
def scale_clip_real(mat, shift, out_bits=8):
    """Arithmetic right shift then clip to signed out_bits range."""
    upper = (1 << (out_bits - 1)) - 1   # 127
    lower = -(1 << (out_bits - 1))      # -128
    result = np.zeros_like(mat)
    for i in range(mat.shape[0]):
        for j in range(mat.shape[1]):
            for k in range(mat.shape[2]):
                shifted = int(mat[i][j][k]) >> shift
                result[i][j][k] = max(lower, min(upper, shifted))
    return result

def maxpool_sim(mat):
    drain_order = mat[::-1, :]  # reversed row order
    buf0 = mat[:dim//2, :]
    buf1 = mat[dim//2:, :]
    n_out = dim // 4
    golden_out = np.zeros((n_out, dim), dtype=np.int32)
    for i in range(n_out):
        for ch in range(dim):
            p0 = buf0[2*i,   ch]
            p1 = buf0[2*i+1, ch]
            p2 = buf1[2*i,   ch]
            p3 = buf1[2*i+1, ch]
            golden_out[i, ch] = max(p0, p1, p2, p3)
    return golden_out

def maxpool_real(mat):
    H = mat.shape[0]//2
    W = mat.shape[1]//2
    C = mat.shape[2]
    output = np.zeros((H, W, C), dtype=np.int32)
    for row in range(H):
        for col in range(W):
            for ch in range(C):
                p0 = mat[2*row,   2*col,   ch]
                p1 = mat[2*row,   2*col+1, ch]
                p2 = mat[2*row+1, 2*col,   ch]
                p3 = mat[2*row+1, 2*col+1, ch]
                output[row, col, ch] = max(p0, p1, p2, p3)
    return output


###############################################################
# Everything below this is pretty much only used in im2col.py #
###############################################################

def rand_mat_gen_2D(rows, cols, lower=-10, upper=10):
    return np.random.randint(lower, upper, (rows, cols), dtype=np.int8)

def rand_mat_gen_3D(rows, cols, depth, lower=-10, upper=10):
    # Generate the matrix in HWC form (channel-first)
    # instead of CHW [ row[0]col[0]channel[0], row[0]col[1]channel[0], row[0]col[2]channel[0], ... ]
    # do HWC [ row[0]col[0]channel[0], row[0]col[0]channel[1], row[0]col[0]]channel[2], row[0]col[1]channel[0], ...]
    # its like storing rgb[0], rgb[1], rgb[2] instead of r[0] r[1] r[2] g[0] g[1] ...
    return np.random.randint(lower, upper, (rows, cols, depth), dtype=np.int8)

def rand_mat_gen_4D(rows, cols, depth, N, lower=-10, upper=10):
    return np.random.randint(lower, upper, (N, rows, cols, depth), dtype=np.int8)

def mat_gen_3D(rows, cols, depth):
    matrix = np.empty((rows, cols, depth), dtype='<U10')
    for mat_idx in range(depth):
        for row in range(rows):
            for col in range(cols):
                matrix[row][col][mat_idx] = str(row*cols + col) + str(chr(ord('a') + mat_idx))
    return matrix

def mat_gen_4D(rows, cols, depth, N):
    matrix = np.empty((N, rows, cols, depth), dtype='<U10')
    for filt in range(N):
        for mat_idx in range(depth):
            for row in range(rows):
                for col in range(cols):
                    matrix[filt][row][col][mat_idx] = str(row*cols + col) + str(chr(ord('a') + mat_idx))
    return matrix

def print_2D_matrix(file, matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    file.write(f'Matrix Dim: {dims}\n')
    for row in range(rows):
        for col in range(cols):
            file.write(f'{matrix[row][col]:5d} ' )
        file.write('\n')
    file.write('\n')

def print_3D_matrix_CHW(file, matrix):
    dims = matrix.shape
    depth = dims[0]
    rows = dims[1]
    cols = dims[2]
    file.write(f'Matrix Dim: {dims}\n')
    for mat_idx in range(depth):
        file.write(f'channel = {mat_idx}\n')
        for row in range(rows):
            for col in range(cols):
                file.write(f'{matrix[mat_idx][row][col]:5d} ' )
            file.write('\n')
    file.write('\n')

def print_3D_matrix(file, matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    depth = dims[2]
    file.write(f'Matrix Dim: {dims}\n')
    for mat_idx in range(depth):
        file.write(f'channel = {mat_idx}\n')
        for row in range(rows):
            for col in range(cols):
                file.write(f'{matrix[row][col][mat_idx]:5d} ' )
            file.write('\n')
    file.write('\n')

def print_4D_matrix(file, matrix):
    dims = matrix.shape
    N = dims[0]
    rows = dims[1]
    cols = dims[2]
    depth = dims[3]
    file.write(f'Matrix Dim: {dims}\n')
    for filt in range(N):
        file.write(f'filter: {filt}\n')
        for mat_idx in range(depth):
            file.write(f'channel: {mat_idx}\n')
            for row in range(rows):
                for col in range(cols):
                    file.write(f'{matrix[filt][row][col][mat_idx]:5d} ' )
                file.write('\n')
        file.write('\n')
    file.write('\n')

def print_2D_matrix_str(file, matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    file.write(f'Matrix Dim: {dims}\n')
    for row in range(rows):
        for col in range(cols):
            file.write(f'{matrix[row][col]:>5} ' )
        file.write('\n')
    file.write('\n')

def print_3D_matrix_str(file, matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    depth = dims[2]
    file.write(f'Matrix Dim: {dims}\n')
    for mat_idx in range(depth):
        file.write(f'channel = {mat_idx}\n')
        for row in range(rows):
            for col in range(cols):
                file.write(f'{matrix[row][col][mat_idx]:>5} ' )
            file.write('\n')
    file.write('\n')

def print_4D_matrix_str(file, matrix):
    dims = matrix.shape
    N = dims[0]
    rows = dims[1]
    cols = dims[2]
    depth = dims[3]
    file.write(f'Matrix Dim: {dims}\n')
    for filt in range(N):
        file.write(f'filter: {filt}\n')
        for mat_idx in range(depth):
            file.write(f'channel: {mat_idx}\n')
            for row in range(rows):
                for col in range(cols):
                    file.write(f'{matrix[filt][row][col][mat_idx]:>5} ' )
                file.write('\n')
        file.write('\n')
    file.write('\n')

def print_mem(file, matrix):
    file.write('Mem layout:\n')
    file.write(f"{matrix.ravel()}\n")
    file.write('\n')

import numpy as np

# Thanks Gemini (im tired) grok > gemini
def write_hex_3D(matrix, file, word_width_bytes=4, little_endian=True):
    # Flatten matrix to a 1D stream of bytes
    # Ensure it's int8 and then cast to unsigned 8-bit to handle negative hex values correctly
    raw_bytes = matrix.flatten().astype(np.int8).view(np.uint8)
    
    # Calculate how many words we have
    num_bytes = len(raw_bytes)
    
    for i in range(0, num_bytes, word_width_bytes):
        # Grab a slice of bytes equal to the word width
        chunk = raw_bytes[i : i + word_width_bytes]
        
        # Handle padding if the matrix size isn't perfectly divisible by word_width
        if len(chunk) < word_width_bytes:
            padding = np.zeros(word_width_bytes - len(chunk), dtype=np.uint8)
            chunk = np.concatenate((chunk, padding))
        
        if little_endian:
            # [Byte0, Byte1, Byte2, Byte3] -> Byte3Byte2Byte1Byte0
            word_hex = "".join(f"{b:02X}" for b in reversed(chunk))
        else:
            # [Byte0, Byte1, Byte2, Byte3] -> Byte0Byte1Byte2Byte3
            word_hex = "".join(f"{b:02X}" for b in chunk)
            
        file.write(word_hex + '\n')

# Does a 3D convolution
def convolve_3D(ifmap, filtr, stride=1):
    new_ifmap = convert_HWC_to_CHW(ifmap)
    new_filtr = convert_HWC_to_CHW(filtr)
    # Technically we want "correlation" because "convolution" actually flips the matrix 180
    result = signal.correlate(new_ifmap, new_filtr, mode='valid')
    # 3D to 2D
    result = result.squeeze()
    result = result[::stride, ::stride]
    return result