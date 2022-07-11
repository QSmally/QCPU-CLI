
@Parsing(array)
struct Array<Element: Byte>#size {

    var container: Object#size

    nonmemory lazy var pointer: &Object = &self.container

    asm closure append(_ element: Element) {
        @PREPARE:ACCUMULATOR element
        MST self.pointer, 0x00
        INC self.pointer
    }

    asm closure pull() -> Element {
        DEC self.pointer
        FWD
        MLD forwarded, 0x00
        @RETURNS
    }
}
