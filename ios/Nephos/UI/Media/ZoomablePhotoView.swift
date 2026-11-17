import Photos
import SwiftUI

struct ZoomablePhotoView: View {
    let item: LocalMediaItem
    let manager: PHImageManager
    let navigate: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var baseOffset = CGSize.zero

    var body: some View {
        GeometryReader { geometry in
            PhotoImageView(item: item, manager: manager)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            scale = min(5, max(1, baseScale * value.magnification))
                            offset = clamped(offset, in: geometry.size)
                        }
                        .onEnded { _ in
                            baseScale = scale
                            baseOffset = offset
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = clamped(
                                CGSize(
                                    width: baseOffset.width + value.translation.width,
                                    height: baseOffset.height + value.translation.height), in: geometry.size)
                        }
                        .onEnded { value in
                            baseOffset = offset
                            if scale == 1, abs(value.translation.width) > 60,
                                abs(value.translation.width) > abs(value.translation.height) * 1.3
                            {
                                navigate(value.translation.width < 0 ? 1 : -1)
                            }
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2
                        baseScale = scale
                        offset = .zero
                        baseOffset = .zero
                    }
                }
                .onChange(of: geometry.size) { _, _ in
                    offset = .zero
                    baseOffset = .zero
                }
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo")
        .accessibilityAction(named: "Next item") { navigate(1) }
        .accessibilityAction(named: "Previous item") { navigate(-1) }
        .accessibilityAction(named: scale > 1 ? "Reset zoom" : "Zoom in") {
            scale = scale > 1 ? 1 : 2
            baseScale = scale
            offset = .zero
            baseOffset = .zero
        }
    }

    private func clamped(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let ratio = item.aspectRatio
        let fittedWidth = min(size.width, size.height * ratio)
        let fittedHeight = min(size.height, size.width / ratio)
        let x = max(0, (fittedWidth * scale - size.width) / 2)
        let y = max(0, (fittedHeight * scale - size.height) / 2)
        return CGSize(width: min(x, max(-x, proposed.width)), height: min(y, max(-y, proposed.height)))
    }
}
