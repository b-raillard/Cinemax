import SwiftUI

struct LicensesView: View {
    @Environment(LocalizationManager.self) var loc
    @Environment(ThemeManager.self) var themeManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CinemaSpacing.spacing5) {
                    Text(loc.localized("settings.licenses.description"))
                        .font(CinemaFont.body)
                        .foregroundStyle(CinemaColor.onSurfaceVariant)
                        .padding(.bottom, CinemaSpacing.spacing2)

                    ForEach(licenses, id: \.name) { license in
                        licenseCard(license)
                    }
                }
                .padding(CinemaSpacing.spacing5)
            }
            .background(CinemaColor.surface.ignoresSafeArea())
            .navigationTitle(loc.localized("settings.licenses"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(CinemaColor.onSurfaceVariant)
                    }
                }
            }
            #endif
        }
    }

    @ViewBuilder
    func licenseCard(_ license: OSSLicense) -> some View {
        VStack(alignment: .leading, spacing: CinemaSpacing.spacing2) {
            HStack {
                Text(license.name)
                    .font(CinemaFont.headline(.small))
                    .foregroundStyle(CinemaColor.onSurface)
                Spacer()
                Text(license.version)
                    .font(CinemaFont.label(.medium))
                    .foregroundStyle(CinemaColor.onSurfaceVariant)
            }

            Text(license.url)
                .font(CinemaFont.label(.small))
                .foregroundStyle(themeManager.accent)

            Text(license.text)
                .font(.system(size: CinemaScale.pt(12), design: .monospaced))
                .foregroundStyle(CinemaColor.onSurfaceVariant)
                .padding(CinemaSpacing.spacing3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: CinemaRadius.medium)
                        .fill(CinemaColor.surfaceContainerLow)
                )
        }
        .padding(CinemaSpacing.spacing4)
        .glassPanel(cornerRadius: CinemaRadius.large)
    }

    // MARK: - License Data

    struct OSSLicense {
        let name: String
        let version: String
        let url: String
        let text: String
    }

    private let mitLicense = """
        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """

    private var licenses: [OSSLicense] {
        [
            OSSLicense(
                name: "Jellyfin SDK Swift",
                version: "0.6.0",
                url: "github.com/jellyfin/jellyfin-sdk-swift",
                text: "Copyright (c) Jellyfin Contributors\n\n" + mitLicense
            ),
            OSSLicense(
                name: "Nuke",
                version: "12.9.0",
                url: "github.com/kean/Nuke",
                text: "Copyright (c) Alexander Grebenyuk\n\n" + mitLicense
            ),
            OSSLicense(
                name: "Get",
                version: "2.2.1",
                url: "github.com/kean/Get",
                text: "Copyright (c) Alexander Grebenyuk\n\n" + mitLicense
            ),
        ]
    }
}
