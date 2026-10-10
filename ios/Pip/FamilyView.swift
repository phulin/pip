import SwiftUI
import UniformTypeIdentifiers

struct CSVExport: Transferable {
    var text: String
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { value in Data(value.text.utf8) }.suggestedFileName("pip-activities.csv")
    }
}

struct FamilyView: View {
    @Environment(PipStore.self) var store
    @State private var members: [Member] = []
    @State private var email = ""
    @State private var invitationStatus: String?
    @State private var inviting = false
    @State private var newBaby = false
    @State private var account = false
    @State private var remove: Member?
    @State private var signOut = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "leaf.fill").font(.largeTitle).foregroundStyle(PipTheme.green)
                        Text(store.family?.name ?? "Your family").font(.system(size: 30, weight: .semibold, design: .serif))
                        Text("A little village, always in the loop.").foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }.listRowBackground(Color.clear)
                Section("Little ones") {
                    ForEach(store.babies) { baby in
                        Button { store.selectedBabyId = baby.id; store.persist() } label: {
                            HStack { Label(baby.name, systemImage: "face.smiling").foregroundStyle(.primary); Spacer(); if store.baby?.id == baby.id { Image(systemName: "checkmark").foregroundStyle(PipTheme.green) } }
                        }
                    }
                    Button("Add a baby", systemImage: "plus") { newBaby = true }
                }
                Section("Your village") {
                    ForEach(members) { member in
                        HStack { VStack(alignment: .leading, spacing: 4) { Text(member.name); Text(member.role == "owner" ? "Family owner" : "Caregiver").font(.caption).foregroundStyle(.secondary) }; Spacer(); if member.id == store.user?.id { Text("You").font(.caption).foregroundStyle(.secondary) } }
                            .swipeActions { if member.role != "owner" && (store.family?.role == "owner" || member.id == store.user?.id) { Button("Remove", role: .destructive) { remove = member } } }
                    }
                }
                if store.family?.role == "owner" {
                    Section { TextField("Caregiver’s email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { inviting = true; invitationStatus = nil; Task { do { try await store.invite(email: email); invitationStatus = "Invitation sent. It’s valid for 7 days."; email = "" } catch { invitationStatus = error.localizedDescription }; inviting = false } } label: { HStack { Text("Send invitation"); Spacer(); if inviting { ProgressView() } else { Image(systemName: "paperplane") } } }.disabled(email.isEmpty || inviting)
                        if let invitationStatus { Text(invitationStatus).font(.footnote).foregroundStyle(.secondary) }
                    } header: { Text("Invite someone you trust") } footer: { Text("Caregivers can see and edit your family’s feeds and pumping sessions.") }
                }
                Section {
                    Button("Account & privacy", systemImage: "person.crop.circle") { account = true }
                    ShareLink(item: CSVExport(text: exportCSV()), preview: SharePreview("Pip activity export")) { Label("Export activities (CSV)", systemImage: "square.and.arrow.up") }
                    Button("Sign out", role: .destructive) { signOut = true }.disabled(!store.pending.isEmpty || store.syncing)
                    if !store.pending.isEmpty { Text("Sync or resolve pending changes before signing out.").font(.footnote).foregroundStyle(.secondary) }
                }
                Section { Text("Pip keeps a protected copy on this iPhone so tracking works offline. Your family’s data syncs to Cloudflare when you reconnect.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Family")
                .task { await reloadMembers() }
                .refreshable { await store.refreshProfile(); await reloadMembers() }
                .sheet(isPresented: $newBaby) { AddBabyView() }
                .sheet(isPresented: $account) { AccountView() }
                .confirmationDialog("Sign out of Pip?", isPresented: $signOut, titleVisibility: .visible) { Button("Sign out", role: .destructive) { Task { await store.signOut() } } }
                .confirmationDialog("Remove this caregiver from the family?", isPresented: Binding(get: { remove != nil }, set: { if !$0 { remove = nil } }), titleVisibility: .visible) { Button("Remove caregiver", role: .destructive) { if let remove { Task { do { try await store.removeMember(remove.id); await reloadMembers() } catch { store.error = error.localizedDescription } } }; remove = nil } }
        }
    }
    func reloadMembers() async { do { members = try await store.members() } catch { store.error = error.localizedDescription } }
    func exportCSV() -> String {
        func escape(_ value: String) -> String {
            let safe = ["=", "+", "-", "@", "\t", "\r"].contains(where: { value.hasPrefix($0) }) ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return "Baby,Activity,Started,Ended,Left seconds,Right seconds,Volume mL,Milk,Notes\n" + store.activities.filter { !$0.deleted }.sorted { $0.startedAt < $1.startedAt }.map { a in
            [store.babies.first { $0.id == a.babyId }?.name ?? "", a.kind.title, a.startDate.ISO8601Format(), a.endedAt.map { Date(timeIntervalSince1970: $0 / 1000).ISO8601Format() } ?? "", String(Int(a.leftSeconds)), String(Int(a.rightSeconds)), String(a.volumeML), a.milk, a.notes].map(escape).joined(separator: ",")
        }.joined(separator: "\n")
    }
}
struct AddBabyView: View {
    @Environment(PipStore.self) var store
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var birthday = Date()
    @State private var busy = false
    @State private var failure: String?
    var body: some View { NavigationStack { Form {
        TextField("Baby’s name", text: $name)
        DatePicker("Birthday", selection: $birthday, in: ...Date(), displayedComponents: .date)
        if let failure { Text(failure).foregroundStyle(.red) }
    }.navigationTitle("A new little one").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { Button("Add") { busy = true; Task { do { try await store.addBaby(name: name, birthday: birthday); dismiss() } catch { failure = error.localizedDescription }; busy = false } }.disabled(name.isEmpty || busy) }
    } } }
}
struct AccountView: View {
    @Environment(PipStore.self) var store
    @Environment(\.dismiss) var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var deletionPassword = ""
    @State private var confirm = false
    @State private var busy = false
    @State private var message: String?
    var body: some View {
        NavigationStack { Form {
            Section { LabeledContent("Name", value: store.user?.name ?? ""); LabeledContent("Email", value: store.user?.email ?? "") }
            Section("Change password") {
                SecureField("Current password", text: $current).textContentType(.password)
                SecureField("New password · 10+ characters", text: $new).textContentType(.newPassword)
                Button("Update password") { perform { try await store.changePassword(current: current, new: new); current = ""; new = ""; message = "Password changed. Other devices are now signed out." } }.disabled(current.isEmpty || new.count < 10 || busy)
            }
            Section {
                Text(store.family?.role == "owner" ? "Deleting your account also permanently deletes your family, baby profiles, and activity history for all caregivers." : "Deleting your account removes your login and family access. Shared activity history stays with your family.").font(.footnote).foregroundStyle(.secondary)
                SecureField("Password to confirm deletion", text: $deletionPassword)
                Button("Delete account", role: .destructive) { confirm = true }.disabled(deletionPassword.isEmpty || busy)
            } header: { Text("Delete account") }
            if let message { Section { Text(message) } }
            if busy { ProgressView() }
        }.navigationTitle("Account").toolbar { Button("Done") { dismiss() } }
            .confirmationDialog("Permanently delete your account? This cannot be undone.", isPresented: $confirm, titleVisibility: .visible) { Button("Delete permanently", role: .destructive) { perform { try await store.deleteAccount(password: deletionPassword); dismiss() } } }
        }
    }
    func perform(_ action: @escaping () async throws -> Void) { busy = true; Task { do { try await action() } catch { message = error.localizedDescription }; busy = false } }
}
