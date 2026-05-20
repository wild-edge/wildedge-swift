import SwiftUI
import WildEdgeBenchmarks

// MARK: - ViewModel

@MainActor
final class BenchmarkViewModel: ObservableObject {
    @Published var appendResults:     [BlobAppendResult]     = []
    @Published var compactionResults: [BlobCompactionResult] = []
    @Published var encodingResults:   [BlobEncodingResult]   = []
    @Published var gzipResults:       [GzipResult]           = []
    @Published var log: [String] = []
    @Published var isRunning     = false
    @Published var elapsedSec: Double = 0

    private var startTime: Double = 0
    private var timer: Timer?

    func run() {
        guard !isRunning else { return }
        isRunning        = true
        appendResults     = []
        compactionResults = []
        encodingResults   = []
        gzipResults       = []
        log               = []
        elapsedSec       = 0
        startTime        = ProcessInfo.processInfo.systemUptime

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.elapsedSec = ProcessInfo.processInfo.systemUptime - self.startTime
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            func emit(_ msg: String) {
                Task { @MainActor in self.log.append(msg) }
            }

            do {
                emit("▶ append benchmark (100 MB per scenario, +1 warmup)…")
                let app = try blobAppendBenchmark(progress: { emit("  · \($0)") })
                await MainActor.run { self.appendResults = app }

                emit("▶ compaction benchmark (100 MB file, drop half, +1 warmup)…")
                let cmp = try blobCompactionBenchmark(progress: { emit("  · \($0)") })
                await MainActor.run { self.compactionResults = cmp }

                emit("▶ encoding benchmark (1 000 events × 5 iterations, +1 warmup)…")
                let enc = try blobEncodingBenchmark(progress: { emit("  · \($0)") })
                await MainActor.run { self.encodingResults = enc }

                emit("▶ gzip benchmark (1–200 events, +1 warmup)…")
                let gz = gzipBatchBenchmark(progress: { emit("  · \($0)") })
                await MainActor.run { self.gzipResults = gz }

                let total = ProcessInfo.processInfo.systemUptime - (await self.startTime)
                emit(String(format: "✓ done in %.1f s", total))
            } catch {
                emit("✗ \(error)")
            }

            await MainActor.run {
                self.isRunning = false
                self.timer?.invalidate()
            }
        }
    }
}

// MARK: - Root view

struct BenchmarkView: View {
    @StateObject private var vm = BenchmarkViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // Controls
                    HStack {
                        Button(action: { vm.run() }) {
                            Label(vm.isRunning ? "Running…" : "Run Benchmarks",
                                  systemImage: vm.isRunning ? "hourglass" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.isRunning)

                        if vm.isRunning {
                            Text(String(format: "%.0f s", vm.elapsedSec))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                        }
                    }

                    // Notice
                    Label("Same scenarios as the Mac test suite — 100 MB per scenario. Expect 5–15 min on device.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Log
                    if !vm.log.isEmpty { LogView(lines: vm.log) }

                    // Append results
                    if !vm.appendResults.isEmpty { AppendTable(results: vm.appendResults) }

                    // Compaction results
                    if !vm.compactionResults.isEmpty { CompactionTable(results: vm.compactionResults) }

                    // Encoding results
                    if !vm.encodingResults.isEmpty { EncodingTable(results: vm.encodingResults) }

                    // Gzip results
                    if !vm.gzipResults.isEmpty { GzipTable(results: vm.gzipResults) }
                }
                .padding()
            }
            .navigationTitle("BlobStore Benchmark")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Log

private struct LogView: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Progress", systemImage: "terminal")
                .font(.caption.bold()).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(lines.indices, id: \.self) {
                        Text(lines[$0])
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 140)
            .background(Color(UIColor.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Append table

private struct AppendTable: View {
    let results: [BlobAppendResult]
    var body: some View {
        SectionCard(label: "Append — 100 MB per scenario", icon: "arrow.down.doc") {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    header("Scenario");  header("locked",   trailing: true)
                    header("unlocked",  trailing: true);  header("speedup", trailing: true)
                    header("MB/s",      trailing: true);  header("n",       trailing: true)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(results, id: \.scenario.name) { r in
                    GridRow {
                        Text(r.scenario.name.trimmingCharacters(in: .whitespaces))
                            .gridCellAnchor(.leading)
                        mono(ms(r.lockedMs))
                        mono(ms(r.unlockedMs))
                        mono(String(format: "%.2f×", r.speedup))
                            .foregroundStyle(r.speedup > 1.1 ? .green : .primary)
                        mono(String(format: "%.0f", r.throughputMBs))
                        mono("\(r.scenario.measured)")
                    }
                }
            }
        }
    }
}

// MARK: - Compaction table

private struct CompactionTable: View {
    let results: [BlobCompactionResult]
    var body: some View {
        SectionCard(label: "dropFirst — 100 MB file, half dropped", icon: "trash.slash") {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    header("Scenario");  header("shift",    trailing: true)
                    header("inPlace",   trailing: true);  header("rename",  trailing: true)
                    header("faster",    trailing: true);  header("n",       trailing: true)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(results, id: \.scenario.name) { r in
                    GridRow {
                        Text(r.scenario.name.trimmingCharacters(in: .whitespaces))
                            .gridCellAnchor(.leading)
                        mono(String(format: "%.0f MB", r.scenario.shiftMB))
                        mono(ms(r.inPlaceMs))
                            .foregroundStyle(r.inPlaceMs < r.renameMs ? .green : .primary)
                        mono(ms(r.renameMs))
                            .foregroundStyle(r.renameMs < r.inPlaceMs ? .green : .primary)
                        mono(r.faster).foregroundStyle(.green)
                        mono("\(r.scenario.measured)")
                    }
                }
            }
        }
    }
}

// MARK: - Encoding table

private struct EncodingTable: View {
    let results: [BlobEncodingResult]

