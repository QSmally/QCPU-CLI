
@import foo, "builtin-define.s"

@define bar, foo.bar

@section root
@align foo.aaa

                  bkpt

@barrier
@align bar

                  bkpt
