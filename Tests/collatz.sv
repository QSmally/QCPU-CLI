// QCPU 2 boot memory
//
// The 'boot' module is a XIP non-volatile memory starting at address 0. It is
// executed when QCPU 2 starts up. It is 10 bit, contains 1024 bytes, and
// therefore holds a maximum of 512 instructions.

module boot (
    input [9:1] addr,
    output [15:0] instr
);
    logic [15:0] instr_c;

    always_comb begin
        case (addr)
            // @section root (4 bytes)
            'h0000 : instr_c = 16'b1001000110010010; // lli d1, 50
            'h0001 : instr_c = 16'b0001000000010001; // addi ip, .loop + 0
            // @section text (20 bytes)
            'h0002 : instr_c = 16'b0111010001010010; // bsr d1, d1, 1
            'h0003 : instr_c = 16'b0101100000001010; // mask d1, 1
            'h0004 : instr_c = 16'b1011111111110011; // brh z, .not_even + 0
            'h0005 : instr_c = 16'b1111100111000000; // nop
            'h0006 : instr_c = 16'b0111010001010011; // bsr d2, d1, 1
            'h0007 : instr_c = 16'b1011100000000011; // brh z, .done + 0
            'h0008 : instr_c = 16'b0111000001010011; // bsl d2, d1, 1
            'h0009 : instr_c = 16'b0000001000010011; // add d1, d1, d2
            'h000A : instr_c = 16'b0000100000001010; // addi d1, 1
            'h000B : instr_c = 16'b0001011111000001; // addi ip, .loop + 0
            default : instr_c = 'h0000;
        endcase
    end

    assign instr = instr_c;
endmodule
