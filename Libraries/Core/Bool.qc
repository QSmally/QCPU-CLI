
@Parsing(boolean)
struct Bool {

    var container: Byte

    asm closure toggle() -> Bool {
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
