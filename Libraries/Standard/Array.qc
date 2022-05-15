
struct Array<Element: Byte>#size: Object {

    weak var pointer: Byte
    var container: Object#size

    asm closure append(_ element: Element) -> Array<Element> {
        @ACCUMULATOR element
        MST self.pointer, 0x00
        INC self.pointer
    }

    asm closure pull() -> Element {
        DEC self.pointer, FWD
        MLD forwarded, 0x00
    }
}
