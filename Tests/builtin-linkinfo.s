
@section root
@region 256
@align 2

_:                u16 .entrypoint

@end

@linkinfo(origin) root, 0
@linkinfo(align) data, 64
@linkinfo(align) bss, 64
@linkinfo(align) text, 256

@section data
counter:          u8 0

@section bss
struct:           reserve u24, 4

@section text
entrypoint:       mld zr, .counter
.loop:            inc zr
                  jmpr .loop
