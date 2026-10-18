import SwiftUI

struct RetentionSettingsView: View {
    @StateObject private var selection: RetentionSelection

    init(store: Store) { _selection = StateObject(wrappedValue: RetentionSelection(store: store)) }

    var body: some View {
        Section(header: Text(NotificationHistoryStrings.section), footer: Text(NotificationHistoryStrings.explanation)) {
            Picker(NotificationHistoryStrings.title, selection: Binding(get: { selection.policy }, set: selection.select)) {
                ForEach(NotificationRetention.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
        }
        .alert(item: $selection.prompt) { prompt in
            if let policy = prompt.policy {
                return Alert(title: Text(NotificationHistoryStrings.confirmation(prompt.count, policy)),
                    message: Text(NotificationHistoryStrings.confirmExplanation),
                    primaryButton: .destructive(Text(NotificationHistoryStrings.delete)) { selection.confirm(policy) },
                    secondaryButton: .cancel(Text(NotificationHistoryStrings.cancel)) { selection.cancel() })
            }
            return Alert(title: Text(NotificationHistoryStrings.saveError), message: Text(NotificationHistoryStrings.saveErrorExplanation))
        }
    }
}
