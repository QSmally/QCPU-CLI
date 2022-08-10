
@Parsing(boolean)
struct Bool {

    var container: Byte

    asm inline func conditional() flags(notzero) {
        @PREPARE:ACCUMULATOR self.container
    }

    asm inline func toggle() -> Bool {
        @PREPARE:ACCUMULATOR self.container
        NTA
        @WRITEBACK self.container
        @RETURNS self.container
    }

    asm operator not(target: Bool) -> Bool {
        @PREPARE:ACCUMULATOR target
        NTA
        @WRITEBACK target
        @RETURNS target
    }
}
