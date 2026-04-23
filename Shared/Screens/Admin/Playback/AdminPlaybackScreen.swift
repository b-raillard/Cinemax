#if os(iOS)
import SwiftUI
import CinemaxKit
@preconcurrency import JellyfinAPI

/// Server-side transcoding defaults. Pragmatic subset of Jellyfin web's
/// Lecture admin panel — the levers most worth flipping from a phone.
/// Full parity (CRF values, preset pickers, container/codec allow-lists,
/// NVDEC/QSV sub-tuning) is intentionally out of scope: those are
/// one-time setup decisions better made from the web admin on a desktop.
struct AdminPlaybackScreen: View {
    @Environment(AppState.self) private var appState
    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @Environment(ToastCenter.self) private var toasts

    @State private var viewModel = AdminPlaybackViewModel()

    var body: some View {
        AdminLoadStateContainer(
            isLoading: viewModel.isLoading && viewModel.edited == nil,
            errorMessage: viewModel.errorMessage,
            isEmpty: false,
            onRetry: { Task { await viewModel.load(using: appState.apiClient) } }
        ) {
            if viewModel.edited != nil {
                AdminFormScreen(
                    isDirty: viewModel.isDirty,
                    isSaving: viewModel.isSaving,
                    onSave: {
                        let ok = await viewModel.save(using: appState.apiClient)
                        if ok {
                            toasts.success(loc.localized("admin.playback.save.success"))
                        } else if let err = viewModel.errorMessage {
                            toasts.error(err)
                        }
                    }
                ) {
                    hardwareSection
                    encodingSection
                    processingSection
                    pathsSection
                }
            }
        }
        .background(CinemaColor.surface.ignoresSafeArea())
        .navigationTitle(loc.localized("admin.playback.title"))
        .navigationBarTitleDisplayMode(.large)
        .task {
            if viewModel.edited == nil {
                await viewModel.load(using: appState.apiClient)
            }
        }
    }

    // MARK: - Sections

    private var hardwareSection: some View {
        AdminSectionGroup(
            loc.localized("admin.playback.hardware.title"),
            footer: loc.localized("admin.playback.hardware.footer")
        ) {
            hardwareAccelRow
            iOSSettingsDivider
            toggleRow(
                icon: "cpu",
                label: loc.localized("admin.playback.enableHardwareEncoding"),
                binding: binding(\.enableHardwareEncoding)
            )
        }
    }

    private var encodingSection: some View {
        AdminSectionGroup(loc.localized("admin.playback.encoding.title")) {
            toggleRow(
                icon: "sparkles.tv",
                label: loc.localized("admin.playback.allowHevc"),
                binding: binding(\.allowHevcEncoding)
            )
            iOSSettingsDivider
            toggleRow(
                icon: "sparkles.tv",
                label: loc.localized("admin.playback.allowAv1"),
                binding: binding(\.allowAv1Encoding)
            )
        }
    }

    private var processingSection: some View {
        AdminSectionGroup(loc.localized("admin.playback.processing.title")) {
            toggleRow(
                icon: "gauge.with.dots.needle.33percent",
                label: loc.localized("admin.playback.enableThrottling"),
                binding: binding(\.enableThrottling)
            )
            iOSSettingsDivider
            toggleRow(
                icon: "circle.hexagongrid",
                label: loc.localized("admin.playback.enableTonemapping"),
                binding: binding(\.enableTonemapping)
            )
            iOSSettingsDivider
            toggleRow(
                icon: "captions.bubble",
                label: loc.localized("admin.playback.enableSubtitleExtraction"),
                binding: binding(\.enableSubtitleExtraction)
            )
        }
    }

    @ViewBuilder
    private var pathsSection: some View {
        if let options = viewModel.edited {
            AdminSectionGroup(
                loc.localized("admin.playback.paths.title"),
                footer: loc.localized("admin.playback.paths.footer")
            ) {
                readOnlyPathRow(
                    label: loc.localized("admin.playback.encoderPath"),
                    value: options.encoderAppPathDisplay ?? options.encoderAppPath ?? "—"
                )
                iOSSettingsDivider
                readOnlyPathRow(
                    label: loc.localized("admin.playback.transcodingTempPath"),
                    value: options.transcodingTempPath ?? "—"
                )
            }
        }
    }

    // MARK: - Rows

    private var hardwareAccelRow: some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: "bolt", color: themeManager.accent)
                Text(loc.localized("admin.playback.hardwareAcceleration"))
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Menu {
                    ForEach(HardwareAccelerationType.allCases, id: \.self) { option in
                        Button {
                            viewModel.edited?.hardwareAccelerationType = option
                        } label: {
                            if viewModel.edited?.hardwareAccelerationType == option {
                                Label(hwAccelLabel(for: option), systemImage: "checkmark")
                            } else {
                                Text(hwAccelLabel(for: option))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(hwAccelLabel(for: viewModel.edited?.hardwareAccelerationType ?? .none))
                            .font(CinemaFont.label(.large))
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: CinemaScale.pt(11), weight: .semibold))
                            .foregroundStyle(CinemaColor.outlineVariant)
                    }
                }
                .tint(themeManager.accent)
            }
        }
    }

    private func hwAccelLabel(for type: HardwareAccelerationType) -> String {
        switch type {
        case .none: return loc.localized("admin.playback.hwAccel.none")
        case .amf: return "AMD AMF"
        case .qsv: return "Intel QSV"
        case .nvenc: return "NVIDIA NVENC"
        case .v4l2m2m: return "V4L2M2M"
        case .vaapi: return "VAAPI"
        case .videotoolbox: return "VideoToolbox"
        case .rkmpp: return "Rockchip RKMPP"
        }
    }

    @ViewBuilder
    private func toggleRow(icon: String, label: String, binding: Binding<Bool>) -> some View {
        iOSSettingsRow {
            HStack {
                iOSRowIcon(systemName: icon, color: themeManager.accent)
                Text(label)
                    .font(CinemaFont.label(.large))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Button { binding.wrappedValue.toggle() } label: {
                    CinemaToggleIndicator(isOn: binding.wrappedValue, accent: themeManager.accent, animated: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func readOnlyPathRow(label: String, value: String) -> some View {
        iOSSettingsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
                Text(value)
                    .font(.system(size: CinemaScale.pt(13), design: .monospaced))
                    .foregroundStyle(CinemaColor.onSurface)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Binding helper

    /// Binds a Bool? field on EncodingOptions through a non-optional Bool
    /// surface — defaulting nil to false on read, keeping nil-as-false
    /// symmetry on write (we always write the explicit bool).
    private func binding(_ keyPath: WritableKeyPath<EncodingOptions, Bool?>) -> Binding<Bool> {
        Binding(
            get: { viewModel.edited?[keyPath: keyPath] ?? false },
            set: { viewModel.edited?[keyPath: keyPath] = $0 }
        )
    }
}
#endif
