
@section root

_:                u16 .foo

@linkinfo(origin) root, 0
@linkinfo(origin) text, 512

@header hdr, x
@align 2

a:                u8 1
.b:               u8 2
c:                u8 3
d:                u8 x

                  u16 .b
@end

@section text

.foo:             u16 .bar.a
                  u16 .bar.a + 10
.bar:             hdr 255
