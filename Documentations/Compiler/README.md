#  QCPU HLL Compiler

Topics are featured in their own file, and general overview of the syntax is down below.

### Configuration

* `import Library`

### Variable management

* `var foo: Type = start_value`
* `let foo: Type = start_value`
* `mutate foo = foo + bar`

**Allocation and references**
* `weak var foo: Type = start_value`
* `refer var bar: Type = foo`

### Subroutines and embedded code

* `func foo() -> Type { }`
* `func foo(copyable bar: UInt) -> Type { }`
* `func foo(mutable bar: UInt) -> Type { }`

**Embedded code and custom blocks**
* `clos foo() -> Type { }`
* `clos foo() [element: Element]: Bool -> Array<Element> { }`

**Operators and assembly API**
* `oper +(lhs: Int, rhs: Int) -> Int { }`
* `asm oper -(lhs: Int, rsh: Int) -> Int { }`

### Complex data types

**Enumerations**
* `enum Type {}`
    - `case one`

**Structures**
* `struct Something: SomeProtocol { }`
    - `computed var`
    - `lazy var`
    - preprocessed #size constant
    - preprocessed #address start pointer constant

**Protocols**
* `protocol Something { }`
    - `optional var`
    - `internal var`

**Modifiers and hosters**
* `modifier Something { }`
    - `func/clos initialise`
    - `func/clos willSet`
    - `func/clos retrieve`
    - `@Something var`
