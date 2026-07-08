import AppKit
import SwiftUI

/// Renders marketing screenshots straight from the real UI (no desktop capture),
/// so README/release images stay accurate and reproducible. Invoked via
/// `ClaudeUsage --screenshots [outDir]`. Writes hero.png (in-context scene),
/// plus standalone popover.png and menubar.png.
@MainActor
enum Screenshots {
    static func render(to dir: String) {
        let model = sampleModel()
        write(popoverPanel(model), to: "\(dir)/popover.png")
        write(menuChip(), to: "\(dir)/menubar.png")
        write(hero(model), to: "\(dir)/hero.png")
        print("wrote popover.png, menubar.png, hero.png to \(dir)")
    }

    // MARK: - Sample state (matches the 58% / 56% example)

    static func sampleModel() -> PopoverModel {
        let now = Date()
        let model = PopoverModel()
        model.snapshot = UsageSnapshot(
            sessionPercent: 58,
            sessionResetsAt: now.addingTimeInterval(30 * 60),
            weeklyPercent: 56,
            weeklyResetsAt: now.addingTimeInterval((2 * 24 + 8) * 3600),
            extraUsageEnabled: false,
            status: .ok,
            lastUpdated: now.addingTimeInterval(-55))
        return model
    }

    // MARK: - Pieces

    @ViewBuilder
    static func popoverPanel(_ model: PopoverModel) -> some View {
        PopoverView(model: model)
            .frame(width: 360)
            .background(Color(red: 0.118, green: 0.118, blue: 0.129))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    static func menuChip() -> some View {
        HStack(spacing: 6) {
            Image(nsImage: StatusItemController.ringImage(percent: 58, tier: Tier.of(58), diameter: 16, lineWidth: 2.2))
            Text("58%").font(.system(size: 14, weight: .medium).monospacedDigit()).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(red: 0.13, green: 0.13, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .environment(\.colorScheme, .dark)
        .padding(24)
    }

    // MARK: - Hero scene (wallpaper + menu bar + popover)

    @ViewBuilder
    static func hero(_ model: PopoverModel) -> some View {
        let width: CGFloat = 1040
        let height: CGFloat = 720

        ZStack(alignment: .topTrailing) {
            // macOS-inspired wallpaper
            LinearGradient(
                colors: [
                    Color(red: 0.26, green: 0.43, blue: 0.74),
                    Color(red: 0.40, green: 0.40, blue: 0.75),
                    Color(red: 0.60, green: 0.44, blue: 0.74),
                    Color(red: 0.82, green: 0.54, blue: 0.63),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), .clear, Color.black.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom))
                .frame(width: width, height: height)

            // Menu bar across the top, with our item among the system icons.
            VStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    Color.black.opacity(0.42)
                    HStack(spacing: 16) {
                        HStack(spacing: 6) {
                            Image(nsImage: StatusItemController.ringImage(percent: 58, tier: Tier.of(58), diameter: 15, lineWidth: 2.0))
                            Text("58%").font(.system(size: 13, weight: .medium).monospacedDigit())
                        }
                        Image(systemName: "wifi")
                        Image(systemName: "battery.75")
                        Text("9:41")
                    }
                    .foregroundStyle(.white)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.trailing, 22)
                }
                .frame(height: 28)
                Spacer()
            }
            .frame(width: width, height: height)

            // Popover dropping from the menu-bar item.
            popoverPanel(model)
                .shadow(color: .black.opacity(0.35), radius: 22, x: 0, y: 12)
                .padding(.top, 42)
                .padding(.trailing, 78)
        }
        .frame(width: width, height: height)
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Render to PNG

    private static func write<V: View>(_ view: V, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { print("render failed: \(path)"); return }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("png encode failed: \(path)"); return
        }
        do { try png.write(to: URL(fileURLWithPath: path)) }
        catch { print("write failed: \(path) — \(error)") }
    }
}
