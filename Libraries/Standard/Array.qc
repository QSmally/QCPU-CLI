
@Literal<array<any>>
struct Array<Element: Byte>#size: Object {

    weak var pointer: Byte = 0
    var container: Object#size

    asm closure append(_ element: Element) {
        @PREPARE accumulator element
        MST self.pointer, 0x00
        INC self.pointer
    }

    asm closure pull() -> Element {
        DEC self.pointer
        FWD
        MLD forwarded, 0x00
        @RETURNS accumulator
    }
}
