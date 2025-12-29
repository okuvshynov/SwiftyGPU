// swift-tools-version:5.2

import PackageDescription

let package = Package(
    name: "SwiftyGPU",
    products: [
        .executable(name: "swifty-gpu", targets: ["SwiftyGPU"]),
        .executable(name: "gpu-monitor", targets: ["GPUMonitor"])
    ],
    targets: [
        .target(name: "SwiftyGPU", dependencies: []),
        .target(name: "GPUMonitor", dependencies: [])
    ]
)
