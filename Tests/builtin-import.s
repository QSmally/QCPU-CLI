
@import library, "builtin-import-2.s"

@section root
@region 256
@align 2

_:                u16 .foo

@end

@linkinfo(origin) root, 0
@linkinfo(align) example, 256

@section example
foo:              jmpr .library.foo
