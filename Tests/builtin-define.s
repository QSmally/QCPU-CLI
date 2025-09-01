
@section root
@region 256
@align 2

_:                u16 .foo

@end

@linkinfo(origin) root, 0
@linkinfo(align) example, 256

@define deadbeef, (0xDE lsh 8) + 0xAD

@section example
foo:              u16 @deadbeef
