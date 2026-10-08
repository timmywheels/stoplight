import SwiftUI
import AppKit

/// GitHub avatars, fetched once per login per launch and kept in memory. Rows ask for the same
/// handful of people over and over, so a dictionary beats URLCache round trips.
@MainActor @Observable
final class AvatarStore {
    static let shared = AvatarStore()
    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []

    func image(for login: String) -> NSImage? {
        let key = login.lowercased()
        if let img = images[key] { return img }
        load(key)
        return nil
    }

    private func load(_ key: String) {
        guard !loading.contains(key), !failed.contains(key) else { return }
        loading.insert(key)
        // Bots ("dependabot[bot]") have their avatar under the app's name.
        let name = key.replacingOccurrences(of: "[bot]", with: "")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://github.com/\(encoded).png?size=64") else { failed.insert(key); return }
        Task {
            let img = await Task.detached { () -> NSImage? in
                guard let (data, resp) = try? await URLSession.shared.data(from: url),
                      (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return NSImage(data: data)
            }.value
            loading.remove(key)
            if let img { images[key] = img } else { failed.insert(key) }
        }
    }
}

/// A round GitHub avatar; the login's first letter until (or unless) the picture arrives.
struct Avatar: View {
    let login: String
    var size: CGFloat = 16

    var body: some View {
        ZStack {
            if let img = AvatarStore.shared.image(for: login) {
                Image(nsImage: img).resizable().interpolation(.high).transition(.opacity)
            } else {
                Circle().fill(.quaternary)
                Text(login.prefix(1).uppercased())
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.2), value: AvatarStore.shared.images[login.lowercased()] != nil)
    }
}
