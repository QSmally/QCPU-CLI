
@Literal<boolean>
struct Bool: Byte {

    var container: Byte

    asm closure toggle() -> Bool {
        @PREPARE accumulator self.container
        NTA
        @WRITEBACK self.container
        @RETURNS self.container
    }

    asm operator not(target: Bool) -> Bool {
        @PREPARE accumulator target
        NTA
        @WRITEBACK target
        @RETURNS target
    }
}
