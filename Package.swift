// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "QCPU CLI",
    platforms: [
        .macOS(.v11)
    ],
    products: [
        .executable(name: "QCPU", targets: ["QCPU"]),
        .executable(name: "QCPUC", targets: ["QCPUC"])
    ],
    targets: [
        .target(
            name: "QCPU",
            dependencies: []),
        .target(
            name: "QCPUC",
            dependencies: [.target(name: "QCPU")])
    ]
)
