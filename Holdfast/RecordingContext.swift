//
//  RecordingContext.swift
//  Holdfast
//

import AVFoundation
import Foundation

/// Where one recording is written and the settings its stop and what follows it (audio mix, preview,
/// notifications) work from, so changing a setting in the meantime cannot redirect them to another file. Built
/// once in `RecorderController.start`. The settings of the stream and the encoder are not here: `CaptureSource`
/// and `MovieWriter.prepareVideo` read them from `AppSettings` once, while the recording starts.
///
/// The URLs of its files are those of `files` and read as its own: `recording.rawURL` is `recording.files.rawURL`.
@dynamicMemberLookup
struct RecordingContext {
    let audioOnly: Bool
    /// Whether this recording has a microphone track, which the "recordMic" setting alone does not decide
    let recordMic: Bool
    /// Whether this recording captures system audio. The "recordWinSound" setting alone does not decide that
    /// either: a hotkey start and an audio-only recording always do.
    let systemAudio: Bool
    /// Whether the system audio comes from the process tap, with ScreenCaptureKit's system audio recorded next to it
    /// as a backup for the whole recording (its own track, or file); decided with the route before the start
    /// (`SystemAudioSelection.usesTap`)
    let systemAudioBackup: Bool
    let remuxAudio: Bool
    let preventSleep: Bool
    let showPreview: Bool
    let trimAfterRecord: Bool
    let videoFormat: VideoFormat
    let audioFormat: AudioFormat
    let saveDirectory: String
    /// Bitrate of the lossy audio (AAC, Opus, MP3) in kbit/s; lossless formats ignore it
    let audioQuality: Int
    /// Whether the recording as it was written stays next to the mixed one
    let keepUnmixed: Bool
    let files: RecordingFiles

    subscript<T>(dynamicMember file: KeyPath<RecordingFiles, T>) -> T { files[keyPath: file] }

    /// Whether a recording started so captures system audio: the setting says so, or it was started by a hotkey
    /// or records sound only
    static func wantsSystemAudio(audioOnly: Bool, fastStart: Bool) -> Bool {
        return AppSettings.recordWinSound || fastStart || audioOnly
    }

    var mixesAudio: Bool { files.mixURL != nil }
    var fileType: AVFileType { videoFormat == .mov ? .mov : .mp4 }
    /// MP3 is recorded as AAC and converted afterwards
    var audioEncoder: String { audioFormat == .mp3 ? AudioFormat.aac.rawValue : audioFormat.rawValue }
    /// The encoder settings of this recording's audio tracks: of the video file, or of the audio files
    var audioSettings: [String: Any] {
        return MovieWriter.audioSettings(format: audioFormat.rawValue, quality: audioQuality, videoFormat: audioOnly ? nil : videoFormat.rawValue)
    }

    /// Reads the settings kept for the recording from `AppSettings`. What depends on how this recording
    /// was started is handed in: `recordMic` is whether it got a microphone, `saveDirectory` the folder
    /// `RecorderController.start` has checked, `tap` whether its system audio is to come from the process tap,
    /// `reserved` the names of the recordings that are not final yet (`RecordingFileStore.newBase`).
    init(audioOnly: Bool, recordMic: Bool, fastStart: Bool, saveDirectory: String, tap: Bool = false, reserved: Set<String> = []) {
        let systemAudio = RecordingContext.wantsSystemAudio(audioOnly: audioOnly, fastStart: fastStart)
        let systemAudioBackup = systemAudio && tap
        let remuxAudio = AppSettings.remuxAudio
        let videoFormat = AppSettings.videoFormat
        let audioFormat = AppSettings.audioFormat
        self.audioOnly = audioOnly
        self.recordMic = recordMic
        self.systemAudio = systemAudio
        self.systemAudioBackup = systemAudioBackup
        self.remuxAudio = remuxAudio
        self.preventSleep = AppSettings.preventSleep
        self.showPreview = AppSettings.showPreview
        self.trimAfterRecord = AppSettings.trimAfterRecord
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.saveDirectory = saveDirectory
        self.audioQuality = AppSettings.audioQuality.rawValue
        self.keepUnmixed = AppSettings.keepUnmixed

        files = RecordingFiles(base: RecordingFileStore(directory: saveDirectory).newBase(reserved: reserved), audioOnly: audioOnly,
                               recordMic: recordMic, systemAudio: systemAudio, remuxAudio: remuxAudio,
                               videoEnding: videoFormat.rawValue, audioFormat: audioFormat, systemAudioBackup: systemAudioBackup)
    }
}

/// The one place an audio file's extension is decided, and with it its container: AVAudioFile writes the container
/// its file name ends in, and AVAssetWriter is given the one the extension names (`packageFileType`).
extension AudioFormat {
    /// An audio file of its own: an audio-only recording without a microphone, or the mix of a package. Core Audio
    /// writes Opus into a CAF file only (an .ogg file it cannot write, and one named so it cannot read); MP3 is
    /// recorded as AAC and converted afterwards.
    var fileEnding: String {
        switch self {
        case .mp3, .aac, .alac: return "m4a"
        case .flac: return "flac"
        case .opus: return "caf"
        }
    }

    /// The two files of a .qma package. Its microphone file is written by AVAssetWriter, for the fragments of an
    /// .m4a, and AVAssetWriter writes FLAC only into CAF: both files of a FLAC package are .caf.
    var packageFileEnding: String { self == .flac ? "caf" : fileEnding }

    /// The container of a package's microphone file, the one its extension names
    var packageFileType: AVFileType { packageFileEnding == "caf" ? .caf : .m4a }
}

/// Why a recording could not be started, written, mixed or checked, in words shown to the user as they are
struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
