import numpy as np

def to_hex(val, bit_width=8):
    """Converts an integer to a hex string (2's complement for negatives)."""
    val = int(val)
    if val < 0:
        val = (1 << bit_width) + val
    return f"{val:0{bit_width // 4}X}"

class SystolicArrayGolden:
    """
    Cycle-Accurate Weight-Stationary Model.
    """
    def __init__(self, rows, cols):
        self.shape = (rows, cols)
        self.reset()

    def reset(self):
        # act_h: Horizontal wires (Activations). Shape: [Rows, Cols + 1]
        self.act_h = np.zeros((self.shape[0], self.shape[1] + 1)) 
        # psum_v: Vertical wires (Partial Sums). Shape: [Rows + 1, Cols]
        self.psum_v = np.zeros((self.shape[0] + 1, self.shape[1]))
        self.weights = np.zeros(self.shape)
        self.cycle_count = 0

    def load_weights(self, weights):
        self.weights = weights.copy()

    def step(self, input_col):
        """Execute one clock cycle."""
        # Compute Phase
        mac_result = (self.act_h[:, :-1] * self.weights) + self.psum_v[:-1, :]

        # Shift Phase
        self.psum_v[1:, :] = mac_result # Move down
        self.psum_v[0, :]  = 0.0        # Zero pad top
        
        self.act_h[:, 1:] = self.act_h[:, :-1] # Move right
        self.act_h[:, 0]  = input_col          # Load new input

        self.cycle_count += 1
        return self.psum_v[-1, :].copy()

    def run_vector(self, vector):
        rows, cols = self.shape
        output = np.zeros(cols)
        total_cycles = rows + cols + 1
        
        for cycle in range(total_cycles):
            # Skew Inputs
            current_inputs = np.zeros(rows)
            for r in range(rows):
                if cycle == r:
                    current_inputs[r] = vector[r]

            # Step Hardware
            valid_out = self.step(current_inputs)

            # Capture Output
            for c in range(cols):
                if cycle == rows + c:
                    output[c] = valid_out[c]
            
        return output

# Verification & File Export
if __name__ == "__main__":
    R, C = 4, 4
    BIT_WIDTH = 8  # Width for the Hex files
    dut = SystolicArrayGolden(R, C)

    np.random.seed(42)
    # Using small numbers so 8-bit output doesn't overflow easily
    vec_in = np.random.randint(-4, 4, size=R)     
    weights = np.random.randint(-4, 4, size=(R, C))
    
    dut.load_weights(weights)
    hw_result = dut.run_vector(vec_in)

    print("Exporting Test Vectors...")

    with open("weights.txt", "w") as f:
        for r in range(R):
            row_hex = [to_hex(w, BIT_WIDTH) for w in weights[r]]
            f.write(" ".join(row_hex) + "\n")
    print(f" -> Generated 'weights.txt' ({R}x{C})")

    with open("inputs.txt", "w") as f:
        for val in vec_in:
            f.write(to_hex(val, BIT_WIDTH) + "\n")
    print(f" -> Generated 'inputs.txt' ({R} values)")

    with open("outputs.txt", "w") as f:
        for val in hw_result:
            f.write(to_hex(val, BIT_WIDTH) + "\n")
    print(f" -> Generated 'outputs.txt' ({C} values)")

    print("\n[DONE] You can now use $readmemh in Verilog to load these files.")