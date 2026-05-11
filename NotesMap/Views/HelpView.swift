// HelpView.swift, In-App-Hilfe.
//
// Wird über das Hilfe-Menü oder ⌘? geöffnet, ein eigenes Fenster mit Sidebar
// links + Content rechts. Inhalte kommen aus HelpContent.swift, gerendert
// werden die einzelnen Block-Typen (Paragraph, Heading, Bullets, Shortcuts,
// Note, Link).
//
// Sprache: zieht beim Render-Zeitpunkt LanguagePreference.current.resolved.
// Wenn der User die Sprache in den Einstellungen umschaltet, fällt der
// nächste Aufruf der Hilfe automatisch auf die neue Sprache, kein Listener
// notwendig (das Fenster wird beim Schließen verworfen).

import SwiftUI
import AppKit

// MARK: - Sektion-Enum

private enum HelpSection: Hashable, CaseIterable, Identifiable {
    case overview, views, controls, shortcuts, heightmap, privacy, troubleshooting, about

    var id: Self { self }

    /// SF-Symbol für die Sidebar.
    var iconSystemName: String {
        switch self {
        case .overview:        return "map"
        case .views:           return "rectangle.3.group"
        case .controls:        return "hand.tap"
        case .shortcuts:       return "keyboard"
        case .heightmap:       return "mountain.2"
        case .privacy:         return "lock.shield"
        case .troubleshooting: return "wrench.and.screwdriver"
        case .about:           return "info.circle"
        }
    }

    /// Lokalisierter Sidebar-Titel.
    var title: String {
        switch self {
        case .overview:        return Localized.string(\.helpSidebarOverview)
        case .views:           return Localized.string(\.helpSidebarViews)
        case .controls:        return Localized.string(\.helpSidebarControls)
        case .shortcuts:       return Localized.string(\.helpSidebarShortcuts)
        case .heightmap:       return Localized.string(\.helpSidebarHeightmap)
        case .privacy:         return Localized.string(\.helpSidebarPrivacy)
        case .troubleshooting: return Localized.string(\.helpSidebarTroubleshooting)
        case .about:           return Localized.string(\.helpSidebarAbout)
        }
    }

    /// Liefert die Block-Liste für diese Sektion in der gewählten Sprache.
    func blocks(in lang: Localized.Lang) -> [HelpContent.Block] {
        switch self {
        case .overview:        return HelpContent.overview(in: lang)
        case .views:           return HelpContent.views(in: lang)
        case .controls:        return HelpContent.controls(in: lang)
        case .shortcuts:       return HelpContent.shortcuts(in: lang)
        case .heightmap:       return HelpContent.heightmap(in: lang)
        case .privacy:         return HelpContent.privacy(in: lang)
        case .troubleshooting: return HelpContent.troubleshooting(in: lang)
        case .about:           return HelpContent.about(in: lang)
        }
    }
}

// MARK: - Haupt-View

struct HelpView: View {
    @State private var selection: HelpSection = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            content
        }
        .navigationTitle(Localized.string(\.helpWindowTitle))
        .frame(minWidth: 800, minHeight: 600)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(HelpSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.iconSystemName)
                .tag(section)
        }
        .listStyle(.sidebar)
    }

    // MARK: - Content

    private var content: some View {
        let lang = LanguagePreference.current.resolved
        let blocks = selection.blocks(in: lang)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Großer Sektion-Titel oben
                Text(selection.title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.bottom, 4)

                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Block-Renderer

private struct HelpBlockView: View {
    let block: HelpContent.Block

    var body: some View {
        switch block {
        case .heading(let text):
            Text(text)
                .font(.title2)
                .fontWeight(.semibold)
                .padding(.top, 6)

        case .paragraph(let text):
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("•")
                            .foregroundStyle(.secondary)
                            .frame(width: 10, alignment: .leading)
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }
                }
            }

        case .shortcuts(let rows):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 14) {
                        Text(row.keys)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                            .frame(minWidth: 130, alignment: .leading)
                        Text(row.desc)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                }
            }

        case .note(let text):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tint)
                    .font(.callout)
                    .padding(.top, 2)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
            )

        case .link(let text, let urlString):
            // SwiftUI's Link braucht eine echte URL. Falls die String-URL aus
            // HelpContent kaputt ist, fallback auf simple Text-Anzeige.
            if let url = URL(string: urlString) {
                Link(destination: url) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square")
                        Text(text)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text(text)
                    .foregroundStyle(.secondary)
            }

        case .image(let filename, let caption):
            // Screenshot aus dem App-Bundle. xcodegen mit `type: folder` flacht
            // die Resources/screenshots/-Subdirectory aus, alle JPGs landen
            // direkt unter Contents/Resources/. Daher kein subdirectory-Param.
            // Fallback auf Platzhalter, falls das File aus irgendeinem Grund
            // nicht im Bundle ist.
            VStack(alignment: .leading, spacing: 6) {
                if let url = Bundle.main.url(forResource: filename, withExtension: nil),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 200)
                        .overlay(
                            Text("Screenshot fehlt: \(filename)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        )
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

#Preview {
    HelpView()
        .frame(width: 1000, height: 700)
}
