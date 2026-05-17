import SwiftUI

struct ScanJobCell: View {
    let job: ScanJob
    let onTap: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            thumbnailBackground

            VStack {
                HStack {
                    providerBadge
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.5))
                    }
                }
                .padding(6)
                Spacer()
                statusBar
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { onTap() }
    }

    private var thumbnailBackground: some View {
        Group {
            if let img = job.thumbnail {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color.gray.opacity(0.4), Color.gray.opacity(0.2)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Image(systemName: "car.side")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 200)
    }

    @ViewBuilder
    private var statusBar: some View {
        switch job.status {
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .white)).scaleEffect(0.8)
                Text("Analyzing…").font(.caption).foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.ultraThinMaterial)

        case .completed(let results):
            if let info = results.first(where: { $0.info.found })?.info, let top = info.candidates?.first {
                VStack(alignment: .leading, spacing: 2) {
                    if let v = top.brand { Text(v).font(.caption.weight(.semibold)).foregroundColor(.white).lineLimit(1) }
                    if let v = top.model { Text(v).font(.caption).foregroundColor(.white.opacity(0.85)).lineLimit(1) }
                    if let v = top.color { Text(v).font(.caption2).foregroundColor(.white.opacity(0.7)).lineLimit(1) }
                    if let v = top.year  { Text(v).font(.caption2).foregroundColor(.white.opacity(0.7)).lineLimit(1) }
                    if let c = top.confidence { Text("\(c)% confidence").font(.caption2).foregroundColor(.white.opacity(0.6)).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.ultraThinMaterial)
            } else {
                HStack {
                    Text("No car").font(.caption).foregroundColor(.white.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.ultraThinMaterial)
            }

        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.caption)
                Text("Failed").font(.caption).foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    private var providerBadge: some View {
        Text(job.provider.rawValue)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(LinearGradient(
                colors: [Color(red: 0.008, green: 0.251, blue: 0.475, opacity: 0.75),
                         Color(red: 0.000, green: 0.718, blue: 0.545, opacity: 0.75)],
                startPoint: .leading, endPoint: .trailing
            )))
    }
}
