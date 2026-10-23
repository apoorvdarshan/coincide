import CoincideCore
import ImageIO
import SwiftUI

/// The source owns attachment bytes. A remote reference can only be resolved
/// through its captured environment, never through a local workspace path.
@MainActor struct AttachmentAccess {
    let id: String
    let data: (ChatAttachment) async throws -> Data
    let open: (ChatAttachment) async -> Void
    let copyImage: (ChatAttachment) async -> Void
    let save: (ChatAttachment) -> Void
    var cancelDownload: ((ChatAttachment) -> Void)? = nil
    var transferProgress: ((ChatAttachment) -> Double?)? = nil

    static func local(_ store: WorkspaceStore) -> Self {
        .init(id: "local-\(ObjectIdentifier(store))", data: { try await store.attachmentData($0) },
            open: { await store.openAttachment($0) }, copyImage: { await store.copyAttachmentImage($0) },
            save: { store.saveAttachment($0) })
    }
    func imageIdentity(_ attachment: ChatAttachment) -> String { id + ":" + attachment.id.uuidString + ":" + attachment.digest }
}

struct AttachmentShelf: View {
    let source: AttachmentAccess
    let attachments: [ChatAttachment]
    var remove: ((UUID) -> Void)?
    @State private var preview: ChatAttachment?
    init(store: WorkspaceStore, attachments: [ChatAttachment], remove: ((UUID) -> Void)? = nil) {
        self.init(source: .local(store), attachments: attachments, remove: remove)
    }
    init(source: AttachmentAccess, attachments: [ChatAttachment], remove: ((UUID) -> Void)? = nil) {
        self.source = source; self.attachments = attachments; self.remove = remove
    }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        Button { preview = attachment } label: {
                            HStack(spacing: 8) {
                                AttachmentThumbnail(source: source, attachment: attachment)
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
        .sheet(item: $preview) { attachment in AttachmentPreview(source: source, attachment: attachment) }
    }
}

struct AttachmentThumbnail: View {
    let source: AttachmentAccess
    let attachment: ChatAttachment
    @State private var image: NSImage?
    @State private var unavailable = false
    init(store: WorkspaceStore, attachment: ChatAttachment) { self.init(source: .local(store), attachment: attachment) }
    init(source: AttachmentAccess, attachment: ChatAttachment) { self.source = source; self.attachment = attachment }
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: unavailable ? "exclamationmark.triangle" : attachment.isImage ? "photo" : "doc.text").foregroundStyle(.secondary) }
        }.frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: source.imageIdentity(attachment)) {
            image = nil; unavailable = false
            guard attachment.isImage else { return }
            do { image = try await attachmentImage(source: source, attachment: attachment, size: 128) }
            catch is CancellationError { }
            catch { unavailable = true }
        }
    }
}

struct AttachmentPreview: View {
    let source: AttachmentAccess
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var error: String?
    @State private var reload = UUID()
    init(store: WorkspaceStore, attachment: ChatAttachment) { self.init(source: .local(store), attachment: attachment) }
    init(source: AttachmentAccess, attachment: ChatAttachment) { self.source = source; self.attachment = attachment }
    var body: some View {
        VStack(spacing: 16) {
            HStack { Text(attachment.name).font(.headline).lineLimit(2); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            if attachment.isImage {
                if let image { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 550) }
                else if let error { VStack { Text(error).foregroundStyle(.secondary); Button("Retry") { reload = UUID() } } }
                else {
                    VStack {
                        if let progress = source.transferProgress?(attachment) { ProgressView(value: progress).frame(width: 220) }
                        else { ProgressView("Loading image…") }
                        if let cancel = source.cancelDownload { Button("Cancel Download") { cancel(attachment) } }
                    }
                }
            } else { Image(systemName: "doc.text").font(.system(size: 64)).foregroundStyle(.secondary).padding(36) }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file)).foregroundStyle(.secondary)
                Spacer()
                if attachment.isImage { Button("Copy Image") { Task { await source.copyImage(attachment) } } }
                Button("Save Copy…") { source.save(attachment) }
                Button("Open File") { Task { await source.open(attachment) } }
            }
        }.padding(24).frame(minWidth: 420, idealWidth: 700, maxWidth: 900, minHeight: 220)
        .task(id: source.imageIdentity(attachment) + reload.uuidString) {
            image = nil; error = nil
            guard attachment.isImage else { return }
            do { image = try await attachmentImage(source: source, attachment: attachment, size: 1_600) }
            catch is CancellationError { if !Task.isCancelled { error = "Image loading was cancelled." } }
            catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor private func attachmentImage(source: AttachmentAccess, attachment: ChatAttachment, size: Int) async throws -> NSImage {
    let data = try await source.data(attachment)
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
