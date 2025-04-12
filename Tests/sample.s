
@symbols "Library.s"

@define(expose) foo, 0x00

@section text
bar:              cli
                  jmpr  0x00
