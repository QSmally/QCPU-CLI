
@section root
@align 2

_:                bkpt
.foo:             u16 .foo

; _:                lui d1, 0xFF10
                  ; bkpt

_:                jmpl .foo

@linkinfo(origin) root, 781
