
@section text

@offset(expose) foo, bar

@if @foo
                  bkpt
@offset(expose) foo, aaa
                  bkpt
@offset(expose) foo, bbb
                  bkpt
                  bkpt
@else
                  bkpt
                  bkpt
@end
