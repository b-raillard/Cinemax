#if os(iOS)
import SwiftUI
import CinemaxKit

/// Array-of-strings editor rendered as removable chips + an inline "add"
/// text field. Used by the metadata editor for Genres, Tags, Taglines, and
/// Studios-by-name. Kept deliberately lightweight — no drag-reorder,
/// no autocomplete — since the admin use case is "type a new value and
/// commit".
struct ChipEditor: View {
    @Binding var items: [String]
    let placeholder: String

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            if !items.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, value in
                        chip(value, at: index)
                    }
                }
            }

            HStack(spacing: CinemaSpacing.spacing2) {
                TextField(placeholder, text: $draft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled(false)
                    .onSubmit(commit)
                    .font(.system(size: CinemaScale.pt(14)))
                    .padding(.horizontal, CinemaSpacing.spacing3)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .background(CinemaColor.surfaceContainerHighest.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))

                Button(action: commit) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1.0)
            }
        }
    }

    private func chip(_ value: String, at index: Int) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(CinemaFont.label(.small))
                .foregroundStyle(CinemaColor.onSurface)
            Button {
                items.remove(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: CinemaScale.pt(13)))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized("admin.metadata.chip.remove"))
        }
        .padding(.horizontal, CinemaSpacing.spacing2)
        .padding(.vertical, 4)
        .background(Capsule().fill(CinemaColor.surfaceContainerHigh))
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !items.contains(trimmed) else { return }
        items.append(trimmed)
        draft = ""
    }
}

/// String key-value editor used for `providerIDs: [String:String]?` (IMDB,
/// TMDB, TVDB, MusicBrainz, etc.). Rows are editable inline; an empty
/// trailing row lets you append. Removing clears the key — backend wipes
/// the provider from the item.
struct KeyValueEditor: View {
    @Binding var dict: [String: String]
    let keyPlaceholder: String
    let valuePlaceholder: String

    @Environment(ThemeManager.self) private var themeManager
    @Environment(LocalizationManager.self) private var loc
    @State private var draftKey: String = ""
    @State private var draftValue: String = ""

    private var sortedPairs: [(String, String)] {
        dict.sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            ForEach(sortedPairs, id: \.0) { key, value in
                kvRow(key: key, value: value)
            }

            HStack(spacing: CinemaSpacing.spacing2) {
                TextField(keyPlaceholder, text: $draftKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: CinemaScale.pt(13), design: .monospaced))
                    .frame(width: 100)
                    .padding(.horizontal, CinemaSpacing.spacing2)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .background(CinemaColor.surfaceContainerHighest.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))

                TextField(valuePlaceholder, text: $draftValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: CinemaScale.pt(13), design: .monospaced))
                    .padding(.horizontal, CinemaSpacing.spacing2)
                    .padding(.vertical, CinemaSpacing.spacing2)
                    .background(CinemaColor.surfaceContainerHighest.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))

                Button(action: commit) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: CinemaScale.pt(20), weight: .semibold))
                        .foregroundStyle(themeManager.accent)
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .opacity(canCommit ? 1.0 : 0.4)
            }
        }
    }

    @ViewBuilder
    private func kvRow(key: String, value: String) -> some View {
        HStack(spacing: CinemaSpacing.spacing2) {
            Text(key)
                .font(.system(size: CinemaScale.pt(13), design: .monospaced))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .frame(width: 100, alignment: .leading)

            TextField("", text: Binding(
                get: { dict[key] ?? value },
                set: { dict[key] = $0.isEmpty ? nil : $0 }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: CinemaScale.pt(13), design: .monospaced))
            .padding(.horizontal, CinemaSpacing.spacing2)
            .padding(.vertical, CinemaSpacing.spacing2)
            .background(CinemaColor.surfaceContainerHighest.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: CinemaRadius.small))

            Button {
                dict.removeValue(forKey: key)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: CinemaScale.pt(18)))
                    .foregroundStyle(CinemaColor.error.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc.localized("admin.metadata.kv.remove"))
        }
    }

    private var canCommit: Bool {
        let k = draftKey.trimmingCharacters(in: .whitespaces)
        let v = draftValue.trimmingCharacters(in: .whitespaces)
        return !k.isEmpty && !v.isEmpty && dict[k] == nil
    }

    private func commit() {
        let k = draftKey.trimmingCharacters(in: .whitespaces)
        let v = draftValue.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, !v.isEmpty, dict[k] == nil else { return }
        dict[k] = v
        draftKey = ""
        draftValue = ""
    }
}
#endif
