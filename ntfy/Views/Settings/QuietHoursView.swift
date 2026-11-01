import SwiftUI

struct QuietHoursView: View {
    @EnvironmentObject private var store: Store
    @State private var schedule = QuietHours.load()
    private var weekdays: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
    var body: some View {
        Form {
            Section(footer: Text(String(localized: "Messages stay in history and Notification Center without sound, banners or waking the screen. Topic mute always takes precedence."))) {
                Toggle(String(localized: "Enable quiet hours"), isOn: $schedule.enabled)
            }
            Section(footer: Text(String(localized: "Uses your current time zone. Days select when quiet hours start. Matching start and end times silence the whole selected day."))) {
                DatePicker(String(localized: "Start time"), selection: time(\QuietHours.start), displayedComponents: .hourAndMinute)
                DatePicker(String(localized: "End time"), selection: time(\QuietHours.end), displayedComponents: .hourAndMinute)
                ForEach(weekdays, id: \.self) { day in
                    Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(
                        get: { schedule.days.contains(day) },
                        set: { selected in
                            schedule.days.removeAll { $0 == day }
                            if selected { schedule.days.append(day) }
                        }))
                }
            }
            Section(footer: Text(String(localized: "Allowed messages use their usual topic sound and urgency. iOS notification and Focus settings still apply."))) {
                Toggle(String(localized: "Allow priority 5"), isOn: $schedule.allowUrgent)
                NavigationLink(String(localized: "Allowed topics")) {
                    List {
                        ForEach(store.getSubscriptions() ?? [], id: \.objectID) { subscription in
                            let identity = topicUrl(baseUrl: normalizeBaseUrl(subscription.baseUrl!), topic: subscription.topic!)
                            Toggle(isOn: Binding(get: { schedule.exceptions.contains(identity) }, set: { allowed in
                                schedule.exceptions.removeAll { $0 == identity }
                                if allowed { schedule.exceptions.append(identity) }
                            })) {
                                VStack(alignment: .leading) {
                                    Text(subscription.shortDisplayName())
                                    Text(identity).font(.caption).foregroundColor(.secondary)
                                }.fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.navigationTitle(String(localized: "Allowed topics"))
                }
            }
        }
        .navigationTitle(String(localized: "Quiet hours"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: schedule) { value in
            value.save()
            QuietTopicAlerts.shared.refreshQuietHours()
        }
    }
    private func time(_ key: WritableKeyPath<QuietHours, Int>) -> Binding<Date> {
        Binding(get: {
            let minutes = schedule[keyPath: key]
            return Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1, hour: minutes / 60, minute: minutes % 60))!
        }, set: {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
            schedule[keyPath: key] = parts.hour! * 60 + parts.minute!
        })
    }
}
