
@define begin_value, 50

@section root

_:                lui d1, begin_value
                  jmpr .loop

@section text

.not_even:        bsr d1, d1, 1

.loop:            mask d1, 0x01
                  brh c, .not_even

                  bsl d2, d1, 1
                  add d1, d1, d2
                  jmpr .loop
