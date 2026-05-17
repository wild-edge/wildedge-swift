import SwiftUI

struct ScanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Color.white, lineWidth: 3).frame(width: 76, height: 76)
                Circle().fill(Color.white).frame(width: 64, height: 64)
                Text("Scan").font(.system(size: 15, weight: .semibold)).foregroundColor(.black)
            }
        }
    }
}
