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

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }

    var body: some View {
        ZStack {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else if !icon.isEmpty {
                Circle().fill(.tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(.tint)
            } else if !initials.isEmpty {
                Circle().fill(.tint.opacity(0.15))
                Text(initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tint)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
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

// temporary icons, we'll choose the real ones later
private struct IconPickerSheet: View {
    @Binding var icon: String
    @Environment(\.dismiss) private var dismiss

    static let icons = [
        "person.fill", "leaf.fill", "carrot.fill", "fork.knife",
        "cup.and.saucer.fill", "birthday.cake.fill", "fish.fill", "takeoutbag.and.cup.and.straw.fill",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 16)], spacing: 16) {
                    ForEach(Self.icons, id: \.self) { symbol in
                        Button {
                            icon = symbol
                            AvatarStore.remove()   // icon wins over photo
                            dismiss()
                        } label: {
                            Image(systemName: symbol)
                                .font(.title)
                                .frame(width: 72, height: 72)
                                .background(.tint.opacity(icon == symbol ? 0.3 : 0.12), in: .circle)
                        }
                        .accessibilityAddTraits(icon == symbol ? .isSelected : [])
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
