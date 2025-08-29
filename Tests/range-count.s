
@section root
@region 256
@align 2

_:                u16 .main         // entrypoint

@end

@linkinfo(origin) root, 0
@linkinfo(align) text, 256

@define countdown, 10

@section text
.main:            imm zr, @countdown
.loop:            dec zr
                  brh nz, .loop
                  jmpr .main
