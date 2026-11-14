
@section root
@align 2

_:                bkpt
.foo:             u16 .foo

_:                lli d1, 0xFF10
                  bkpt

@linkinfo(origin) root, 781
