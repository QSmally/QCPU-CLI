
@import root, "root.s"
@import library, "Library.s"

@define roo, 0x05
@define(expose) foo, @roo

@header hdr, a
                  rst @a
@end

@section text
start:            clr
                  imm   zr, @foo
                  bsl   1
                  rst   ra
                  mld   zr, .root.flags + 1
                  @hdr  @library.foo
                  jmpr  .library.spinlock

@section data
dead:             u8 255
@align 2
beef:             u16 @library.bar
