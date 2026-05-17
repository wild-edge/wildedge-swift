import SwiftUI

struct MarqueeText: View {
    let text: String
    var speed: Double = 50

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .lineLimit(1)
                .fixedSize()
                .frame(height: proxy.size.height)
                .offset(x: offset)
                .background(
                    GeometryReader { textProxy in
                        Color.clear.onAppear {
                            textWidth = textProxy.size.width
                            scroll(in: proxy.size.width)
                        }
                    }
                )
        }
        .clipped()
    }

    private func scroll(in containerWidth: CGFloat) {
        offset = containerWidth
        let duration = (containerWidth + textWidth) / speed
        withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
            offset = -textWidth
        }
    }
}
