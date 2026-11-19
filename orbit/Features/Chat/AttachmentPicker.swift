import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentPicker: View {
    @Binding var attachments: [DraftAttachment]
    @Binding var error: String?
    let focus: () -> Void
    @State private var photos: [PhotosPickerItem] = []
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var hasPasteImage = false
    @State private var failures = 0
    @State private var added = 0
    @State private var showsCamera = false
    @State private var retryActions: [UUID: () -> Void] = [:]
    @State private var batches: [UUID: Set<UUID>] = [:]
    @State private var batchPhotos: [UUID: Int] = [:]
    @State private var batchFiles: [UUID: [String]] = [:]

    var body: some View {
        pickerMenu
            .photosPicker(isPresented: $showsPhotos, selection: $photos, maxSelectionCount: max(1, 10 - attachments.count), selectionBehavior: .ordered, matching: .images, preferredItemEncoding: .compatible)
            .onChange(of: photos) { loadPhotos() }
            .onChange(of: attachments.map(\.id)) {
                let ids = Set(attachments.map(\.id))
                retryActions = retryActions.filter { ids.contains($0.key) }
                for removed in Set(batches.values.flatMap { $0 }).subtracting(ids) { finishItem(removed) }
            }
            .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true, onCompletion: loadFiles)
            .sensoryFeedback(.selection, trigger: added)
            .sensoryFeedback(.warning, trigger: failures)
            .fullScreenCover(isPresented: $showsCamera) {
                CameraPicker { data in addImages([data], name: "Camera.jpg") }
            }
            .onReceive(NotificationCenter.default.publisher(for: .retryAttachment)) { notification in
                guard let id = notification.object as? UUID, let index = attachments.firstIndex(where: { $0.id == id }) else { return }
                attachments[index].phase = .preparing
                batches[UUID()] = [id]
                retryActions[id]?()
            }
    }

    private var pickerMenu: some View {
        Menu {
            Group {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { showsCamera = true }
                    .accessibilityIdentifier("chat.attach.camera")
            }
            Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
                .accessibilityIdentifier("chat.attach.library")
            Button("Choose File", systemImage: "folder") { showsFiles = true }
                .accessibilityIdentifier("chat.attach.files")
            if hasPasteImage {
                Button("Paste Image", systemImage: "doc.on.clipboard") {
                    addImages((UIPasteboard.general.images ?? []).compactMap { $0.pngData() }, name: "Pasted image.png")
                }.accessibilityIdentifier("chat.attach.paste")
            }
            }.disabled(attachments.count >= 10)
            if attachments.count >= 10 { Text("10 attachments is the limit") }
        } label: {
            Image(systemName: "plus.circle.fill").resizable().scaledToFit().frame(width: 30, height: 30)
                .frame(width: 44, height: 44).contentShape(.rect)
        }
        .tint(.secondary)
        .menuOrder(.fixed)
        .accessibilityLabel("Add attachment").accessibilityHint("Photos, camera or files")
        .accessibilityIdentifier("chat.attach")
        .simultaneousGesture(TapGesture().onEnded { hasPasteImage = UIPasteboard.general.hasImages })
    }

    private func loadPhotos() {
        let selected = photos
        photos = []
        var ids: Set<UUID> = []
        for photo in selected {
            guard let id = placeholder(name: "Photo", image: true) else { break }
            ids.insert(id)
            let load = {
                Task { @MainActor in
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self) else { throw HermesError.server("Couldn't load this photo") }
                        await prepare(id: id, data: data, name: "Photo.jpg", image: true)
                    } catch { fail(id, "Couldn't load this photo") }
                }
            }
            retryActions[id] = { _ = load() }
            _ = load()
        }
        if !ids.isEmpty { batches[UUID()] = ids }
        focus()
    }

    private func loadFiles(_ result: Result<[URL], Error>) {
        do {
            var ids: Set<UUID> = []
            for url in try result.get() {
                guard let id = placeholder(name: url.lastPathComponent, image: false) else { break }
                ids.insert(id)
                let load = {
                    Task { @MainActor in
                        do { complete(id, try await Task.detached { try AttachmentPreparation.file(url) }.value) }
                        catch { fail(id, error.localizedDescription) }
                    }
                }
                retryActions[id] = { _ = load() }
                _ = load()
            }
            if !ids.isEmpty { batches[UUID()] = ids }
            focus()
        } catch { self.error = error.localizedDescription }
    }

    private func placeholder(name: String, image: Bool) -> UUID? {
        guard attachments.count < 10 else {
            error = "Only 10 attachments per message"
            AccessibilityNotification.Announcement("Only 10 attachments per message").post()
            return nil
        }
        let item = DraftAttachment(kind: image ? .image : .file, name: name)
        attachments.append(item)
        return item.id
    }

    private func addImages(_ images: [Data], name: String) {
        var ids: Set<UUID> = []
        for data in images {
            guard let id = placeholder(name: name, image: true) else { break }
            ids.insert(id)
            retryActions[id] = { Task { await prepare(id: id, data: data, name: name, image: true) } }
            retryActions[id]?()
        }
        if !ids.isEmpty { batches[UUID()] = ids }
        focus()
    }

    private func prepare(id: UUID, data: Data, name: String, image: Bool) async {
        do { complete(id, try await Task.detached { try AttachmentPreparation.prepare(data, name: name, image: image) }.value) }
        catch { fail(id, error.localizedDescription) }
    }

    private func complete(_ id: UUID, _ prepared: AttachmentPreparation.Prepared) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { finishItem(id); return }
        guard attachments.reduce(0, { $0 + $1.byteCount }) + prepared.outgoing.payload.count <= 50 * 1024 * 1024 else {
            fail(id, "Attachments must total 50 MB or less")
            return
        }
        attachments[index].name = prepared.outgoing.name
        attachments[index].kind = prepared.outgoing.kind
        attachments[index].payload = prepared.outgoing.payload
        attachments[index].byteCount = prepared.outgoing.payload.count
        attachments[index].uti = UTType(mimeType: prepared.outgoing.mime) ?? .data
        attachments[index].thumbnail = prepared.thumbnail.flatMap { UIImage(data: $0) }
        attachments[index].preview = prepared.preview
        attachments[index].phase = .ready
        error = nil
        finishItem(id, photo: prepared.outgoing.kind == .image, name: prepared.outgoing.name)
    }

    private func fail(_ id: UUID, _ reason: String) {
        defer { finishItem(id) }
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].phase = .failed(reason)
        error = reason
        failures += 1
    }

    private func finishItem(_ id: UUID, photo: Bool? = nil, name: String = "") {
        guard let batch = batches.first(where: { $0.value.contains(id) })?.key else { return }
        if photo == true { batchPhotos[batch, default: 0] += 1 }
        if photo == false { batchFiles[batch, default: []].append(name) }
        batches[batch]?.remove(id)
        guard batches[batch]?.isEmpty == true else { return }
        batches.removeValue(forKey: batch)
        let photos = batchPhotos.removeValue(forKey: batch) ?? 0
        let files = batchFiles.removeValue(forKey: batch) ?? []
        guard photos + files.count > 0 else { return }
        added += 1
        let message: String
        if files.isEmpty { message = photos == 1 ? "Photo added" : "\(photos) photos added" }
        else if photos == 0 { message = files.count == 1 ? "\(files[0]) added" : "\(files.count) files added" }
        else { message = "\(photos + files.count) attachments added" }
        AccessibilityNotification.Announcement(message).post()
    }
}

extension Notification.Name {
    static let retryAttachment = Notification.Name("orbit.retryAttachment")
}
