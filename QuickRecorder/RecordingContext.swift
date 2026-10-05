//
//  RecordingContext.swift
//  QuickRecorder
//

import AVFoundation
import Foundation

/// Everything about one recording that must not change while it runs or while it is being finished: where it is
/// written and the settings it was started with. Built once in `prepRecord`. `stopRecording()` and what follows it
/// (audio mix, preview, notifications) work from their own copy, so changing a setting or starting the next
/// recording in the meantime cannot redirect them to another file.
struct RecordingContext {
    /// Tells this recording from the next one where a stop is requested asynchronously
    let id = UUID()
    let audioOnly: Bool
    /// Whether this recording has a microphone track, which the "recordMic" setting alone does not decide
    let recordMic: Bool
    /// Whether this recording captures system audio. The "recordWinSound" setting alone does not decide that
    /// either: a hotkey start and an audio-only recording always do.
    let systemAudio: Bool
    let remuxAudio: Bool
    let preventSleep: Bool
    let showPreview: Bool
    let trimAfterRecord: Bool
    let videoFormat: VideoFormat
    let audioFormat: AudioFormat
    let saveDirectory: String
    /// MP3 bitrate in kbit/s
    let audioQuality: Int
    /// What is written while recording: the video file, the audio file, or the .qma package for audio with a microphone
    let rawURL: URL
    /// What the audio mix after a video recording writes before it is checked and gets the final name, nil when
    /// the audio tracks are not mixed
    let mixURL: URL?
    /// The name the recording as it was written (two audio tracks) gets when it is kept, nil when the audio tracks are not mixed
    let unmixedURL: URL?
    /// Whether the recording as it was written stays next to the mixed one
    let keepUnmixed: Bool
    /// What the user ends up with
    let finalURL: URL
    /// Audio-only recordings: the system audio file, and the microphone file when there is one
    let systemAudioURL: URL?
    let micAudioURL: URL?

    var mixesAudio: Bool { mixURL != nil }
    var fileType: AVFileType { videoFormat == .mov ? .mov : .mp4 }
    var audioFileType: AVFileType { audioFormat == .flac || audioFormat == .opus ? .caf : .m4a }
    var audioFileEnding: String { RecordingContext.fileEnding(for: audioFormat) }
    /// MP3 is recorded as AAC and converted afterwards
    var audioEncoder: String { audioFormat == .mp3 ? AudioFormat.aac.rawValue : audioFormat.rawValue }
    /// The encoder settings of this recording's audio tracks
    var audioSettings: [String: Any] {
        return MovieWriter.audioSettings(format: audioFormat.rawValue, quality: audioQuality, videoFormat: videoFormat.rawValue)
    }

    private static func fileEnding(for format: AudioFormat) -> String {
        switch format {
        case .mp3, .aac, .alac: return "m4a"
        case .flac: return "flac"
        case .opus: return "ogg"
        }
    }

    /// The one place the settings of a recording are read from `AppSettings`. What depends on how this recording
    /// was started is handed in: `recordMic` is whether it got a microphone, `saveDirectory` the folder
    /// `prepRecord` has checked.
    init(audioOnly: Bool, recordMic: Bool, fastStart: Bool, saveDirectory: String) {
        let systemAudio = AppSettings.recordWinSound || fastStart || audioOnly
        let remuxAudio = AppSettings.remuxAudio
        let videoFormat = AppSettings.videoFormat
        let audioFormat = AppSettings.audioFormat
        self.audioOnly = audioOnly
        self.recordMic = recordMic
        self.systemAudio = systemAudio
        self.remuxAudio = remuxAudio
        self.preventSleep = AppSettings.preventSleep
        self.showPreview = AppSettings.showPreview
        self.trimAfterRecord = AppSettings.trimAfterRecord
        self.videoFormat = videoFormat
        self.audioFormat = audioFormat
        self.saveDirectory = saveDirectory
        self.audioQuality = AppSettings.audioQuality.rawValue
        self.keepUnmixed = AppSettings.keepUnmixed

        let files = RecordingFiles(base: RecordingFileStore(directory: saveDirectory).newBase(), audioOnly: audioOnly,
                                   recordMic: recordMic, systemAudio: systemAudio, remuxAudio: remuxAudio,
                                   videoEnding: videoFormat.rawValue, audioEnding: RecordingContext.fileEnding(for: audioFormat),
                                   exportsMP3: audioFormat == .mp3)
        rawURL = files.rawURL
        mixURL = files.mixURL
        unmixedURL = files.unmixedURL
        finalURL = files.finalURL
        systemAudioURL = files.systemAudioURL
        micAudioURL = files.micAudioURL
    }
}

/// A reason a recording could not be started, shown to the user as it is
struct RecordingError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
