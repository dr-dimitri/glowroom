import AppKit
import SwiftUI
import GlowroomCore

/// Export controls use a captured editing snapshot; changing the library
/// selection or the before/after comparison never changes an accepted export.
@MainActor
struct JPEGExportView: View {
    @ObservedObject var model: JPEGExportModel
    @ViewState private var showsLocation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.line)
            if let result = model.result {
                success(result)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        locationSection
                        fileSection
                        sizeSection
                        summary
                    }.padding(24)
                }
                .disabled(model.isExporting || model.needsOverwriteConfirmation || model.hasPausedBatch)
            }
            Divider().overlay(Theme.line)
            footer
        }
        .frame(width: 680, height: model.result == nil ? min(720, max(480, (NSScreen.main?.visibleFrame.height ?? 840) - 120)) : 410)
        .background(Theme.background)
        .foregroundStyle(Color.white.opacity(0.9))
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(model.isExporting)
        .alert("Vorhandene Datei ersetzen?", isPresented: Binding(
            get: { model.needsOverwriteConfirmation },
            set: { if !$0 { model.dismissOverwritePrompt() } }
        )) {
            Button("Ersetzen", role: .destructive) { model.confirmOverwrite() }
            Button("Abbrechen", role: .cancel) { model.declineOverwrite() }
        } message: {
            Text("„\(model.overwriteFilename)“ ist bereits vorhanden. Der Export ersetzt diese Datei durch die aktuelle Bearbeitung.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 24, weight: .light)).foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Foto exportieren").font(.system(size: 20, weight: .semibold))
                Text(model.sourceName).font(.system(size: 12)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(model.format == .jpeg ? "JPEG" : "HDR").font(.system(size: 10, weight: .semibold)).tracking(1)
                .foregroundStyle(Theme.muted).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 5))
        }.padding(24)
    }

    private var locationSection: some View {
        section("Speicherort", symbol: "folder") {
            row("Ordner") {
                HStack(spacing: 10) {
                    Text(model.destinationDirectory.lastPathComponent)
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.destinationDirectory.path)
                    Button("Auswählen …") { model.chooseDirectory() }
                        .controlSize(.small).accessibilityLabel("Exportordner auswählen")
                }
            }
            if model.isBatch {
                row("Dateinamen") {
                    Text("Originalname-bearbeitet.\(model.format.fileExtension)")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("Gleiche Namen erhalten eine fortlaufende Nummer. Vorhandene Dateien werden nur nach Bestätigung ersetzt.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                row("Dateiname") {
                    TextField("Bild-bearbeitet.\(model.format.fileExtension)", text: $model.filename)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Exportdateiname")
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "folder").accessibilityHidden(true)
                Text(model.destinationDirectory.path).lineLimit(showsLocation ? nil : 1)
                    .truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { showsLocation.toggle() } label: {
                    Image(systemName: showsLocation ? "chevron.up" : "chevron.down")
                }.buttonStyle(.plain)
                    .accessibilityLabel(showsLocation ? "Ordnerpfad einklappen" : "Vollständigen Ordnerpfad anzeigen")
            }.font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }

    private var fileSection: some View {
        section("Dateieinstellungen", symbol: "doc") {
            row("Bildformat") {
                Picker("Bildformat", selection: $model.format) {
                    ForEach(JPEGExportFormat.allCases, id: \.self) { format in Text(format.displayName).tag(format) }
                }.labelsHidden().accessibilityLabel("Exportformat")
            }
            row("Farbraum") {
                if model.format == .jpeg {
                    Picker("Farbraum", selection: $model.colorSpace) {
                        Text("sRGB").tag(JPEGExportColorSpace.sRGB)
                        Text("Display P3").tag(JPEGExportColorSpace.displayP3)
                    }.labelsHidden().accessibilityLabel("Farbraum des exportierten JPEG")
                } else {
                    Text("Rec. 2100 HLG · 10 Bit").font(.system(size: 12))
                }
            }
            row("Qualität") {
                HStack(spacing: 12) {
                    ResettableSlider(value: Binding(
                        get: { Double(min(100, max(0, Int(model.qualityText) ?? 90))) },
                        set: { model.qualityText = String(Int($0.rounded())) }
                    ), in: 0...100, step: 1, neutralValue: 90)
                    .accessibilityLabel("Exportqualität")
                    TextField("90", text: $model.qualityText).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 49).accessibilityLabel("Exportqualität in Prozent")
                    Text("%").foregroundStyle(Theme.muted)
                }
            }
            Text("Höhere Qualität bedeutet weniger Kompression und größere Dateien. Transparente Bereiche werden weiß hinterlegt.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            if model.format == .heif10HDR {
                Text("Speichert den erweiterten Helligkeitsumfang als 10-Bit-HEIF. Die HDR-Wirkung hängt vom Ausgangsbild, der Bearbeitung und dem Anzeigegerät ab.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sizeSection: some View {
        section("Bildgröße", symbol: "arrow.up.left.and.arrow.down.right") {
            row("Abmessungen") {
                Picker("Abmessungen", selection: $model.sizeMode) {
                    Text("Originalgröße").tag(JPEGExportSizeMode.original)
                    Text("Lange Kante").tag(JPEGExportSizeMode.longEdge)
                    Text("In Breite / Höhe einpassen").tag(JPEGExportSizeMode.fit)
                }.labelsHidden().accessibilityLabel("Größenanpassung")
            }
            if model.sizeMode == .longEdge {
                row("Lange Kante") {
                    pixelField("Lange Kante in Pixeln", text: $model.longEdgeText)
                    Spacer()
                }
            } else if model.sizeMode == .fit {
                row("Maximalgröße") {
                    HStack(spacing: 8) {
                        pixelField("Maximale Breite in Pixeln", text: $model.widthText)
                        Text("×").foregroundStyle(Theme.muted)
                        pixelField("Maximale Höhe in Pixeln", text: $model.heightText)
                        Spacer(minLength: 0)
                    }
                }
            }
            if model.sizeMode != .original {
                row("") {
                    Toggle("Kleinere Bilder vergrößern", isOn: $model.allowUpscaling)
                        .toggleStyle(.checkbox).font(.system(size: 11))
                }
            }
            row("Auflösung") {
                HStack(spacing: 8) {
                    TextField("300", text: $model.resolutionText).textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 70)
                        .accessibilityLabel("Druckauflösung in Pixel pro Zoll")
                    Text("Pixel / Zoll (ppi)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                }
            }
            Text("Das Seitenverhältnis bleibt erhalten. Die Auflösung beeinflusst die Druckgröße, nicht die Pixelanzahl.")
                .font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "photo").foregroundStyle(Theme.accent).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                if model.isBatch {
                    Text("\(model.sourceCount) Bilder mit gemeinsamen Exporteinstellungen")
                        .font(.system(size: 12, weight: .medium))
                } else if let size = model.estimatedSize {
                    Text("Voraussichtlich \(size.width) × \(size.height) Pixel")
                        .font(.system(size: 12, weight: .medium))
                } else {
                    Text("Ausgabegröße wird beim Export ermittelt").font(.system(size: 12, weight: .medium))
                }
                if !model.isBatch {
                    Text("Original: \(model.sourceDimensions)").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Text("Exportiert die Bearbeitung beim Öffnen dieses Dialogs.")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            Spacer()
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
    }

    private func success(_ result: JPEGExportResult) -> some View {
        VStack(spacing: 13) {
            Image(systemName: model.wasCancelled ? "stop.circle" : "checkmark.circle")
                .font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(model.isBatch ? "\(model.completedCount) von \(model.sourceCount) Fotos exportiert" : "Foto exportiert")
                .font(.system(size: 20, weight: .semibold))
            if model.isBatch {
                Text(model.wasCancelled ? "Export abgebrochen. Bereits exportierte Bilder bleiben gespeichert." : result.url.deletingLastPathComponent().path)
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else {
                Text(result.url.lastPathComponent).font(.system(size: 13)).lineLimit(2).textSelection(.enabled)
                Text("\(result.width) × \(result.height) Pixel").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            Button("Im Finder anzeigen") { model.revealResult() }.padding(.top, 3)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let message = model.errorMessage ?? (model.result == nil ? model.validationMessage : nil), !model.isExporting {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isBatch, model.isExporting || model.hasPausedBatch || model.needsOverwriteConfirmation {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: Double(model.completedCount), total: Double(model.sourceCount))
                        .accessibilityLabel("Exportfortschritt")
                    Text("\(model.completedCount) von \(model.sourceCount) exportiert · \(model.currentFilename)")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 12) {
                if model.isExporting {
                    ProgressView().controlSize(.small)
                    Text(model.isCancelling ? "Export wird abgebrochen …" : "Foto wird exportiert …")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .accessibilityLabel(model.isCancelling ? "Export wird abgebrochen" : "Export läuft")
                } else if model.result == nil {
                    Text("Originaldateien bleiben unverändert.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.result != nil {
                    Button("Fertig") { model.cancel() }.buttonStyle(AccentButton()).keyboardShortcut(.defaultAction)
                } else {
                    Button(model.isExporting ? "Export abbrechen" : "Abbrechen") { model.cancel() }
                        .keyboardShortcut(.cancelAction).disabled(model.isCancelling)
                    if !model.isExporting {
                        Button(model.hasPausedBatch ? "Erneut versuchen" : "Exportieren") { model.startExport() }.buttonStyle(AccentButton())
                            .keyboardShortcut(.defaultAction).disabled(!model.canExport)
                    }
                }
            }
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).accessibilityHidden(true)
                SectionLabel(text: title)
            }.foregroundStyle(Theme.muted)
            content()
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(width: 116, alignment: .leading)
            content()
        }
    }

    private func pixelField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 5) {
            TextField("Pixel", text: text).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing).frame(width: 76).accessibilityLabel(label)
            Text("px").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
    }
}
