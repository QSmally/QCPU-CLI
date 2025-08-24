
@import aaa, "Library.s"

@define roo, 0x05
@define(expose) foo, @roo

@header hdr, a
                  rst @a
@end

@section text
start:            cli
                  @hdr  @aaa.foo
                  jmpr  @foo

@section data
ccc:              u8 255
@align 2
bbb:              u16 @aaa.aaa
