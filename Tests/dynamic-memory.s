
@header ubc, label
      brh c, @label
@end

@section root
@region 256
@align 2

_:                u16 .start

@end

@linkinfo(origin) root, 0
@linkinfo(align) data, 256
@linkinfo(align) text, 256

@section data
@region 8

.array:           u8 1
                  u8 2
                  u8 3
                  u8 4
                  u8 5
                  u8 6
                  u8 7
                  u8 8

@end

@section text
.start:           imm ra, 0
.loop:            mld' zr, .array
                  brh z, .end
                  inc zr
                  ast ra
                  mst' zr, .array
                  inc ra
                  @ubc .end
                  jmpr .loop
.end:             bkpt
