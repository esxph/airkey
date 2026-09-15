import AppKit
import SwiftUI

/// The floating panel contains only suggestions, keys, and the hand guides.
struct ContentView: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var keyboard: TypingController
    @ObservedObject var output: SystemTypingDriver
    var onActivity: () -> Void = {}
    var onMouseDrag: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.035, green: 0.055, blue: 0.08)
                keyboardSurface(size: geometry.size)
                HandOverlayView(frames: camera.frames, keyboard: keyboard, size: geometry.size)
                if let handle = keyboard.layout.dragHandleFrame(in: geometry.size) {
                    let held = keyboard.pressed.contains("move_keyboard")
                    let aimed = keyboard.hovered.values.contains("move_keyboard")
                    RoundedRectangle(cornerRadius: 14)
                        .fill(held ? Color.mint : Color.white.opacity(aimed ? 0.24 : 0.10))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(aimed || held ? Color.mint : Color.white.opacity(0.24), lineWidth: 1.5))
                        .overlay(HStack(spacing: 8) {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right").font(.system(size: 20, weight: .medium))
                            Text(held ? "Moving" : "Move").font(.system(size: 16, weight: .semibold))
                        }.foregroundStyle(held ? .black : Color(red: 0.65, green: 0.83, blue: 0.94)))
                        .overlay(alignment: .topTrailing) {
                            if output.needsPermission {
                                Circle().fill(.orange).frame(width: 7, height: 7).padding(5)
                                    .help("Typing access is missing for this running copy. Open the AirKey menu to enable it.")
                            }
                        }
                        .overlay(KeyboardDragHandle(dragging: onMouseDrag))
                        .frame(width: handle.width, height: handle.height)
                        .position(x: handle.midX, y: handle.midY)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .onAppear { keyboard.setSceneSize(geometry.size) }
            .onChange(of: geometry.size) { keyboard.setSceneSize($0) }
            .onContinuousHover { phase in if case .active = phase { onActivity() } }
        }
        .frame(minWidth: 1040, idealWidth: 1100, minHeight: 444, idealHeight: 444)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func keyboardSurface(size: CGSize) -> some View {
        let panel = keyboard.layout.panelFrame(in: size)
        let frames = keyboard.layout.keyFrames(in: size)
        let hovered = Set(keyboard.hovered.values)
        RoundedRectangle(cornerRadius: 22)
            .fill(Color(red: 0.10, green: 0.13, blue: 0.17).opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.09)))
            .frame(width: panel.width, height: panel.height)
            .position(x: panel.midX, y: panel.midY)
        if camera.cameraGhostEnabled {
            CameraGhostView(frames: camera.frames, size: size, panel: panel)
        }
        ForEach(keyboard.layout.keys) { key in
            if let rect = frames[key.id] {
                let active = keyboard.pressed.contains(key.id) || (key.id == "caps" && keyboard.caps)
                Button { keyboard.activate(key.id) } label: {
                    keyFace(key, active: active, hovered: hovered.contains(key.id))
                        .frame(width: rect.width, height: rect.height)
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(keyboard.calibration?.key == key.id ? Color.yellow : .clear, lineWidth: 4))
                        .overlay {
                            if keyboard.calibration?.key == key.id {
                                Circle().stroke(Color.yellow, lineWidth: 2)
                                    .frame(width: 34, height: 34)
                                    .allowsHitTesting(false)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.label)
                .position(x: rect.midX, y: rect.midY)
            }
        }
        let suggestions = keyboard.layout.suggestionFrames(in: size, count: keyboard.suggestions.count)
        ForEach(Array(keyboard.suggestions.enumerated()), id: \.offset) { index, word in
            if index < suggestions.count {
                let rect = suggestions[index]
                Button { keyboard.activate("pred_\(index)") } label: {
                    Text(keyboard.suggestionLabel(at: index))
                        .font(.system(size: 19, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(width: rect.width, height: rect.height)
                        .foregroundStyle(.white)
                        .background(hovered.contains("pred_\(index)") ? Color.mint.opacity(0.30) : Color.white.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.mint.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Use suggestion \(keyboard.suggestionLabel(at: index))")
                .position(x: rect.midX, y: rect.midY)
            }
        }
    }

    private func keyFace(_ key: KeySpec, active: Bool, hovered: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(active ? Color.mint : Color.white.opacity(hovered ? 0.20 : 0.075))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(hovered ? Color.mint.opacity(0.8) : Color.white.opacity(0.05), lineWidth: 1.5))
            .overlay {
                if let image = key.systemImage {
                    Image(systemName: image).font(.system(size: 21, weight: .medium))
                } else {
                    Text(key.isLetter && !keyboard.caps ? key.label.lowercased() : key.label)
                        .font(.system(size: key.isLetter ? 24 : 17, weight: .medium, design: .rounded))
                }
            }
            .foregroundStyle(active ? Color.black : Color.white.opacity(0.92))
    }

}
