import AppServices
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The few places where the iPhone/iPad app and the Mac (Mac Catalyst) build differ outside the chart map.
// Every iOS branch is exactly what the iOS app did before the Mac build existed.

/// "Keep the screen on" (Settings): the idle timer on iOS; on the Mac a process activity that keeps the
/// display from sleeping while the setting is on (`NSActivityIdleDisplaySleepDisabled`, NSProcessInfo.h).
@MainActor
enum KeepScreenOn {
    #if targetEnvironment(macCatalyst)
    private static var activity: NSObjectProtocol?
    #endif

    static func set(_ on: Bool) {
        #if targetEnvironment(macCatalyst)
        if on {
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [ProcessInfo.ActivityOptions.idleDisplaySleepDisabled, ProcessInfo.ActivityOptions.userInitiated],
                    reason: "Gulf Nav keeps the display awake (Settings > Keep the display awake)")
            }
        } else if let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

/// User-facing words that depend on the platform.
enum PlatformText {
    #if targetEnvironment(macCatalyst)
    static let isMac: Bool = true
    /// "Tap" on a touch screen, "Click" with a pointer.
    static let tap: String = "Click"
    static let tapLower: String = "click"
    static let keepScreenOn: String = "Keep the display awake"
    static let recordingNote: String = "Recording continues while Gulf Nav is open, also when another app is in front. A Mac usually has no GPS: positions come from Wi-Fi location, if Location Services allows it, so a track is only recorded while a position is available."
    static let intervalNote: String = "Shorter intervals give smoother tracks; location keeps running while recording either way."
    static let locationOff: String = "Location access is off. Click to open System Settings. Charts, waypoints and routes work without it."
    /// System Settings > Privacy & Security > Location Services.
    static let locationSettingsURL: String = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
    #else
    static let isMac: Bool = false
    static let tap: String = "Tap"
    static let tapLower: String = "tap"
    static let keepScreenOn: String = "Keep the screen on"
    static let recordingNote: String = "Recording continues with the screen locked or another app in front, using GPS in the background: this uses noticeably more battery. Stop recording when you are done."
    static let intervalNote: String = "Shorter intervals give smoother tracks; background recording uses GPS continuously either way."
    static let locationOff: String = "Location access is off. Tap to open Settings."
    static let locationSettingsURL: String = UIApplication.openSettingsURLString
    #endif
}

// MARK: - GPX export

/// A GPX file for the Mac's save panel (`fileExporter`).
struct GPXExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { GPXDocumentTypes.allowed }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Presents a GPX export: the share sheet on iOS (as before), a save panel on the Mac (a share sheet inside a
/// sheet is not how a Mac app saves a file, and Mac Catalyst presents UIActivityViewController as a popover).
struct GPXExportPresenter: ViewModifier {
    let plotter: PlotterModel

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        let file: PlotterModel.ExportFile? = plotter.exportFile
        let document: GPXExportDocument? = file.flatMap { item in
            (try? Data(contentsOf: item.url)).map { GPXExportDocument(data: $0) }
        }
        content.fileExporter(isPresented: Binding(get: { plotter.exportFile != nil },
                                                  set: { shown in
                                                      if !shown { plotter.exportFile = nil }
                                                  }),
                             document: document,
                             contentType: GPXDocumentTypes.exportType,
                             defaultFilename: file?.url.deletingPathExtension().lastPathComponent) { result in
            if case .failure(let error) = result {
                plotter.data.errorText = "The file could not be saved: \(error.localizedDescription)"
            }
            plotter.exportFile = nil
        }
        #else
        content.sheet(item: exportBinding(plotter)) { file in
            ShareSheet(url: file.url)
        }
        #endif
    }
}

extension View {
    /// The GPX export presentation for `plotter.exportFile` (see `GPXExportPresenter`).
    func gpxExport(_ plotter: PlotterModel) -> some View {
        modifier(GPXExportPresenter(plotter: plotter))
    }
}

extension GPXDocumentTypes {
    /// The type a saved GPX file gets.
    static var exportType: UTType {
        UTType(GPXFiles.typeIdentifier) ?? UTType(filenameExtension: GPXFiles.fileExtension) ?? UTType.xml
    }
}

#if targetEnvironment(macCatalyst)
// MARK: - Mac window

/// Window size of the Mac build. SwiftUI sizes a Mac Catalyst window from its content; the first content is the
/// small "Loading…" view, which on CI gave a 59 × 69 point window with the map screen laid out around it. So:
/// - the root view has a minimum frame (`contentMinimum`) and the scene uses `.windowResizability(.contentMinSize)`;
/// - `configure()` sets `UIWindowScene.sizeRestrictions.minimumSize` and, if the window is still smaller, asks
///   for a frame with `requestGeometryUpdate(.Mac(systemFrame:))` (Mac Catalyst 16+), clamped to the screen.
@MainActor
enum MacWindow {
    static let defaultSize: CGSize = CGSize(width: 1280, height: 860)
    /// Fits a 1024 × 768 display with the menu bar and Dock.
    static let contentMinimum: CGSize = CGSize(width: 800, height: 600)
    private static var lastRequest: String = "none"
    private static var requestCount: Int = 0
    private static var startedAt: Date?
    /// Only while the app starts is the window resized; after that the user's own size is kept.
    static let startUpPeriod: TimeInterval = 6

