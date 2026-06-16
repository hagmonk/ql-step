import COcctBridge
import Foundation
import StepPreviewKit

struct BenchmarkResult {
    let name: String
    let samples: [Double]

    var average: Double { samples.reduce(0, +) / Double(samples.count) }
    var minimum: Double { samples.min() ?? 0 }
    var maximum: Double { samples.max() ?? 0 }
}

@inline(__always)
func elapsedMilliseconds(_ body: () throws -> Void) rethrows -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try body()
    let end = DispatchTime.now().uptimeNanoseconds
    return Double(end - start) / 1_000_000.0
}

func runBenchmark(name: String, warmups: Int, iterations: Int, body: () throws -> Void) throws -> BenchmarkResult {
    if warmups > 0 {
        for _ in 0..<warmups {
            try autoreleasepool {
                try body()
            }
        }
    }

    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let sample = try autoreleasepool {
            try elapsedMilliseconds(body)
        }
        samples.append(sample)
    }
    return BenchmarkResult(name: name, samples: samples)
}

func printResult(_ result: BenchmarkResult) {
    let samples = result.samples
        .map { String(format: "%.1f", $0) }
        .joined(separator: ", ")
    print(String(
        format: "%-16@ avg %8.1f ms  min %8.1f  max %8.1f  samples [%@]",
        result.name as NSString,
        result.average,
        result.minimum,
        result.maximum,
        samples
    ))
}

func occtOptions(from options: StepSceneLoader.Options) -> OcctLoadOptions {
    OcctLoadOptions(
        linear_deflection: options.linearDeflection,
        angular_deflection: options.angularDeflection,
        relative_deflection: options.relativeDeflection,
        parallel_meshing: options.parallelMeshing
    )
}

func parseBool(_ value: String?) -> Bool? {
    guard let value else { return nil }
    switch value.lowercased() {
    case "1", "true", "yes", "parallel", "mesh-parallel":
        return true
    case "0", "false", "no", "serial", "mesh-serial":
        return false
    default:
        return nil
    }
}

func loadBridgeFile(url: URL, options: StepSceneLoader.Options) throws {
    var mesh = OcctMesh()
    var cOptions = occtOptions(from: options)
    let ok = withUnsafePointer(to: &cOptions) { optionsPointer in
        url.path.withCString { path in
            occt_load_step_with_options(path, optionsPointer, &mesh)
        }
    }
    guard ok else {
        throw NSError(domain: "StepPreviewBench", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "occt_load_step failed"
        ])
    }
    occt_free_mesh(mesh)
}

func loadBridgeData(data: Data, name: String, options: StepSceneLoader.Options) throws {
    var mesh = OcctMesh()
    var cOptions = occtOptions(from: options)
    let ok = withUnsafePointer(to: &cOptions) { optionsPointer in
        data.withUnsafeBytes { bytes in
            name.withCString { cName in
                occt_load_step_data_with_options(bytes.baseAddress, bytes.count, cName, optionsPointer, &mesh)
            }
        }
    }
    guard ok else {
        throw NSError(domain: "StepPreviewBench", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "occt_load_step_data failed"
        ])
    }
    occt_free_mesh(mesh)
}

func inspectBridgeData(data: Data, name: String, options: StepSceneLoader.Options) throws -> (vertices: Int, triangles: Int) {
    var mesh = OcctMesh()
    var cOptions = occtOptions(from: options)
    let ok = withUnsafePointer(to: &cOptions) { optionsPointer in
        data.withUnsafeBytes { bytes in
            name.withCString { cName in
                occt_load_step_data_with_options(bytes.baseAddress, bytes.count, cName, optionsPointer, &mesh)
            }
        }
    }
    guard ok else {
        throw NSError(domain: "StepPreviewBench", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "occt_load_step_data failed"
        ])
    }
    defer { occt_free_mesh(mesh) }
    return (Int(mesh.vert_count), Int(mesh.tri_count))
}

func loadSceneFile(url: URL, options: StepSceneLoader.Options) throws {
    _ = try StepSceneLoader.scene(fromFileAt: url, options: options)
}

func loadSceneData(data: Data, name: String, options: StepSceneLoader.Options) throws {
    _ = try StepSceneLoader.scene(from: data, name: name, options: options)
}

enum ParallelMode: String, Sendable {
    case bridgeData = "bridge-data"
    case sceneData = "scene-data"
}

final class ParallelResults: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var firstErrorDescription: String?

    init(capacity: Int) {
        samples.reserveCapacity(capacity)
    }

    func append(_ sample: Double) {
        lock.lock()
        samples.append(sample)
        lock.unlock()
    }

    func record(_ error: Error) {
        lock.lock()
        if firstErrorDescription == nil {
            firstErrorDescription = String(describing: error)
        }
        lock.unlock()
    }

    func snapshot() -> (samples: [Double], firstErrorDescription: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (samples, firstErrorDescription)
    }
}

