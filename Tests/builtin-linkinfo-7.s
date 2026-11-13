
@section root

_:                jmpr .foo

@linkinfo(origin) root, 0
@linkinfo(origin) text, 16
@linkinfo(aligned) data, 2

@section text

.foo:             lua a1, .bar'u
                  jmpr .foo

@section data

.bar:             u16 0xFFFF