    /// Sets the minimum size and, during start-up, asks for the default size (clamped to the screen) whenever the
    /// window is smaller. On CI the first request was made while the window was still the tiny "Loading…" window
    /// and did not stick (the window ended at the 800 × 600 content minimum), and later calls only checked the
    /// minimum, so nothing asked again; `GulfNavApp` now calls this several times during start-up.
    static func configure() {
        let now = Date()
        if startedAt == nil { startedAt = now }
        let starting: Bool = now.timeIntervalSince(startedAt ?? now) < startUpPeriod
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let screen: CGSize = windowScene.screen.bounds.size
            let usable = CGSize(width: max(screen.width - 40, 320), height: max(screen.height - 100, 320))
            let minimum = CGSize(width: min(contentMinimum.width, usable.width), height: min(contentMinimum.height, usable.height))
            windowScene.sizeRestrictions?.minimumSize = minimum
            let wanted = CGSize(width: min(defaultSize.width, usable.width), height: min(defaultSize.height, usable.height))
            let current: CGRect = windowScene.effectiveGeometry.systemFrame
            let tooSmall: Bool = current.width < minimum.width || current.height < minimum.height
            let belowWanted: Bool = current.width < wanted.width - 20 || current.height < wanted.height - 20
            guard tooSmall || (starting && belowWanted) else { continue }
            // CI showed the geometry request alone being ignored (window stayed 800 x 632 after five requests).
            // Raising the minimum size to the wanted size makes the system grow the window; the real minimum is
            // put back shortly after, so the user can still make the window smaller.
            if starting && belowWanted {
                windowScene.sizeRestrictions?.minimumSize = wanted
                let restore: CGSize = minimum
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    windowScene.sizeRestrictions?.minimumSize = restore
                }
            }
            let frame = CGRect(x: 20, y: 40, width: wanted.width, height: wanted.height)
            requestCount += 1
            lastRequest = "\(Int(frame.width))x\(Int(frame.height)) (request \(requestCount), window was \(Int(current.width))x\(Int(current.height)))"
            windowScene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.Mac(systemFrame: frame)) { error in
                let text: String = error.localizedDescription
                Task { @MainActor in
                    MacWindow.noteFailure(text)
                }
            }
        }
    }

    static func noteFailure(_ text: String) {
        lastRequest += " failed: " + text
    }

    /// Debug probe value (`mac.window`): `screen=WxH; window=x,y,WxH; content=WxH; requested=…`. `content` is the
    /// key window's bounds (the earlier probe measured its own 2 × 2 frame).
    static func describe() -> String {
        var parts: [String] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let screen: CGSize = windowScene.screen.bounds.size
            let frame: CGRect = windowScene.effectiveGeometry.systemFrame
            let content: CGSize = windowScene.windows.first?.bounds.size ?? .zero
            parts.append("screen=\(Int(screen.width))x\(Int(screen.height))")
            parts.append("content=\(Int(content.width))x\(Int(content.height))")
            parts.append("window=\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))")
        }
        parts.append("requested=" + lastRequest)
        return parts.joined(separator: "; ")
    }
}
#endif

// MARK: - Map screen additions on the Mac

/// Mac: GPX files dropped onto the window are imported (the same import plan as "Import GPX"), and an
/// "Export All" from the menu bar is saved from the map screen. iOS: nothing (the content is returned as is).
struct MacMapScreenSupport: ViewModifier {
    let plotter: PlotterModel
    @Binding var dropTargeted: Bool

    func body(content: Content) -> some View {
        #if targetEnvironment(macCatalyst)
        content
            .gpxExport(plotter)
            .onDrop(of: GPXDrop.acceptedTypes, isTargeted: $dropTargeted) { providers in
                GPXDrop.handle(providers, plotter: plotter)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 4)
                        .padding(4)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("map.dropTarget")
                }
            }
        #else
        content
        #endif
    }
}

/// Mac: reading a GPX file dropped from Finder or another app.
enum GPXDrop {
    /// GPX first (Finder files declare it through the app's imported type), then any XML or file URL.
    static var acceptedTypes: [UTType] {
        var types: [UTType] = GPXDocumentTypes.allowed
        types.append(UTType.fileURL)
        return types
    }

    /// Loads the first dropped item that is GPX/XML data or a `.gpx` file and plans its import. Returns
    /// whether the drop was accepted.
    @MainActor
    static func handle(_ providers: [NSItemProvider], plotter: PlotterModel) -> Bool {
        for provider in providers {
            for type in GPXDocumentTypes.allowed where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    Task { @MainActor in
                        if let data {
                            await plotter.planImport(data: data)
                        } else {
                            plotter.data.errorText = "The dropped file could not be read: \(error?.localizedDescription ?? "no data")"
                        }
                    }
                }
                return true
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    Task { @MainActor in
                        guard let url, url.pathExtension.lowercased() == GPXFiles.fileExtension else {
                            plotter.data.errorText = "Only GPX files can be dropped on the chart."
                            return
                        }
                        await plotter.planImport(fileAt: url)
                    }
                }
                return true
            }
        }
        return false
    }
}