func runParallelBenchmark(
    data: Data,
    name: String,
    options: StepSceneLoader.Options,
    workers: Int,
    jobs: Int,
    mode: ParallelMode
) throws {
    guard workers > 0, jobs > 0 else {
        throw NSError(domain: "StepPreviewBench", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "workers and jobs must be greater than zero"
        ])
    }

    @Sendable func loadOnce() throws {
        switch mode {
        case .bridgeData:
            try loadBridgeData(data: data, name: name, options: options)
        case .sceneData:
            try loadSceneData(data: data, name: name, options: options)
        }
    }

    // Warm up OCCT/SceneKit lazy initialization before measuring contention.
    try autoreleasepool {
        try loadOnce()
    }

    let semaphore = DispatchSemaphore(value: workers)
    let group = DispatchGroup()
    let results = ParallelResults(capacity: jobs)

    let wallStart = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<jobs {
        semaphore.wait()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                semaphore.signal()
                group.leave()
            }

            do {
                let sample = try autoreleasepool {
                    try elapsedMilliseconds(loadOnce)
                }
                results.append(sample)
            } catch {
                results.record(error)
            }
        }
    }
    group.wait()
    let wallEnd = DispatchTime.now().uptimeNanoseconds

    let snapshot = results.snapshot()
    if let firstErrorDescription = snapshot.firstErrorDescription {
        throw NSError(domain: "StepPreviewBench", code: 5, userInfo: [
            NSLocalizedDescriptionKey: firstErrorDescription
        ])
    }

    let result = BenchmarkResult(name: mode.rawValue, samples: snapshot.samples)
    let wallMs = Double(wallEnd - wallStart) / 1_000_000.0
    let throughput = Double(jobs) / (wallMs / 1000.0)
    let summedWorkerTime = snapshot.samples.reduce(0, +)
    let effectiveParallelism = summedWorkerTime / wallMs

    print("parallel mode: \(mode.rawValue)")
    print("workers: \(workers), jobs: \(jobs)")
    printResult(result)
    print(String(
        format: "wall %8.1f ms  throughput %6.2f jobs/s  effective parallelism %.2fx",
        wallMs,
        throughput,
        effectiveParallelism
    ))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let firstArgument = arguments.first else {
    fputs("""
    usage:
      StepPreviewBench /path/to/file.step [iterations] [warmups] [linearDeflection angularDeflection]
      StepPreviewBench parallel /path/to/file.step [workers] [jobs] [linearDeflection angularDeflection] [bridge-data|scene-data] [mesh-parallel|mesh-serial]
    """, stderr)
    exit(64)
}

if firstArgument == "parallel" {
    guard let path = arguments.dropFirst().first else {
        fputs("usage: StepPreviewBench parallel /path/to/file.step [workers] [jobs] [linearDeflection angularDeflection] [bridge-data|scene-data]\n", stderr)
        exit(64)
    }

    let url = URL(fileURLWithPath: path)
    let workers = arguments.dropFirst(2).first.flatMap(Int.init) ?? ProcessInfo.processInfo.activeProcessorCount
    let jobs = arguments.dropFirst(3).first.flatMap(Int.init) ?? workers
    let options: StepSceneLoader.Options
    if let linear = arguments.dropFirst(4).first.flatMap(Double.init),
       let angular = arguments.dropFirst(5).first.flatMap(Double.init) {
        options = StepSceneLoader.Options(
            linearDeflection: linear,
            angularDeflection: angular,
            parallelMeshing: parseBool(arguments.dropFirst(7).first) ?? true
        )
    } else {
        options = StepSceneLoader.Options(
            parallelMeshing: parseBool(arguments.dropFirst(7).first) ?? true
        )
    }
    let mode = arguments.dropFirst(6).first.flatMap(ParallelMode.init(rawValue:)) ?? .sceneData
    let data = try Data(contentsOf: url)
    let name = url.lastPathComponent
    let meshCounts = try inspectBridgeData(data: data, name: name, options: options)

    print("file: \(url.path)")
    print("bytes: \(data.count)")
    print(String(
        format: "deflection: linear %.3f, angular %.3f, relative %@",
        options.linearDeflection,
        options.angularDeflection,
        options.relativeDeflection ? "true" : "false"
    ))
    print("mesh parallel: \(options.parallelMeshing ? "true" : "false")")
    print("mesh: \(meshCounts.vertices) vertices, \(meshCounts.triangles) triangles")
    try runParallelBenchmark(data: data, name: name, options: options, workers: workers, jobs: jobs, mode: mode)
    exit(0)
}

let url = URL(fileURLWithPath: firstArgument)
let iterations = arguments.dropFirst().first.flatMap(Int.init) ?? 5
let warmups = arguments.dropFirst(2).first.flatMap(Int.init) ?? 1
let options: StepSceneLoader.Options
if let linear = arguments.dropFirst(3).first.flatMap(Double.init),
   let angular = arguments.dropFirst(4).first.flatMap(Double.init) {
    options = StepSceneLoader.Options(
        linearDeflection: linear,
        angularDeflection: angular,
        parallelMeshing: parseBool(arguments.dropFirst(5).first) ?? true
    )
} else {
    options = StepSceneLoader.Options(
        parallelMeshing: parseBool(arguments.dropFirst(5).first) ?? true
    )
}
let data = try Data(contentsOf: url)
let name = url.lastPathComponent
let meshCounts = try inspectBridgeData(data: data, name: name, options: options)

print("file: \(url.path)")
print("bytes: \(data.count)")
print("iterations: \(iterations), warmups: \(warmups)")
print(String(
    format: "deflection: linear %.3f, angular %.3f, relative %@",
    options.linearDeflection,
    options.angularDeflection,
    options.relativeDeflection ? "true" : "false"
))
print("mesh parallel: \(options.parallelMeshing ? "true" : "false")")
print("mesh: \(meshCounts.vertices) vertices, \(meshCounts.triangles) triangles")

let results = try [
    runBenchmark(name: "bridge-file", warmups: warmups, iterations: iterations) {
        try loadBridgeFile(url: url, options: options)
    },
    runBenchmark(name: "bridge-data", warmups: warmups, iterations: iterations) {
        try loadBridgeData(data: data, name: name, options: options)
    },
    runBenchmark(name: "scene-file", warmups: warmups, iterations: iterations) {
        try loadSceneFile(url: url, options: options)
    },
    runBenchmark(name: "scene-data", warmups: warmups, iterations: iterations) {
        try loadSceneData(data: data, name: name, options: options)
    },
]

for result in results {
    printResult(result)
}
