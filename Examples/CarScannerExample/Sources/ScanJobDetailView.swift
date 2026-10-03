import Foundation
import WildEdge
import SwiftUI

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ScanJobDetailView: View {
    let job: ScanJob
    let onDismiss: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var backgroundOpacity: Double = 1.0
    @State private var feedback: [UUID: FeedbackType] = [:]

    var body: some View {
        ZStack {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.35)
            }
            .ignoresSafeArea()
            .opacity(backgroundOpacity)
            .onTapGesture { animatedDismiss() }

            VStack(spacing: 0) {
                thumbnail
                detailContent
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let dy = value.translation.height
                        dragOffset = dy
                        backgroundOpacity = max(0, 1 - abs(dy) / 250.0)
                    }
                    .onEnded { value in
                        let dy = value.translation.height
                        if dy > 80 {
                            animatedDismiss()
                        } else if dy < -80 {
                            animatedDismiss(up: true)
                        } else {
                            withAnimation(.spring(duration: 0.3)) {
                                dragOffset = 0
                                backgroundOpacity = 1
                            }
                        }
                    }
            )
        }
    }

    private func animatedDismiss(up: Bool = false) {
        withAnimation(.easeIn(duration: 0.28)) {
            dragOffset = up ? -800 : 800
            backgroundOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { onDismiss() }
    }

    private var thumbnail: some View {
        // Color.clear fixes the banner at the card's width by 200pt, and the
        // image rides in an overlay so it cannot vote on the size. A scan
        // uploads a crop of the car, whose aspect ratio varies wildly from one
        // photo to the next; as a direct child it drags the card with it.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .background(Color.black.opacity(0.9))
            .overlay {
                if let img = job.thumbnail {
                    // Fit, not fill: this banner stands for the image that was
                    // uploaded, so cutting the ends off a wide crop would
                    // misrepresent what the provider actually saw.
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    LinearGradient(
                        colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.25)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }
            }
            .clipped()
        .overlay {
            if let img = job.thumbnail {
                let bboxes = thumbnailBBoxes()
                if !bboxes.isEmpty {
                    GeometryReader { geo in
                        let frameW = geo.size.width
                        let frameH = geo.size.height
                        let imgW = img.size.width
                        let imgH = img.size.height
                        // Matches the .scaledToFit above: the image is letterboxed
                        // inside the banner, so the offsets are the bars around it.
                        let scale = min(frameW / imgW, frameH / imgH)
                        let displayW = imgW * scale
                        let displayH = imgH * scale
                        let xOff = (frameW - displayW) / 2
                        let yOff = (frameH - displayH) / 2
                        let colors: [Color] = [.yellow, .cyan, .orange]
                        ForEach(Array(bboxes.enumerated()), id: \.offset) { idx, bbox in
                            let color = colors[idx % colors.count]
                            let rw = bbox.width * displayW
                            let rh = bbox.height * displayH
                            let cx = xOff + bbox.x * displayW + rw / 2
                            let cy = yOff + bbox.y * displayH + rh / 2
                            Rectangle()
                                .stroke(color, lineWidth: 2)
                                .frame(width: rw, height: rh)
                                .position(x: cx, y: cy)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { animatedDismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.5))
            }
            .padding(10)
        }
        .overlay(alignment: .topLeading) {
            providerBadge.padding(10)
        }
        .overlay(alignment: .bottom) {
            if let photo = job.photoMetadata {
                HStack(spacing: 12) {
                    if let res = photo.dimensionsFormatted {
                        Label(res, systemImage: "squareshape.split.2x2")
                    }
                    Label(photo.fileSizeFormatted, systemImage: "arrow.up.circle")
                }
                .font(.caption2)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
    }

    private var detailContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                Text(job.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Pipeline order: what the local model said, what that made the
                // prompt, then what each provider answered.
                brandGuessSection
                Divider()
                promptSection
                Divider()

                switch job.status {
                case .scanning:
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Analyzing image…").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                    }

                case .completed(let results):
                    ForEach(results) { result in
                        resultSection(result)
                        if results.count > 1 && result.id != results.last?.id {
                            Divider()
                        }
                    }
                    if let photo = results.first?.photo {
                        Divider()
                        photoSection(photo)
                    }

                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.subheadline)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
        .background(Color(UIColor.secondarySystemBackground))
    }

    /// What the on-device classifier said, and whether that reached the
    /// provider. A guess below the hint threshold is still shown — knowing the
    /// local model was unsure is the point of showing it at all.
    @ViewBuilder
    private var brandGuessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-Device Classifier")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            if let guess = job.brandGuess?.guess, let top = guess.top {
                DetailRow(icon: "tag", label: "Brand", value: top.brand)
                DetailRow(icon: "percent", label: "Confidence",
                          value: percent(top.probability))

                let runnersUp = guess.candidates.dropFirst().prefix(2)
                if !runnersUp.isEmpty {
                    DetailRow(
                        icon: "list.number",
                        label: "Then",
                        value: runnersUp
                            .map { "\($0.brand) \(percent($0.probability))" }
                            .joined(separator: ", ")
                    )
                }

                DetailRow(icon: "clock", label: "Duration", value: "\(guess.durationMs) ms")
                DetailRow(
                    icon: guess.promptHint == nil ? "xmark.circle" : "checkmark.circle",
                    label: "Sent as hint",
                    value: guess.promptHint == nil ? "No — below threshold" : "Yes"
                )
            } else if let outcome = job.brandGuess {
                Label(outcome.explanation, systemImage: "car.slash")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label("Running…", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The prompt as sent, so the brand hint above can be read in context.
    @ViewBuilder
    private var promptSection: some View {
        if let prompt = job.prompt {
            MonospacedDisclosureSection(title: "Prompt Sent", text: prompt)
        } else {
            HStack {
                Text("Prompt Sent")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("Building…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func percent(_ probability: Double) -> String {
        "\(Int((probability * 100).rounded()))%"
    }

    @ViewBuilder
    private func resultSection(_ result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if results(for: result).count > 1 {
                HStack {
                    Text(result.provider)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                    Spacer()
                    feedbackButtons(for: result)
                }
            } else {
                feedbackRow(for: result)
            }

            if result.info.found, let candidates = result.info.candidates, !candidates.isEmpty {
                ForEach(Array(candidates.enumerated()), id: \.offset) { idx, candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(["1st", "2nd", "3rd"][safe: idx] ?? "#\(idx + 1)")
                                .font(.caption.weight(.bold))
                            Text(result.provider)
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        if let v = candidate.brand      { DetailRow(icon: "tag",          label: "Brand",      value: v) }
                        if let v = candidate.model      { DetailRow(icon: "car.rear",     label: "Model",      value: v) }
                        if let v = candidate.color      { DetailRow(icon: "paintpalette", label: "Color",      value: v) }
                        if let v = candidate.year       { DetailRow(icon: "calendar",     label: "Year",       value: v) }
                        if let c = candidate.confidence { DetailRow(icon: "percent",      label: "Confidence", value: "\(c)%") }
                        if let b = candidate.bbox {
                            DetailRow(icon: "rectangle.dashed", label: "BBox", value: String(format: "(%.2f, %.2f) %.2f×%.2f", b.x, b.y, b.width, b.height))
                        }
                    }
                    if idx < candidates.count - 1 { Divider() }
                }
            } else {
                Label("No car detected", systemImage: "car.slash")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            MonospacedDisclosureSection(title: "JSON Response", text: result.rawJSON)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("HTTP").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                DetailRow(icon: "checkmark.circle", label: "Status",   value: "\(result.httpStats.statusCode)")
                DetailRow(icon: "clock",            label: "Duration", value: "\(result.httpStats.durationMs) ms")
                DetailRow(icon: "arrow.down.circle",label: "Response", value: result.httpStats.responseSizeFormatted)
            }

        }
    }

    @ViewBuilder
    private func feedbackRow(for result: ScanResult) -> some View {
        HStack(spacing: 12) {
            Text("Helpful?")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            feedbackButtons(for: result)
        }
    }

    @ViewBuilder
    private func feedbackButtons(for result: ScanResult) -> some View {
        let given = feedback[result.id]
        HStack(spacing: 12) {
            Button {
                guard given == nil else { return }
                feedback[result.id] = .thumbsUp
                result.sendFeedback(.thumbsUp)
            } label: {
                Image(systemName: given == .thumbsUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .font(.system(size: 18))
                    .foregroundStyle(given == .thumbsUp ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(given != nil)

            Button {
                guard given == nil else { return }
                feedback[result.id] = .thumbsDown
                result.sendFeedback(.thumbsDown)
            } label: {
                Image(systemName: given == .thumbsDown ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.system(size: 18))
                    .foregroundStyle(given == .thumbsDown ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(given != nil)
        }
    }

    @ViewBuilder
    private func photoSection(_ photo: PhotoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Photo").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            DetailRow(icon: "arrow.up.circle",       label: "Uploaded", value: photo.fileSizeFormatted)
            DetailRow(icon: "squareshape.split.2x2", label: "Res",      value: photo.dimensionsFormatted ?? "—")
        }
    }

    private func thumbnailBBoxes() -> [BoundingBox] {
        guard case .completed(let results) = job.status,
              let candidates = results.first?.info.candidates else { return [] }
        return candidates.compactMap { $0.bbox }
    }

    private func results(for result: ScanResult) -> [ScanResult] {
        guard case .completed(let results) = job.status else { return [] }
        return results
    }

    private var providerBadge: some View {
        Text(job.provider.rawValue)
            .font(.caption.weight(.medium))
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(LinearGradient(
                colors: [Color(red: 0.008, green: 0.251, blue: 0.475, opacity: 0.75),
                         Color(red: 0.000, green: 0.718, blue: 0.545, opacity: 0.75)],
                startPoint: .leading, endPoint: .trailing
            )))
    }
}

/// A collapsed block of monospaced text: the outgoing prompt, the raw response.
struct MonospacedDisclosureSection: View {
    let title: String
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.spring(duration: 0.25)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct DetailRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundColor(.primary)
        }
    }
}
