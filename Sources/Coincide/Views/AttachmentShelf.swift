import CoincideCore
import ImageIO
import SwiftUI

struct AttachmentShelf: View {
    var store: WorkspaceStore
    let attachments: [ChatAttachment]
    var remove: ((UUID) -> Void)?
    @State private var preview: ChatAttachment?
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        Button { preview = attachment } label: {
                            HStack(spacing: 8) {
                                AttachmentThumbnail(store: store, attachment: attachment)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Preview \(attachment.name)")
                        if let remove {
                            Button { remove(attachment.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Remove \(attachment.name)")
                        }
                    }.padding(8).coincideSurface(cornerRadius: 10)
                }
            }.padding(.vertical, 2)
        }.frame(height: 60)
        .sheet(item: $preview) { attachment in AttachmentPreview(store: store, attachment: attachment) }
    }
}

struct AttachmentThumbnail: View {
    var store: WorkspaceStore
    let attachment: ChatAttachment
    @State private var image: NSImage?
    @State private var unavailable = false
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: unavailable ? "exclamationmark.triangle" : attachment.isImage ? "photo" : "doc.text").foregroundStyle(.secondary) }
        }.frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            do { image = try await attachmentImage(store: store, attachment: attachment, size: 128) }
            catch { unavailable = true }
        }
    }
}

struct AttachmentPreview: View {
    var store: WorkspaceStore
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text(attachment.name).font(.headline).lineLimit(2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if attachment.isImage {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 550) }
                else if let error { Text(error).foregroundStyle(.secondary) }
                else { ProgressView("Loading image…") }
            } else { Image(systemName: "doc.text").font(.system(size: 64)).foregroundStyle(.secondary).padding(36) }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).foregroundStyle(.secondary)
                Spacer()
                if attachment.isImage { Button("Copy Image") { Task { await store.copyAttachmentImage(attachment) } } }
                Button("Save Copy…") { store.saveAttachment(attachment) }
                Button("Open File") { Task { await store.openAttachment(attachment) } }
            }
        }.padding(24).frame(minWidth: 420, idealWidth: 700, maxWidth: 900, minHeight: 220)
        .task(id: attachment.id) {
            guard attachment.isImage else { return }
            do { image = try await attachmentImage(store: store, attachment: attachment, size: 1_600) }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor private func attachmentImage(store: WorkspaceStore, attachment: ChatAttachment, size: Int) async throws -> NSImage {
    let data = try await store.attachmentData(attachment)
    let image = try await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size] as CFDictionary) else {
            throw CoincideError("This image could not be previewed. Attach it again.")
        }
        return image
    }.value
    try Task.checkCancellation()
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}
