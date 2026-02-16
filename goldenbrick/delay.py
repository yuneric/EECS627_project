import numpy as np

class delay_buf:
    def __init__(self, max_delay):
        self.size = max_delay
        self.reset()

    def reset(self):
        self.delay_buf = np.zeros((self.size))

    def delay(self, val):
        output = self.delay_buf[-1]
        self.delay_buf[1:] = self.delay_buf[:-1]
        self.delay_buf[0] = val
        return output

# Skew buffer for systolic array
class skew_buf:
    def __init__(self, max_delay):
        self.size = max_delay
        self.reset()

    def reset(self):
        self.delay_buf = np.zeros((self.size, self.size))
        
    def skew_left(self, input_col):
        output_col = np.zeros((self.size))
        for idx in range(self.size):
            output_col[idx] = self.delay_buf[idx][idx]
        self.delay_buf[:, 1:] = self.delay_buf[:, :-1]
        self.delay_buf[:, 0] = input_col
        return output_col

    def skew_top(self, input_row):
        output_col = np.zeros((self.size))
        for idx in range(self.size):
            output_col[idx] = self.delay_buf[idx][idx]
        self.delay_buf[1:, :] = self.delay_buf[:-1, :]
        self.delay_buf[0, :] = input_row
        return output_col

class serializer:
    def __init__(self, word_size):
        self.word_size = word_size
        self.reset()

    def reset(self):
        self.serial_buf = np.zeros(self.word_size)

    def step(self, shift, input_data, data_valid):
        output = self.serial_buf[0]
        if(shift == 1):
            self.serial_buf[:-1] = self.serial_buf[1:]
        if(data_valid == 1):
            self.serial_buf = input_data
        return output

