//
//  StorageComponent.swift
//  QCPU CLI
//
//  Created by Joey Smalen on 01/12/2021.
//

final class StorageComponent {

    var memoryComponents: [MemoryComponent]

    var insertable: [MemoryComponent] {
        memoryComponents.filter { $0.header != nil || $0.enumeration != nil }
    }

    init(_ memoryComponents: [MemoryComponent]) {
        self.memoryComponents = memoryComponents
    }

    @discardableResult
    func deobfuscate() -> StorageComponent {
        memoryComponents
            .map { $0.transpiler.tags() }
            .filter { $0.transpiler.isCodeBlock }
            .forEach { $0.transpiler.prepare(helpers: insertable) }
        memoryComponents.removeAll { !$0.transpiler.isCodeBlock }
        return self
    }

    @discardableResult
    func addressTargets() -> StorageComponent {
        let addressables = memoryComponents
            .filter { $0.namespaceCallable != nil }
            .map { MemoryComponent.Label(
                id: $0.namespaceCallable!,
                address: MemoryComponent.Address(segment: $0.address!.segment, page: $0.address!.page),
                privacy: .global) }

        let labels = memoryComponents.flatMap { $0.transpiler.labels() }
        memoryComponents.forEach { $0.transpiler.insertAddressTargets(labels: addressables + labels) }
        return self
    }

    @discardableResult
    func transpile() -> StorageComponent {
        memoryComponents.forEach { $0.transpiler.binary() }
        return self
    }
}
