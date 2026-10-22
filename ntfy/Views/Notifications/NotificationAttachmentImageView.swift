//
//  NotificationAttachmentImageView.swift
//  ntfy
//
//  Created by Alek Michelson on 5/11/26.
//

import SwiftUI

struct NotificationAttachmentImageView: View {
    @State private var imagePresentation: PresentedImage?
    @StateObject private var imageLoader = NotificationAttachmentImageLoader()

    let localFileUrl: URL?
    let isLoading: Bool

    var body: some View {
        Group {
            if let image = imageLoader.image {
                renderedImage(image)
            } else if isLoading || imageLoader.phase == .idle || imageLoader.phase == .loading {
                loadingPlaceholder
            } else {
                failedPlaceholder
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: localFileUrl?.path) {
            await imageLoader.load(from: localFileUrl)
        }
        .fullScreenCover(item: $imagePresentation) { presentedImage in
            AttachmentFullscreenImageView(image: presentedImage.image)
        }
    }

    private func renderedImage(_ image: UIImage) -> some View {
        Button {
            imagePresentation = PresentedImage(image: image)
        } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Open image"))
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemFill))
            .frame(height: 160)
            .overlay {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(String(localized: "Loading preview"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
    }

    private var failedPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemFill))
            .frame(height: 120)
            .overlay {
                Image(systemName: "photo")
                    .accessibilityLabel(String(localized: "Image preview unavailable"))
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
    }
}

private struct PresentedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct AttachmentFullscreenImageView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var closeButtonSize: CGFloat = 44

    let image: UIImage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            ZoomableImageScrollView(image: image)
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                    }
            }
            .accessibilityLabel(HardeningCopy.close)
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
    }
}

private struct ZoomableImageScrollView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 4
        scrollView.minimumZoomScale = 1
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = String(localized: "Image attachment")
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        scrollView.zoomScale = 1
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
    }
}
