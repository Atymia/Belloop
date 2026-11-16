import SwiftUI
import PhotosUI
import AuthenticationServices

// screens you can open from Account (so after sign in we can go back easily)
enum ProfileRoute: Hashable {
    case editProfile, country, settings, signIn, email(EmailMode), howToUse, dataSources
}

enum EmailMode: Hashable { case signUp, signIn }

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
struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppSettings.Key.profileName) private var name = ""
    @AppStorage(AppSettings.Key.profileUsername) private var username = ""
    @AppStorage(AppSettings.Key.accountProvider) private var provider = ""
    @AppStorage(AppSettings.Key.accountEmail) private var email = ""
    @AppStorage(AppSettings.Key.appleUserID) private var appleUserID = ""
    @AppStorage(AppSettings.Key.country) private var country = ""

    @State private var path = NavigationPath()
    @State private var confirmSignOut = false
    @State private var confirmDelete = false

    private var isSignedIn: Bool { !provider.isEmpty }
    private var countryCode: String { country.isEmpty ? AppSettings.defaultCountry : country }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header

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

                if !isSignedIn {
                    Section {
                        NavigationLink(value: ProfileRoute.signIn) {
                            Label("Sign In or Create Account", systemImage: "person.badge.key")
                        }
                    }
                }

                Section {
                    NavigationLink(value: ProfileRoute.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }

                if isSignedIn {
                    Section {
                        Button("Sign Out", role: .destructive) { confirmSignOut = true }
                    }
                    Section {
                        Button("Delete Account", role: .destructive) { confirmDelete = true }
                    } footer: {
                        Text("Permanently deletes your account and your profile details. Your products stay on this iPhone.")
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
                case .signIn: SignInView()
                case .email(let mode): EmailAuthView(mode: mode)
                case .howToUse: HowToUseView()
                case .dataSources: DataSourcesView()
                }
            }
            // after login go back to Account
            .onChange(of: provider) { _, newValue in
                if !newValue.isEmpty { path = NavigationPath() }
            }
            .confirmationDialog("Sign out of your account?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { Task { await Accounts.service.signOut() } }
            } message: {
                Text("Your products stay on this iPhone.")
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { Task { try? await Accounts.service.deleteAccount() } }
            } message: {
                Text("This can't be undone.")
            }
            // if the user revoked Sign in with Apple, log out here too
            .task {
                guard provider == "apple", !appleUserID.isEmpty else { return }
                let state = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: appleUserID)
                if state == .revoked { await Accounts.service.signOut() }
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
                if isSignedIn && !email.isEmpty {
                    Text(verbatim: email).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
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

// MARK: - Sign in
struct SignInView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var errorText: String?

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "refrigerator.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(width: 96, height: 96)
                    .background(.tint, in: .rect(cornerRadius: 22))
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Welcome to \(appName)")
                        .font(.title.bold())
                        .multilineTextAlignment(.center)
                    Text("Sign in to keep your products in sync and share them with the people you live with.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    // needs the Sign in with Apple capability (paid account)
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        handleApple(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 50)
                    .clipShape(.capsule)

                    NavigationLink(value: ProfileRoute.email(.signUp)) {
                        Label("Continue with Email", systemImage: "envelope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }

                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }

                Text("By continuing, you agree to the Terms of Service and Privacy Policy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
        }
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else { return }
            // copy the values before the Task
            let userID = credential.user
            let email = credential.email
            let name = credential.fullName.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) }
            Task { try? await Accounts.service.signInWithApple(userID: userID, email: email, name: name) }
        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            errorText = String(localized: "Sign in with Apple didn't work. Try again.")
        }
    }
}

// MARK: - Email
struct EmailAuthView: View {
    @State private var mode: EmailMode
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorText: String?

    init(mode: EmailMode) { _mode = State(initialValue: mode) }

    private var emailIsValid: Bool {
        let parts = email.trimmingCharacters(in: .whitespaces).split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
    }
    private var canSubmit: Bool {
        emailIsValid && password.count >= 8
            && (mode == .signIn || !name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // LocalizedStringKey otherwise the translation doesn't work with the ternary
    private var title: LocalizedStringKey { mode == .signUp ? "Sign Up" : "Sign In" }
    private var sectionTitle: LocalizedStringKey { mode == .signUp ? "Your details" : "Your account" }
    private var submitTitle: LocalizedStringKey { mode == .signUp ? "Create Account" : "Sign In" }
    private var switchTitle: LocalizedStringKey {
        mode == .signUp ? "Already have an account? Sign In" : "New here? Create an account"
    }

    var body: some View {
        Form {
            Section {
                if mode == .signUp {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                }
                TextField("Email", text: $email, prompt: Text(verbatim: "name@example.com"))
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password, prompt: Text("At least 8 characters"))
                    .textContentType(mode == .signUp ? UITextContentType.newPassword : UITextContentType.password)
            } header: {
                Text(sectionTitle)
            } footer: {
                if let errorText { Text(errorText).foregroundStyle(.red) }
            }

            Section {
                Button(action: submit) {
                    Group {
                        if isWorking { ProgressView() } else { Text(submitTitle) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(!canSubmit || isWorking)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Button(switchTitle) {
                    mode = (mode == .signUp) ? .signIn : .signUp
                    errorText = nil
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func submit() {
        isWorking = true
        errorText = nil
        let name = name.trimmingCharacters(in: .whitespaces)
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        let password = password
        let mode = mode
        Task {
            do {
                if mode == .signUp {
                    try await Accounts.service.signUp(name: name, email: email, password: password)
                } else {
                    try await Accounts.service.signIn(email: email, password: password)
                }
            } catch {
                errorText = String(localized: "Something went wrong. Try again.")
            }
            isWorking = false
        }
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
