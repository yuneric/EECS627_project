module level_shifter (
    input IN,
    output reg OUT
);

always @(*) begin
    OUT = `LS_DELAY IN;
end
endmodule;