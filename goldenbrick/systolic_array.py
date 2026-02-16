import numpy as np
import copy

from delay import skew_buf

def to_hex(val, bit_width=8):
    """Converts an integer to a hex string (2's complement for negatives)."""
    val = int(val)
    if val < 0:
        val = (1 << bit_width) + val
    return f"{val:0{bit_width // 4}X}"

class SystolicArrayGolden:
    """
    Cycle-Accurate Output-Stationary Model.
    """
    def __init__(self, dim):
        self.dim = dim
        self.shape = (dim, dim)
        self.reset()

    def reset(self):
        # act_h: Horizontal wires (Activations). Shape: [Rows, Cols + 1]
        self.act_h = np.zeros((self.shape[0], self.shape[1])) 
        # psum_v: Vertical wires (Partial Sums). Shape: [Rows + 1, Cols]
        self.weights_v = np.zeros((self.shape[0], self.shape[1]))
        self.sum_v = np.zeros((self.shape[0]+1, self.shape[1])) # Make the sum have an extra row so we can really shift everything out
        self.shift_cycle = 0

    def step(self, left_input, top_input, shift_out):
        """Execute one clock cycle."""
        if(shift_out == 0):
            # Compute Phase
            mac_result = (self.act_h[:, :] * self.weights_v[:, :]) + self.sum_v[:-1, :]

            # Shift Phase
            self.sum_v[:-1, :] = mac_result # new sum
            
            self.act_h[:, 1:] = self.act_h[:, :-1] # Move right
            self.act_h[:, 0]  = left_input         # Load new input

            self.weights_v[1:, :] = self.weights_v[:-1, :] # Move right
            self.weights_v[0, :]  = top_input         # Load new input
        else:
            # Extract sum phase
            output = copy.deepcopy(self.sum_v[-1])
            self.sum_v[1:, :] = self.sum_v[:-1, :]
            self.sum_v[0] = np.zeros(self.dim)
            
            return output

class SystolicArraySkewed:
    """
    Cycle-Accurate Output-Stationary Model with skew
    """
    def __init__(self, dim):
        self.dim = dim
        self.array = SystolicArrayGolden(dim)
        self.left_skew = skew_buf(dim)
        self.top_skew = skew_buf(dim)
        self.reset()

    def reset(self):
        self.array.reset()
        self.left_skew.reset()
        self.top_skew.reset()

        self.left_in = np.zeros(self.dim)
        self.top_in  = np.zeros(self.dim)
        self.output  = np.zeros(self.dim)

    def step(self, left_input, top_input, shift_out):
        """Execute one clock cycle."""
        self.output = self.array.step(self.left_in, self.top_in, shift_out)
        self.left_in = self.left_skew.skew_left(left_input)
        self.top_in = self.top_skew.skew_top(top_input)

        return self.output
        

# Verification & File Export
if __name__ == "__main__":
    dim = 8
    BIT_WIDTH = 8  # Width for the Hex files
    dut = SystolicArraySkewed(dim)

    #np.random.seed(42)
    # Using small numbers so 8-bit output doesn't overflow easily
    activations = np.random.randint(-4, 4, size=(dim, dim))     
    weights = np.random.randint(-4, 4, size=(dim, dim))

    # activations = np.array([[1, 1, 1, 1],
    #                         [2, 2, 2, 2],
    #                         [3, 3, 3, 3],
    #                         [4, 4, 4, 4]])
    # weights = np.array([[1, 1, 1, 1],
    #                     [2, 2, 2, 2],
    #                     [3, 3, 3, 3],
    #                     [4, 4, 4, 4]])
    
    num_cycles = 42
    data_idx = 0
    print('cycle | left_input | top_input | left_in | top_in')
    print('sums')
    for cycle in range(num_cycles):
        left_input = np.zeros(dim)
        top_input = np.zeros(dim)
        if(data_idx < dim):
            left_input = activations[:, data_idx]
            top_input = weights[data_idx, :]
            data_idx += 1
        print(f'{cycle} | {left_input} | {top_input} | {dut.left_in} | {dut.top_in}')
        #print(dut.array.sum_v)
        dut.step(left_input, top_input, 0)

    num_outputs = dim
    output_arr = np.zeros((dim, dim))
    for output in range(num_outputs):
        output_arr[dim - 1 - output] = dut.step(None, None, 1)

    # Check output
    golden_result = np.matmul(activations, weights)
    for row in range(num_outputs):
        for col in range(num_outputs):
            if(output_arr[row][col] != golden_result[row][col]):
                print("ERROR: Systolic array output doesn't match a matmult")
    
    # print("Exporting Test Vectors...")

    # with open("weights.txt", "w") as f:
    #     for r in range(dim):
    #         row_hex = [to_hex(w, BIT_WIDTH) for w in weights[r]]
    #         f.write(" ".join(row_hex) + "\n")
    # print(f" -> Generated 'weights.txt' ({dim}x{})")

    # with open("inputs.txt", "w") as f:
    #     for val in vec_in:
    #         f.write(to_hex(val, BIT_WIDTH) + "\n")
    # print(f" -> Generated 'inputs.txt' ({R} values)")

    # with open("outputs.txt", "w") as f:
    #     for val in hw_result:
    #         f.write(to_hex(val, BIT_WIDTH) + "\n")
    # print(f" -> Generated 'outputs.txt' ({C} values)")

    # print("\n[DONE] You can now use $readmemh in Verilog to load these files.")