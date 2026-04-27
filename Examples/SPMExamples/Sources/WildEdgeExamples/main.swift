import Foundation
import WildEdge

print("WildEdge Swift Examples")
print("Set WILDEDGE_DSN to enable real ingestion")

let semaphore = DispatchSemaphore(value: 0)

Task {
    let tracing = TracingExample()
    tracing.runPipeline(input: Data("hello".utf8))
    tracing.close()

    let coroutines = CoroutinesExample()
    _ = try? await coroutines.classify(input: Data([0x00, 0x01]))
    coroutines.close()

    print("Examples finished")
    semaphore.signal()
}

semaphore.wait()
