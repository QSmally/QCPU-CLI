
@section root
@region 256
@align 2

_:                u16 .main         // entrypoint
                  u16 0             // interrupt
                  u16 0             // reserved
                  u16 0             // flags
                  u16 .stack        // sf
                  u16 .stack        // sp

@end

@linkinfo(origin) root, 0
@linkinfo(align) text, 256
@linkinfo(align) stack, 256

@define recursive_len, 5

@section stack
.stack:           reserve u8, 256

@section text
.main:            imm zr, @recursive_len
                  jmprl .subroutine
                  bkpt

@barrier

.subroutine:      dec zr
                  brh z, .ret
                  jmprl .subroutine
.ret:             ret
