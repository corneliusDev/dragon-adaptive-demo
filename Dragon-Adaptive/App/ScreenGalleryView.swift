//  ScreenGalleryView.swift
//  Debug menu: every screen the renderer draws, with the design's sample
//  numbers (ScreenGallery), in miles or kilometres, full or reduced (the
//  one-element budget). The chosen screen shows on the phone mirror here, and
//  SEND TO GLASSES holds it on the glasses until the gallery is closed or
//  LIVE HUD is tapped.

import SwiftUI
import DragonEngine

struct ScreenGalleryView: View {
    @ObservedObject var hud: HUDController
    @Environment(\.dismiss) private var dismiss
    @State private var unit: DistanceUnit = .miles
    @State private var form: Renderer.Form = .full
    @State private var selected = "split"

    private let phos = Color(red: 57 / 255, green: 226 / 255, blue: 122 / 255)
    private let amber = Color(red: 1, green: 0.54, blue: 0.24)

    private var samples: [ScreenSample] { ScreenGallery.samples(unit: unit) }
    private var sample: ScreenSample? { samples.first { $0.name == selected } ?? samples.first }
    private var frame: HUDFrame { sample?.frame(form, unit: unit) ?? HUDFrame() }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("SCREEN GALLERY").font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer()
                Button("DONE") { dismiss() }
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(phos)
                    .accessibilityIdentifier("galleryDone")
            }
            MirrorView(frame: frame)
                .accessibilityIdentifier("galleryMirror")
            Text(sample.map { "\($0.title) · \(form.rawValue.uppercased())" } ?? "—")
                .font(.system(size: 12, design: .monospaced)).foregroundColor(amber)
                .accessibilityIdentifier("galleryCaption")
            HStack(spacing: 10) {
                seg("MI", unit == .miles) { unit = .miles }
                seg("KM", unit == .kilometers) { unit = .kilometers }
                Spacer()
                seg("FULL", form == .full) { form = .full }
                seg("REDUCED", form == .reduced) { form = .reduced }
            }
            HStack(spacing: 10) {
                Button("SEND TO GLASSES") { hud.showOnGlasses(frame) }
                    .accessibilityIdentifier("gallerySend")
                Button("LIVE HUD") { hud.resumeLiveHUD() }
                Spacer()
                Text(hud.galleryFrame == nil ? "LIVE" : "HELD")
                    .foregroundColor(hud.galleryFrame == nil ? .gray : phos)
                    .accessibilityIdentifier("galleryHeld")
            }
            .font(.system(size: 11, design: .monospaced)).foregroundColor(.white)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(samples, id: \.name) { s in
                        Button {
                            selected = s.name
                        } label: {
                            HStack {
                                Text(s.title).foregroundColor(s.name == selected ? phos : .white)
                                Spacer()
                                Text(s.name).foregroundColor(.gray)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("gallery.\(s.name)")
                        Divider().background(Color(white: 0.15))
                    }
                }
            }
        }
        .padding(16)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func seg(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(on ? phos : .gray)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color(white: 0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(white: 0.2)))
    }
}
