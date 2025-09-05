
@section root
@region 256
@align 2

_:                u16 .start        ; entrypoint

@end

@linkinfo(origin) root, 0
@linkinfo(align) text, 256

@section text
.start:           bkpt