    private var fastest: (enc: String, dec: String) {
        let e = results.min(by: { $0.encodeMs < $1.encodeMs })?.encoding ?? ""
        let d = results.min(by: { $0.decodeMs < $1.decodeMs })?.encoding ?? ""
        return (e, d)
    }

    var body: some View {
        let f = fastest
        SectionCard(label: "Encoding — 1 000 events, rich inference event",
                    icon: "doc.text.magnifyingglass") {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    header("Encoding")
                    header("size",        trailing: true)
                    header("enc µs",      trailing: true)
                    header("dec µs",      trailing: true)
                    header("n",           trailing: true)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(results, id: \.encoding) { r in
                    GridRow {
                        Text(r.encoding).gridCellAnchor(.leading)
                        mono("\(r.sizeBytes) B")
                        mono(String(format: "%.1f", r.encodeUsPerEvent))
                            .foregroundStyle(r.encoding == f.enc ? .green : .primary)
                        mono(String(format: "%.1f", r.decodeUsPerEvent))
                            .foregroundStyle(r.encoding == f.dec ? .green : .primary)
                        mono("\(r.measured)")
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - Gzip table

private struct GzipTable: View {
    let results: [GzipResult]
    var body: some View {
        SectionCard(label: "Gzip compression — JSON batch payloads", icon: "arrow.up.and.down.text.horizontal") {
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    header("Events")
                    header("raw",      trailing: true)
                    header("gzipped",  trailing: true)
                    header("saved",    trailing: true)
                    header("µs/call",  trailing: true)
                    header("n",        trailing: true)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(results, id: \.scenario.name) { r in
                    GridRow {
                        Text(r.scenario.name.trimmingCharacters(in: .whitespaces))
                            .gridCellAnchor(.leading)
                        mono(fmtBytes(r.inputBytes))
                        mono(fmtBytes(r.outputBytes))
                        mono(String(format: "%.0f%%", (1 - r.ratio) * 100))
                            .foregroundStyle(r.ratio < 0.2 ? .green : .primary)
                        mono(String(format: "%.0f", r.compressMs * 1_000))
                        mono("\(r.scenario.measured)")
                    }
                }
            }
        }
    }

    private func fmtBytes(_ n: Int) -> String {
        n < 1_024 ? "\(n) B" : String(format: "%.1f KB", Double(n) / 1_024)
    }
}

// MARK: - Shared card wrapper

private struct SectionCard<Content: View>: View {
    let label: String; let icon: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(label, systemImage: icon)
                .font(.caption.bold()).foregroundStyle(.secondary)
            content()
                .padding(10)
                .background(Color(UIColor.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Helpers

private func ms(_ v: Double) -> String {
    v >= 1_000 ? String(format: "%.2f s",  v / 1_000)
               : String(format: "%.1f ms", v)
}

@ViewBuilder
private func header(_ t: String, trailing: Bool = false) -> some View {
    Text(t).font(.caption2.bold()).foregroundStyle(.secondary)
        .gridCellAnchor(trailing ? .trailing : .leading)
}

@ViewBuilder
private func mono(_ t: String) -> some View {
    Text(t).font(.system(.caption, design: .monospaced))
        .gridCellAnchor(.trailing)
}
