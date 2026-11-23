
@header someheader
field1:           u16 1
field2:           u16 2
field3:           u16 3
field4:           u16 4
@end

@section root

_:                u16 &foo.field2

@linkinfo(origin) root, 0
@linkinfo(origin) data, 8

@section data

.foo:             someheader
