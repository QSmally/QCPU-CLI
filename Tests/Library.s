
@define(expose) foo, rb
@define(expose) bar, 0xFFFF

@section text
@align 32 // L1 cache line
spinlock:         inc ra
                  jmpr .baah

@section text
@align 8
.baah:            jmpr .spinlock
