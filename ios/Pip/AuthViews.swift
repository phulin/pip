import SwiftUI

struct AuthView: View {
    @Environment(PipStore.self) var store
    @State private var registering = true
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var recovery = false
    @State private var resetCode = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 8) { Image(systemName: "leaf.fill"); Text("pip").font(.system(size: 32, weight: .bold, design: .rounded)) }.foregroundStyle(PipTheme.green).padding(.top, 30)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Little moments.\nA little more calm.").font(.system(size: 38, weight: .semibold, design: .serif))
                        Text("Feeds, pumping, and everyone who cares.\nAll together in one small place.").foregroundStyle(.secondary).lineSpacing(4)
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(store.sessionExpired ? "Welcome back" : registering ? "Make room for your family" : "Welcome back").font(.title3.bold())
                            if registering { TextField("Your name", text: $name).textContentType(.name).textFieldStyle(.roundedBorder) }
                            TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                            SecureField("Password · 10+ characters", text: $password).textContentType(registering ? .newPassword : .password).textFieldStyle(.roundedBorder)
                            if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                            PrimaryButton(title: registering ? "Create account" : "Sign in", busy: busy) {
                                busy = true; failure = nil
                                Task {
                                    do { try await store.authenticate(email: email, password: password, name: name, registering: registering) }
                                    catch { failure = error.localizedDescription }
                                    busy = false
                                }
                            }.disabled(email.isEmpty || password.count < 10 || (registering && name.trimmingCharacters(in: .whitespaces).isEmpty))
                            Button(registering ? "Already have an account? Sign in" : "New here? Create an account") { registering.toggle(); failure = nil }.font(.footnote).frame(maxWidth: .infinity)
                            if !registering { Button("Forgot password?") { recovery = true }.font(.footnote).frame(maxWidth: .infinity) }
                        }
                    }
                    Label("Made for the middle of the night.", systemImage: "moon.stars").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }.padding(24)
            }.background(PipTheme.background)
                .onAppear { if store.sessionExpired { registering = false; email = store.user?.email ?? "" } }
                .onReceive(NotificationCenter.default.publisher(for: .init("pip.reset"))) { notification in resetCode = notification.object as? String ?? ""; recovery = true }
                .sheet(isPresented: $recovery) { RecoveryView(code: resetCode) }
        }
    }
}
struct RecoveryView: View {
    @Environment(\.dismiss) var dismiss
    @State var code: String
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Request a reset code") {
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    Button("Send reset email") { perform {
                        let _: OK = try await API.request("auth/forgot-password", method: "POST", body: API.data(["email": email.lowercased().trimmingCharacters(in: .whitespaces)]))
                        message = "If an account exists, a reset email is on its way."
                    } }.disabled(email.isEmpty || busy)
                }
                Section("Set a new password") {
                    TextField("Code from email", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("New password · 10+ characters", text: $password).textContentType(.newPassword)
                    Button("Reset password") { perform {
                        let _: OK = try await API.request("auth/reset-password", method: "POST", body: API.data(["code": code.trimmingCharacters(in: .whitespacesAndNewlines), "password": password]))
                        message = "Password updated. Close this sheet and sign in."
                    } }.disabled(code.isEmpty || password.count < 10 || busy)
                }
                if let message { Section { Text(message) } }
                if busy { ProgressView() }
            }.navigationTitle("Password help").toolbar { Button("Done") { dismiss() } }
        }
    }
    func perform(_ action: @escaping () async throws -> Void) { busy = true; Task { do { try await action() } catch { message = error.localizedDescription }; busy = false } }
}
struct FamilySetupView: View {
    @Environment(PipStore.self) var store
    @State private var joining = false
    @State private var familyName = ""
    @State private var babyName = ""
    @State private var birthday = Date()
    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "person.2.circle.fill").font(.system(size: 60)).foregroundStyle(PipTheme.green).padding(.top, 35)
                    Text("A small circle.\nA lot of love.").font(.system(size: 36, weight: .semibold, design: .serif))
                    Text("Create your family, or join the people already caring for your little one.").foregroundStyle(.secondary)
                    Picker("Setup", selection: $joining) { Text("Create a family").tag(false); Text("Join a family").tag(true) }.pickerStyle(.segmented)
                    Card { VStack(spacing: 18) {
                        if joining {
                            Text("Paste the invitation code from your email. Sign in with the address that received the invitation.").font(.subheadline).foregroundStyle(.secondary)
                            TextField("Invitation code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        } else {
                            TextField("Family name", text: $familyName).textFieldStyle(.roundedBorder)
                            TextField("Baby’s name", text: $babyName).textFieldStyle(.roundedBorder)
                            DatePicker("Birthday", selection: $birthday, in: ...Date(), displayedComponents: .date)
                        }
                        if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                        PrimaryButton(title: joining ? "Join your family" : "Let’s begin", busy: busy) {
                            busy = true; failure = nil
                            Task {
                                do { if joining { try await store.join(code: code) } else { try await store.createFamily(name: familyName, babyName: babyName, birthday: birthday) } }
                                catch { failure = error.localizedDescription }; busy = false
                            }
                        }.disabled(joining ? code.isEmpty : familyName.isEmpty || babyName.isEmpty)
                    } }
                }.padding(24)
            }.background(PipTheme.background).toolbar { Button("Sign out") { Task { await store.signOut() } } }
                .onAppear { if !store.inviteCode.isEmpty { code = store.inviteCode; joining = true } }
                .onChange(of: store.inviteCode) { _, value in code = value; joining = true }
        }
    }
}
