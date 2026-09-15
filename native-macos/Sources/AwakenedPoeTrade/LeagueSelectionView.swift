import SwiftUI

struct LeagueSelectionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var customLeague: String

    init(model: AppModel) {
        self.model = model
        let saved = UserDefaults.standard.string(forKey: "customLeague") ?? ""
        _customLeague = State(initialValue: model.leagues.contains(model.effectiveLeague) ? saved : model.effectiveLeague)
    }

    private var trimmedCustomLeague: String { customLeague.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Choose league").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Text("Available leagues").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if model.isLoadingLeagues { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await model.refreshLeagues() } }.disabled(model.isLoadingLeagues)
            }
            if let error = model.leagueError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.leagues, id: \.self) { league in
                        Button {
                            model.league = league
                            dismiss()
                        } label: {
                            HStack {
                                Text(league).multilineTextAlignment(.leading)
                                Spacer()
                                if model.effectiveLeague == league { Image(systemName: "checkmark") }
                            }.padding(10).frame(maxWidth: .infinity).contentShape(Rectangle())
                                .background(model.effectiveLeague == league ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                        }.buttonStyle(.plain).accessibilityLabel("Select " + league)
                    }
                }
            }.frame(minHeight: 80, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Private or custom league").font(.subheadline)
                TextField("My League (PL12345)", text: $customLeague)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Private or custom league name")
                    .onSubmit { applyCustomLeague() }
                Text("Paste the full league name shown on the trade site, including the (PL12345) suffix for a private league. You can also enter a public league if the list is unavailable.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Private-league searches use the account signed in through this app’s Trade Session.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Selected: " + model.effectiveLeague).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Use League") { applyCustomLeague() }.disabled(trimmedCustomLeague.isEmpty)
                }
            }
        }.padding(20).frame(width: 440, height: 530)
            .task { await model.refreshLeagues() }
    }

    private func applyCustomLeague() {
        guard !trimmedCustomLeague.isEmpty else { return }
        UserDefaults.standard.set(trimmedCustomLeague, forKey: "customLeague")
        model.league = trimmedCustomLeague
        dismiss()
    }
}
