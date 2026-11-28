import SwiftUI
import PhotosUI
import CloudKit
import Combine

// screens you can open from Account
enum ProfileRoute: Hashable {
    case editProfile, country, settings, howToUse, dataSources
}

// MARK: - Avatar (photo, else icon, else initials)
struct AvatarView: View {
    var size: CGFloat

    @AppStorage(AppSettings.Key.profileIcon) private var icon = ""
    @AppStorage(AppSettings.Key.profileName) private var name = ""
    @AppStorage(AppSettings.Key.avatarVersion) private var version = 0
    @State private var photo: UIImage?

    // the two colors of the app icon (from the first Figma mockup, a bit brighter)
    static let iconGradient = LinearGradient(
        colors: [Color(red: 0x16 / 255, green: 0x7A / 255, blue: 0x6D / 255),
                 Color(red: 0x28 / 255, green: 0x50 / 255, blue: 0x9C / 255)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if let choice = AvatarIcon.option(for: icon) {
                // an emoji on a soft circle of its own color, like the emoji avatars in Contacts
                AvatarIcon.Background(color: choice.color)
                Text(verbatim: choice.emoji)
                    .font(.system(size: size * 0.55))
            } else {
                // same gradient as the app icon, white on top: visible in light and dark mode
                // (the pale circle from before almost disappeared on a dark background)
                Circle().fill(Self.iconGradient)
                Group {
                    if !icon.isEmpty {
                        Image(systemName: icon)
                            .font(.system(size: size * 0.45, weight: .medium))
                    } else if !initials.isEmpty {
                        Text(initials)
                            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45, weight: .medium))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .task(id: version) { photo = AvatarStore.load() }
        .accessibilityHidden(true)
    }
}

// MARK: - Account
// the account is the Apple Account already on the iPhone: nothing to sign up for
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.profileName) private var name = ""
    @AppStorage(AppSettings.Key.profileUsername) private var username = ""
    @AppStorage(AppSettings.Key.country) private var country = ""

    private var countryCode: String { country.isEmpty ? AppSettings.defaultCountry : country }

