
@section root
@align 2

_:                jmpr .entrypoint

@section text
@align 2

.entrypoint:      bkpt

// physical memory linkage

@linkinfo(origin) root, 0x0800
@linkinfo(align) text, 32
