
@header header1, bar
.mylocallabel:    bkpt .mylocallabel
sublabel1:        header2 bar
@end

@header header2, bar
sublabel2:        bkpt .sublabel2

                  bkpt bar
@end

@section root

_local_label:     bkpt .aaaa.sublabel1.sublabel2

                  bkpt .local_label

aaaa:             header1 .local_label
