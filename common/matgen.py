import numpy as np
from scipy import signal

'''
NOTE: All this matmult stuff is in HWC format
'''
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

def mat_gen_3D(rows, cols, depth, lower=-10, upper=10):
    matrix = np.empty((rows, cols, depth), dtype='<U10')
    for mat_idx in range(depth):
        for row in range(rows):
            for col in range(cols):
                matrix[row][col][mat_idx] = str(row*cols + col) + str(chr(ord('a') + mat_idx))
    return matrix

def mat_gen_4D(rows, cols, depth, N, lower=-10, upper=10):
    matrix = np.empty((N, rows, cols, depth), dtype='<U10')
    for filt in range(N):
        for mat_idx in range(depth):
            for row in range(rows):
                for col in range(cols):
                    matrix[filt][row][col][mat_idx] = str(row*cols + col) + str(chr(ord('a') + mat_idx))
    return matrix

def int8_to_hex(val):
    return f"{val.view(dtype=np.uint8):02X}"

def create_mat_hex(filename, matrix):
    print(matrix.shape)
    # dim = matrix.shape
    # with open(filename, w) as file:

def print_2D_matrix(file, matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    file.write(f'Matrix Dim: {dims}\n')
    for row in range(rows):
        for col in range(cols):
            file.write(f'{matrix[row][col]:5d} ' )
        file.write('\n')
    print_mem(file, matrix)

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
    print_mem(file, matrix)

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
    print_mem(file, matrix)

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
    print_mem(file, matrix)

def print_2D_matrix_str(file, matrix):
    dims = matrix.shape
    rows = dims[0]
    cols = dims[1]
    file.write(f'Matrix Dim: {dims}\n')
    for row in range(rows):
        for col in range(cols):
            file.write(f'{matrix[row][col]:>5} ' )
        file.write('\n')
    print_mem(file, matrix)

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
    print_mem(file, matrix)

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
    print_mem(file, matrix)

def print_mem(file, matrix):
    file.write('Mem layout:\n')
    file.write(f"{matrix.ravel()}")
    file.write('\n')

def calc_output_dim(Wi, Hi, Wf, Hf, stride):
    Wo = ((Wi - Wf) // stride) + 1
    Ho = ((Hi - Hf) // stride) + 1
    return Wo, Ho

def convert_HWC_to_CHW_3D(matrix):
    return np.transpose(matrix, (2,0,1))

def convolve_3D(ifmap, filtr):
    new_ifmap = convert_HWC_to_CHW_3D(ifmap)
    new_filtr = convert_HWC_to_CHW_3D(filtr)
    # Technically we want "correlation" because "convolution" actually flips the matrix 180
    result = signal.correlate(new_ifmap, new_filtr, mode='valid')
    # 3D to 2D
    result = result.squeeze()
    return result
