
struct Bool: Byte {

    var container: Byte

    asm closure toggle() -> Bool {
        XOR self.container
    }

    asm operator not(target: Bool) -> Bool {
        @ACCUMULATOR target
        NTA
    }
}
