#  QCPU HLL Compiler

Topics are featured in their own file, and general overview of the syntax is down below.

### Configuration

* `import Library`

### Variable management

* `var foo: Type = start_value`
* `let foo: Type = start_value`
* `mutate foo = foo + bar`

**Allocation registers and references**
* `weak var in_reg: Type = start_value`
* `weak var dyn_ref: &Type = &foo`
* TODO: generic pointer types and operations (UInt, Byte)

### Subroutines and embedded code

* `func foo() -> Type { }`
* `func foo(copyable bar: Type) -> Type { }`
* `func foo(mutable bar: Type) -> Type { }`

**Embedded code and custom blocks**
* `clos foo() -> Type { }`
* `clos foo() [element: Element]: Bool -> Array<Element> { }`

**Operators and assembly API**
* `oper inc(rhs: Int) -> Int { }`
* `oper mod(lhs: Int, rhs: Int) -> Int { }`
* `asm oper -(lhs: Int, rsh: Int) -> Int { }`

### Complex data types

**Enumerations**
* `enum Type {}`
    - `case one`

**Structures**
* `struct Something: SomeProtocol { }`
    - `computed var`
    - `lazy var`
    - preprocessed `size` constant
    - preprocessed `address` start pointer constant

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
