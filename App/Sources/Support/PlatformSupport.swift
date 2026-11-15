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

/// Window size limits of the Mac build (`UIWindowScene.sizeRestrictions`, Mac Catalyst 13.1+).
@MainActor
enum MacWindow {
    static let defaultSize: CGSize = CGSize(width: 1280, height: 860)
    static let minimumSize: CGSize = CGSize(width: 900, height: 640)

    static func applySizeLimits() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.sizeRestrictions?.minimumSize = minimumSize
        }
    }
}
#endif
