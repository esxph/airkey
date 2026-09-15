import AppKit
import SwiftUI

struct PracticeView: View {
    @ObservedObject var keyboard: TypingController
    @ObservedObject var camera: CameraManager
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if keyboard.benchmark != nil {
                    Button("Finish test") { keyboard.finishBenchmark() }
                        .disabled(!keyboard.canFinishBenchmark)
                    Button("Cancel test") { keyboard.cancelBenchmark() }
                    Button("Missed pinch") { keyboard.reportMissedPinch() }
                        .disabled(keyboard.benchmark?.started == nil)
                        .help("Report a pinch that failed to produce input. This is a manual count, not automatic detection.")
                } else {
                    Button("Typing test") { keyboard.startBenchmark(pinchThreshold: camera.pinchThreshold) }
                        .disabled(keyboard.isDecoding || keyboard.calibration != nil)
                        .help("Copy a short phrase to measure speed and errors. Your existing text is restored afterward.")
                }
                Spacer()
                if keyboard.benchmark == nil {
                Button("Learn word") { keyboard.learnCurrentWord() }
                    .disabled(!keyboard.canLearnCurrentWord)
                }
                Button { keyboard.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!keyboard.canUndo)
                Button("Accidental pinch") { keyboard.correctAccidentalPinch() }
                    .disabled(!keyboard.canCorrectAccidentalPinch)
                    .help("Undo the last resting-hand press and teach protection to catch similar pinches. Ordinary Undo does not train this behavior.")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(keyboard.text, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .disabled(keyboard.text.isEmpty)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if keyboard.benchmark != nil {
            TextEditor(text: Binding(get: { keyboard.text }, set: { keyboard.editText($0) }))
                .font(.system(size: 22, weight: .medium))
                .scrollContentBackground(.hidden)
                .frame(height: 70)
                .accessibilityLabel("Composed text")
            }
            if let test = keyboard.benchmark {
                Text(test.target)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.mint)
                    .accessibilityLabel("Practice phrase: \(test.target)")
                Text(test.started == nil ? "Copy the phrase above. Timing starts with your first input."
                     : "Timing includes corrections · \(test.corrections) corrections · \(test.reportedMisses) reported misses · Release, then Finish test")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let result = keyboard.benchmarkResult {
                Text(result.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(.mint)
                HStack {
                    Menu("Fatigue: \(result.fatigue)") {
                        ForEach(["None", "Mild", "High"], id: \.self) { level in
                            Button(level) { keyboard.setBenchmarkFatigue(level) }
                        }
                    }.fixedSize()
                    Button("Copy result") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.report, forType: .string)
                    }
                    Button("Dismiss") { keyboard.dismissBenchmarkResult() }
                }.font(.caption).buttonStyle(.borderless)
            } else {
            Text(keyboard.swipeMode
                 ? "Start on the first letter, hold the pinch through the word, and release on the last letter. Tap for names or unfamiliar words."
                 : "Open your thumb and index finger to aim. Pinch to type. Either hand can type; release fully between letters.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(keyboard.learningSummary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(keyboard.calibration == nil ? Color.mint.opacity(0.8) : .yellow)
                .accessibilityLabel("Personal learning status: \(keyboard.learningSummary)")
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.09)))
    }

}
