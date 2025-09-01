
@header cs, reg, offset
                  ast @reg
                  mst sf, @offset
@end

@section root
@region 256
@align 2

_:                u16 .foo

@end

@linkinfo(origin) root, 0
@linkinfo(align) example, 256

@section example
foo:              clr
                  @cs ra, 4
                  @cs rb, 8
                  bkpt