    var body: some View {
        NavigationStack {
            List {
                header

                ICloudSection()

                Section {
                    NavigationLink(value: ProfileRoute.editProfile) {
                        Label("Edit Profile", systemImage: "person.crop.circle")
                    }
                    PlaceholderRow("Sharing", systemImage: "person.2")
                    NavigationLink(value: ProfileRoute.country) {
                        LabeledContent {
                            Text(verbatim: "\(Countries.flag(countryCode)) \(Countries.name(countryCode))")
                        } label: {
                            Label("Country", systemImage: "globe")
                        }
                    }
                } footer: {
                    Text("Your country decides which products appear first when you type a name.")
                }

                Section {
                    NavigationLink(value: ProfileRoute.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                switch route {
                case .editProfile: EditProfileView()
                case .country: CountryPickerView(selection: $country)
                case .settings: SettingsView()
                case .howToUse: HowToUseView()
                case .dataSources: DataSourcesView()
                }
            }
        }
    }

    private var header: some View {
        Section {
            VStack(spacing: 8) {
                AvatarView(size: 96)
                Text(name.isEmpty ? String(localized: "Your name") : name)
                    .font(.title2.bold())
                    .foregroundStyle(name.isEmpty ? .secondary : .primary)
                if !username.isEmpty {
                    Text(verbatim: "@\(username)").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }
}

// MARK: - iCloud
// shows if the pantry is syncing. it only asks iCloud, no data leaves the app
private struct ICloudSection: View {
    @State private var status: CKAccountStatus?

    var body: some View {
        Section {
            LabeledContent {
                Text(statusText)
            } label: {
                Label("iCloud", systemImage: status == .available ? "checkmark.icloud" : "icloud.slash")
            }
        } footer: {
            if let footerText { Text(footerText) }
        }
        .task { await refresh() }
        // the user can sign in or out of iCloud while the app is open
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)
                    .receive(on: DispatchQueue.main)) { _ in
            Task { await refresh() }
        }
    }

    private var statusText: LocalizedStringKey {
        switch status {
        case nil: "Checking…"
        case .some(.available): "On"
        case .some(.noAccount): "Off"
        default: "Not available"
        }
    }

    private var footerText: LocalizedStringKey? {
        switch status {
        case nil: nil
        case .some(.available): "Your pantry is saved in your iCloud and stays the same on all your devices. Only you can see it."
        case .some(.noAccount): "Sign in to iCloud in the Settings app to keep your pantry on all your devices. Until then, it stays on this iPhone."
        default: "iCloud isn't available right now. Your pantry stays on this iPhone and syncs when iCloud is back."
        }
    }

    private func refresh() async {
        status = (try? await CKContainer(identifier: AppModel.cloudContainerID).accountStatus()) ?? .couldNotDetermine
    }
}

// MARK: - Edit Profile
struct EditProfileView: View {
    @AppStorage(AppSettings.Key.profileName) private var name = ""
    @AppStorage(AppSettings.Key.profileUsername) private var username = ""
    @AppStorage(AppSettings.Key.profileIcon) private var icon = ""
    @AppStorage(AppSettings.Key.avatarVersion) private var avatarVersion = 0

    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showIcons = false
    @State private var hasPhoto = false

    // only letters, numbers, . and _ (max 24)
    private var usernameBinding: Binding<String> {
        Binding(
            get: { username },
            set: { newValue in
                username = String(newValue.lowercased()
                    .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
                    .prefix(24))
            }
        )
    }

    var body: some View {
        Form {
            Section {
                AvatarView(size: 96)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
                Button { showIcons = true } label: { Label("Choose Icon", systemImage: "face.smiling") }
                if hasPhoto || !icon.isEmpty {
                    Button("Remove Photo or Icon", systemImage: "trash", role: .destructive) {
                        AvatarStore.remove()
                        icon = ""
                    }
                }
            } header: {
                Text("Avatar")
            } footer: {
                Text("Without a photo or an icon, your initials are shown.")
            }

            Section {
                TextField("Name", text: $name)
                    .textContentType(.name)
                TextField("Username", text: usernameBinding)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Profile")
            } footer: {
                Text("People you share with will see your name and username.")
            }
        }
        .navigationTitle("Edit Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: avatarVersion) { hasPhoto = AvatarStore.load() != nil }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    AvatarStore.save(image)
                    icon = ""   // photo wins over icon
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                AvatarStore.save(image)
                icon = ""
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showIcons) {
            IconPickerSheet(icon: $icon)
        }
    }
}

// MARK: - Avatar icons
// Apple's own emoji, so they have exactly the colors people know from Messages and Contacts
// (the SF Symbols we had were all one color, and only a few food symbols have a multicolor
// version). each one sits on a soft circle of its own color, like the emoji avatars in Contacts.
// VoiceOver reads each emoji's name by itself, in the phone's language
enum AvatarIcon {
    struct Option: Identifiable {
        let emoji: String
        let color: Color
        var id: String { emoji }
    }

    static let options: [Option] = [
        Option(emoji: "🥕", color: .orange), Option(emoji: "🍎", color: .red),
        Option(emoji: "🥑", color: .green), Option(emoji: "🍋", color: .yellow),
        Option(emoji: "🍓", color: .pink), Option(emoji: "🥦", color: .mint),
        Option(emoji: "🧀", color: .yellow), Option(emoji: "🥐", color: .orange),
        Option(emoji: "🍝", color: .red), Option(emoji: "🍣", color: .cyan),
        Option(emoji: "☕️", color: .brown), Option(emoji: "🍰", color: .pink),
    ]

    // nil for icons saved before (SF Symbol names like "carrot.fill"): those still show as before
    static func option(for stored: String) -> Option? {
        options.first { $0.emoji == stored }
    }

    // solid, so it looks the same on a list, on the toolbar glass, in light and dark mode
    struct Background: View {
        let color: Color
        var body: some View {
            ZStack {
                Circle().fill(Color(.secondarySystemBackground))
                Circle().fill(color.opacity(0.3))
            }
        }
    }
}

private struct IconPickerSheet: View {
    @Binding var icon: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 16) {
                    ForEach(AvatarIcon.options) { option in
                        Button {
                            icon = option.emoji
                            AvatarStore.remove()   // icon wins over photo
                            dismiss()
                        } label: {
                            Text(verbatim: option.emoji)
                                .font(.system(size: 38))
                                .frame(width: 72, height: 72)
                                .background { AvatarIcon.Background(color: option.color) }
                                .overlay {
                                    if icon == option.emoji {
                                        Circle().strokeBorder(.tint, lineWidth: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(icon == option.emoji ? .isSelected : [])
                    }
                }
                .padding()
            }
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Country
struct CountryPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var current: String { selection.isEmpty ? AppSettings.defaultCountry : selection }
    private var results: [String] {
        search.isEmpty ? Countries.all : Countries.all.filter { Countries.name($0).localizedStandardContains(search) }
    }

    var body: some View {
        List(results, id: \.self) { code in
            Button {
                selection = code
                dismiss()
            } label: {
                HStack {
                    Text(verbatim: "\(Countries.flag(code))  \(Countries.name(code))")
                        .foregroundStyle(.primary)
                    Spacer()
                    if code == current {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
            }
            .accessibilityAddTraits(code == current ? .isSelected : [])
        }
        .searchable(text: $search, prompt: "Search countries")
        .navigationTitle("Country")
        .navigationBarTitleDisplayMode(.inline)
    }
}
