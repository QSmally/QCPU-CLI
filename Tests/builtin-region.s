
@section root
@region 256
@align 2

_:                u16 .foo

@end

@linkinfo(origin) root, 0
@linkinfo(align) example, 256

@section example
@region 8

foo:              u16 0xDEAD
                  u16 0xBEEF

@end
