
@symbols aaa, "Library.s"

@define roo, 0x05
@define(expose) foo, @roo

@section text
bar:              cli
                  rst   @aaa.foo
                  jmpr  @foo

@section data
ccc:              u8 255
@align 2
bbb:              u16 @aaa.aaa
