import SwiftUI
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers

@main
struct StudioCaptureApp: App {
    @StateObject private var model = RecorderModel()
    @NSApplicationDelegateAdaptor(RecorderDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Studio Capture") {
            RecorderView(model: model).frame(minWidth: 880, minHeight: 700)
                .onAppear { delegate.model = model }
                .background(WindowCloseGuard(model: model))
        }.defaultSize(width: 1000, height: 790)
    }
}

struct WindowCloseGuard: NSViewRepresentable {
    let model: RecorderModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.delegate = context.coordinator }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: RecorderModel
        init(model: RecorderModel) { self.model = model }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard !model.busy else { return false }
            guard model.recording else { return true }
            Task { @MainActor in
                await model.stop()
                if model.errorMessage == nil { sender.performClose(nil) }
            }
            return false
        }
    }
}

final class RecorderDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecorderModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy || model.recording else { return .terminateNow }
        if model.busy {
            let alert = NSAlert(); alert.messageText = "準備・保存が終わるまでお待ちください"; alert.runModal()
            return .terminateCancel
        }
        Task { @MainActor in await model.stop(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@MainActor
final class RecorderModel: ObservableObject {
    @Published var displays: [SCDisplay] = []
    @Published var applications: [SCRunningApplication] = []
    @Published var displayID: UInt32 = 0
    @Published var applicationID = "all"
    @Published var systemAudio = true
    @Published var microphone = false
    @Published var camera = false
    @Published var cursor = true
    @Published var recording = false
    @Published var busy = false
    @Published var status = "「画面一覧を読み込む」で録画する画面を選んでください"
    @Published var errorMessage: String?
    @Published var startedAt: Date?
    @Published var lastSaved: URL?
    @Published var preview: CGImage?
    private var engine: CaptureEngine?

    func refresh() async {
        guard !busy, !recording else { return }
        busy = true; defer { busy = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            displays = content.displays
            applications = content.applications.filter { !$0.applicationName.isEmpty && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
            if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? 0 }
            if applicationID != "all" && !applications.contains(where: { $0.bundleIdentifier == applicationID }) { applicationID = "all" }
            status = displays.isEmpty ? "録画できる画面がありません" : "録画の準備ができました"
        } catch {
            errorMessage = "画面を取得できません。システム設定 → プライバシーとセキュリティ → 画面収録（画面とシステムオーディオの収録）で許可し、必要ならアプリを開き直してください。\n\(error.localizedDescription)"
        }
    }

    func start() async {
        guard !busy, !recording else { return }
        guard let display = displays.first(where: { $0.displayID == displayID }) else { errorMessage = "録画する画面を選んでください"; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true; panel.title = "録画の保存先"
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "Studio_\(formatter.string(from: Date())).mp4"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "同じ名前のファイルがあります。別の名前で保存してください"; return
        }
        busy = true; status = "録画を準備しています…"
        defer { busy = false }
        do {
            if microphone {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw CaptureError.message("マイクへのアクセスを許可してください。システム設定 → プライバシーとセキュリティ → マイク")
                }
            }
            if camera {
                guard await AVCaptureDevice.requestAccess(for: .video) else {
                    throw CaptureError.message("カメラへのアクセスを許可してください。システム設定 → プライバシーとセキュリティ → カメラ")
                }
            }
            let filter: SCContentFilter
            if applicationID == "all" {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            } else {
                guard let app = applications.first(where: { $0.bundleIdentifier == applicationID }) else {
                    throw CaptureError.message("対象アプリがありません。画面一覧を更新してください")
                }
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            }
            let config = SCStreamConfiguration()
            let scale = min(1.0, 1920.0 / Double(max(display.width, display.height)))
            config.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
            config.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
            config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 5
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.showsCursor = cursor; config.capturesAudio = systemAudio
            config.excludesCurrentProcessAudio = true; config.sampleRate = 48000; config.channelCount = 2
            config.captureMicrophone = microphone
            config.captureDynamicRange = .SDR
            let engine = CaptureEngine(); self.engine = engine
            engine.failure = { [weak self] message in
                Task { @MainActor in
                    guard let self else { return }
                    self.errorMessage = message
                    if self.recording { await self.stop() }
                }
            }
            engine.preview = { [weak self] image in Task { @MainActor in self?.preview = image } }
            try await engine.start(filter: filter, configuration: config, destination: destination, camera: camera)
            recording = true; startedAt = Date(); lastSaved = nil
            status = "録画中 · 停止ボタンでMP4を保存します"
        } catch {
            await engine?.discard(); engine = nil
            errorMessage = error.localizedDescription; status = "録画を開始できませんでした"
        }
    }

    func stop() async {
        guard recording, !busy, let engine else { return }
        busy = true; recording = false; status = "MP4を保存しています…（音声をまとめています）"
        defer { busy = false; self.engine = nil; startedAt = nil }
        do {
            let (url, stats) = try await engine.finish()
            lastSaved = url; status = "保存しました · \(stats)"
        } catch { errorMessage = error.localizedDescription; status = "保存エラー · メッセージを確認してください" }
    }
}

struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Image(systemName: "record.circle.fill").font(.system(size: 46)).foregroundStyle(.pink)
                VStack(alignment: .leading) {
                    Text("STUDIO CAPTURE").font(.system(size: 30, weight: .black, design: .rounded))
                    Text("画面も、Macの音も、ひとつの動画に。").foregroundStyle(.secondary)
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = Int(model.startedAt.map { context.date.timeIntervalSince($0) } ?? 0)
                    Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .foregroundStyle(model.recording ? .pink : .secondary)
                }
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("1  録画する画面").font(.title2.bold())
                    Button("画面一覧を読み込む / 更新") { Task { await model.refresh() } }
                        .controlSize(.large).disabled(model.recording || model.busy)
                    Picker("ディスプレイ", selection: $model.displayID) {
                        if model.displays.isEmpty { Text("画面を読み込んでください").tag(UInt32(0)) }
                        ForEach(Array(model.displays.enumerated()), id: \.element.displayID) { index, display in
                            Text("画面 \(index + 1) · \(display.width) × \(display.height)").tag(display.displayID)
                        }
                    }
                    Picker("収録対象", selection: $model.applicationID) {
                        Text("画面全体 + Mac全体の音").tag("all")
                        ForEach(model.applications, id: \.processID) { app in
                            Text(app.applicationName).tag(app.bundleIdentifier)
                        }
                    }
                    Text("Logic Proだけを選ぶと、ほかのアプリは映りません。対象のウインドウがある画面を選んでください。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity).disabled(model.recording || model.busy)
                VStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.5))
                        if let preview = model.preview {
                            Image(decorative: preview, scale: 1).resizable().scaledToFit().padding(8)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "display").font(.system(size: 52))
                                Text("録画中に画面を表示").foregroundStyle(.secondary)
                            }
                        }
                    }.frame(height: 185)
                    Text("画面プレビュー · カメラは保存動画の右下に合成")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
            }
            Text("2  一緒に収録するもの").font(.title2.bold())
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                option("Macの内部音声", detail: "Logic Proなどの出力音", icon: "speaker.wave.2.fill", value: $model.systemAudio)
                option("マイク", detail: "標準入力デバイスの声・楽器", icon: "mic.fill", value: $model.microphone)
                option("カメラ", detail: "右下にピクチャーインピクチャー", icon: "video.fill", value: $model.camera)
                option("マウスカーソル", detail: "操作の位置を動画に表示", icon: "cursorarrow", value: $model.cursor)
            }.disabled(model.recording || model.busy)
            Text("MP4 · 最大1920px · 30fps ／ 各スイッチは録画開始前に設定できます")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.status).font(.callout).fixedSize(horizontal: false, vertical: true)
                    if let saved = model.lastSaved {
                        Button("保存した動画をFinderで表示") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    }
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button {
                    Task { if model.recording { await model.stop() } else { await model.start() } }
                } label: {
                    Label(model.recording ? "停止して保存" : "録画を開始", systemImage: model.recording ? "stop.fill" : "record.circle")
                        .font(.title2.bold()).frame(width: 210, height: 52)
                }.buttonStyle(.borderedProminent).tint(model.recording ? .orange : .pink)
                    .disabled(model.busy || (!model.recording && model.displays.isEmpty))
            }
        }.padding(30).background(Color(red: 0.045, green: 0.055, blue: 0.10))
            .preferredColorScheme(.dark)
            .alert("確認してください", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("閉じる") { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }
    private func option(_ title: String, detail: String, icon: String, value: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 28)).frame(width: 42).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.title3.bold()); Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: value).labelsHidden().toggleStyle(.switch).controlSize(.large)
        }.padding(18).frame(maxWidth: .infinity, minHeight: 66)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
    }
}
