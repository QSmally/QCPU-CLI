
@define begin_value, 50

@section root

_:                lli d1, begin_value
                  jmpr .loop

@linkinfo(origin) root, 0
@linkinfo(aligned) text, 2

@section text

.not_even:        bsr d1, d1, 1           ; n/2

.loop:            mask d1, 0x01           ; check odd
                  brh z, .not_even

                  nop

                  bsr d2, d1, 1           ; check 0x0001 >> 1 == 0
.done:            brh z, .done

                  bsl d2, d1, 1           ; 2n
                  add d1, d1, d2          ; 3n
                  addi d1, 1              ; 3n+1
                  jmpr .loop
