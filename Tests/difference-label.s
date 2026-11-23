
@section root

_:                u16 &foo.len

@linkinfo(origin) root, 0
@linkinfo(origin) data, 8

@section data

.foo:             ascii "abcd"
.foo.len:         reserve u8, 0
