import XCTest
import UserNotifications
@testable import ntfy

final class LocalizationTests: XCTestCase {
    /// Raw catalog resources are copied from the same folder compiled into the app and NSE.
    /// Discover languages across all tables so adding a language automatically adds its gate.
    func testEveryCatalogEntryIsTranslatedInEverySupportedLanguage() throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).resourceURL?.appendingPathComponent("Localization"))
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcstrings" }
        XCTAssertEqual(urls.count, 2)
        let catalogs = try urls.map { try JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as! [String: Any] }
        let tables = catalogs.map { $0["strings"] as! [String: [String: Any]] }
        let languages = Set(tables.flatMap { $0.values.flatMap { ($0["localizations"] as? [String: Any])?.keys.map { $0 } ?? [] } })
        XCTAssertTrue(languages.contains("de"))
        let appCopy = tables[try XCTUnwrap(urls.firstIndex { $0.lastPathComponent == "Localizable.xcstrings" })]
        for component in OpenSourceLicenses.components {
            XCTAssertNotNil(appCopy[component.licenseName], "Missing license-name translation: \(component.licenseName)")
        }

        for (table, url) in zip(tables, urls) {
            XCTAssertFalse(table.isEmpty)
            for (key, entry) in table {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for language in languages {
                    let value = try XCTUnwrap(localizations[language], "\(url.lastPathComponent): \(language) missing for \(key)")
                    if let source = localizations["en"] as? [String: Any],
                       let sourceVariations = source["variations"] as? [String: Any],
                       sourceVariations["plural"] != nil {
                        let object = try XCTUnwrap(value as? [String: Any])
                        let variations = try XCTUnwrap(object["variations"] as? [String: Any], "\(language): missing plural variants for \(key)")
                        let plural = try XCTUnwrap(variations["plural"] as? [String: Any])
                        let required: Set<String>
                        switch language {
                        case "pl": required = ["one", "few", "many", "other"]
                        case "es", "it", "fr": required = ["one", "many", "other"]
                        default: required = ["one", "other"]
                        }
                        XCTAssertTrue(required.isSubset(of: Set(plural.keys)), "\(language): missing plural categories for \(key)")
                    }
                    let units = stringUnits(value)
                    XCTAssertFalse(units.isEmpty, "\(language): no values for \(key)")
                    for unit in units {
                        XCTAssertEqual(unit["state"] as? String, "translated", "\(language): \(key)")
                        let text = try XCTUnwrap(unit["value"] as? String)
                        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(language): empty \(key)")
                        // InfoPlist uses symbolic keys. Other tables preserve all format arguments.
                        if url.lastPathComponent == "Localizable.xcstrings" {
                            XCTAssertEqual(placeholders(text), placeholders(key), "\(language): arguments differ for \(key)")
                        }
                    }
                }
            }
        }
    }

    func testLicenseDetailKeepsCanonicalNoticesInGerman() {
        for component in OpenSourceLicenses.components {
            XCTAssertEqual(component.localizedFullText, component.fullText, component.name)
        }
    }

    func testIngressFallbacksStayNeutralAndRenderInCurrentLanguage() throws {
        let store = Store(inMemory: true)
        let sub = store.saveSubscription(baseUrl: "https://localization.invalid", topic: "fallbacks")
        let cases = [
            ("future", "wire", "This message uses an unsupported encoding."),
            ("base64", "not!base64", "This message could not be decoded (invalid base64)."),
            ("base64", "//4A", "This message contains binary data and cannot be displayed as text.")
        ]
        for (index, item) in cases.enumerated() {
            let (encoding, body, source) = item
            let message = Message(id: "fallback-\(index)", time: 1_800_000_000 + Int64(index),
                                  event: "message", topic: "fallbacks", message: body, encoding: encoding)
            store.save(notificationsFromMessages: [message], withSubscription: sub)
            let request = Notification.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@", message.id)
            let row = try XCTUnwrap(store.context.fetch(request).first)
            XCTAssertEqual(row.message, source, "Persist the English source in every ingress locale")
            XCTAssertEqual(row.formatMessage(), Bundle.main.localizedString(forKey: source, value: nil, table: nil))
            // Each full-suite run ingests in its launch language (German or English). Re-read
            // the saved row through both real language bundles, simulating a later app relaunch.
            store.context.refresh(row, mergeChanges: false)
            for language in ["en", "de"] {
                let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
                XCTAssertEqual(row.formatMessage(bundle: bundle), bundle.localizedString(forKey: source, value: nil, table: nil))
                let ordinary = Message(id: "server-\(index)-\(language)", time: 1_800_000_020,
                                       event: "message", topic: "fallbacks", message: source)
                XCTAssertEqual(Message.localizedBody(ordinary.message, contentType: ordinary.contentType, bundle: bundle), source,
                               "A sender's identical sentence must remain verbatim")
                let encodedText = Message(id: "utf8", time: 1, event: "message", topic: "fallbacks",
                                          message: Data(source.utf8).base64EncodedString(), encoding: "base64")
                XCTAssertEqual(Message.localizedBody(encodedText.message, contentType: encodedText.contentType, bundle: bundle), source)
            }
            let roundTrip = try XCTUnwrap(Message.from(userInfo: message.toUserInfo()))
            XCTAssertEqual(roundTrip.message, source)
            XCTAssertEqual(roundTrip.contentType, message.contentType, "NSE userInfo must retain diagnostic identity")
            let json: [String: Any] = ["id": "json", "time": 1, "event": "message", "topic": "fallbacks",
                                       "message": body, "encoding": encoding]
            let decoded = try JSONDecoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(decoded.message, source)
            XCTAssertEqual(decoded.contentType, message.contentType)
            var pushedInfo = message.toUserInfo()
            pushedInfo["message"] = body
            pushedInfo["encoding"] = encoding
            let pushed = try XCTUnwrap(Message.from(userInfo: pushedInfo))
            XCTAssertEqual(pushed.message, source)
            XCTAssertEqual(pushed.contentType, message.contentType)
            let banner = UNMutableNotificationContent()
            banner.modify(message: message, baseUrl: "https://localization.invalid", categoryRegistrationTimeout: 0)
            XCTAssertEqual(banner.body, Bundle.main.localizedString(forKey: source, value: nil, table: nil))
            banner.userInfo = pushedInfo
            banner.body = body
            XCTAssertEqual(UNNotificationContent.encryptionSafeFallback(banner).body,
                           Bundle.main.localizedString(forKey: source, value: nil, table: nil))
        }
        let info: [AnyHashable: Any] = ["id": "unnamed", "time": "1800000010", "event": "message",
                                     "topic": "fallbacks", "attachment_url": "https://attachments.invalid/"]
        let message = try XCTUnwrap(Message.from(userInfo: info))
        store.save(notificationsFromMessages: [message], withSubscription: sub)
        let request = Notification.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", message.id)
        let row = try XCTUnwrap(store.context.fetch(request).first)
        XCTAssertTrue(row.attachmentName?.isEmpty != false, "Do not persist a localized fallback name")
        XCTAssertEqual(row.messageAttachment()?.displayName(), String(localized: "attachment"))
        store.context.refresh(row, mergeChanges: false)
        for language in ["en", "de"] {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            XCTAssertEqual(row.messageAttachment()?.displayName(bundle: bundle), bundle.localizedString(forKey: "attachment", value: nil, table: nil))
        }
        row.attachmentName = "Anhang"
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(row.messageAttachment()?.displayName(bundle: english), "Anhang", "Preserve a sender's actual name")
    }

    func testAddedLanguagesCompileIntoAppAndExtensionWithLocalePlurals() throws {
        let expected: [String: [String]] = [
            "es": ["Tópicos", "1 hora", "2 horas", "5 horas", "12 horas", "22 horas"],
            "it": ["Iscrizioni", "1 ora", "2 ore", "5 ore", "12 ore", "22 ore"],
            "pl": ["Tematy", "1 godzina", "2 godziny", "5 godzin", "12 godzin", "22 godziny"],
            "nl": ["Topics", "1 uur", "2 uur", "5 uur", "12 uur", "22 uur"],
            "fr": ["Sujets", "1 heure", "2 heures", "5 heures", "12 heures", "22 heures"]
        ]
        let regions = ["es": "ES", "it": "IT", "pl": "PL", "nl": "NL", "fr": "FR"]
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil).first { $0.pathExtension == "appex" })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        for language in Bundle.main.localizations where expected[language] != nil {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let values = try XCTUnwrap(expected[language])
            let locale = Locale(identifier: language + "_" + regions[language]!)
            XCTAssertEqual(bundle.localizedString(forKey: "Subscribed topics", value: nil, table: nil), values[0])
            for (index, count) in [1, 2, 5, 12, 22].enumerated() {
                let format = bundle.localizedString(forKey: "%lld hours", value: nil, table: nil)
                XCTAssertEqual(String(format: format, locale: locale, count), values[index + 1], language)
            }
            if language == "pl" {
                let retry = bundle.localizedString(forKey: "The server is limiting this action. Try again in %lld seconds.", value: nil, table: nil)
                for (count, noun) in [(1, "sekundę"), (2, "sekundy"), (5, "sekund"), (12, "sekund"), (22, "sekundy")] {
                    XCTAssertTrue(String(format: retry, locale: locale, count).hasSuffix("\(count) \(noun)."))
                }
            }
            let nse = try XCTUnwrap(extensionBundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for key in ["Notification state synchronized", "Encrypted message", "New message on %@. Open the app to load it."] {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertNotEqual(value, key, language)
                XCTAssertEqual(nse.localizedString(forKey: key, value: nil, table: nil), value, language)
            }
            let permission = bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
            XCTAssertNotEqual(permission, "NSCameraUsageDescription")
            XCTAssertTrue(permission.contains("NTFY me"))
        }
    }

    func testVersion120ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.20.0" })
        XCTAssertEqual(release.bullets.count, 2)
        let expected: [String: [String]] = [
            "en": ["Message images no longer disappear from the app after appearing in a notification.", "The app and its notifications now support Spanish, Italian, Polish, Dutch and French, following your phone's language."],
            "de": ["Bilder in Nachrichten verschwinden nicht mehr aus der App, nachdem sie in einer Benachrichtigung angezeigt wurden.", "Die App und ihre Benachrichtigungen sind jetzt auch auf Spanisch, Italienisch, Polnisch, Niederländisch und Französisch verfügbar und folgen der Sprache deines iPhones."],
            "es": ["Las imágenes de los mensajes ya no desaparecen de la app después de mostrarse en una notificación.", "La app y sus notificaciones ahora están disponibles en español, italiano, polaco, neerlandés y francés, según el idioma de tu teléfono."],
            "it": ["Le immagini dei messaggi non scompaiono più dall'app dopo essere state mostrate in una notifica.", "L'app e le sue notifiche sono ora disponibili in spagnolo, italiano, polacco, olandese e francese, in base alla lingua del tuo telefono."],
            "pl": ["Obrazy w wiadomościach nie znikają już z aplikacji po wyświetleniu w powiadomieniu.", "Aplikacja i jej powiadomienia są teraz dostępne po hiszpańsku, włosku, polsku, niderlandzku i francusku, zgodnie z językiem telefonu."],
            "nl": ["Afbeeldingen in berichten verdwijnen niet meer uit de app nadat ze in een melding zijn getoond.", "De app en de meldingen die de app zelf maakt, zijn nu beschikbaar in het Spaans, Italiaans, Pools, Nederlands en Frans en volgen de taal van je telefoon."],
            "fr": ["Les images des messages ne disparaissent plus de l’app après leur affichage dans une notification.", "L’app et ses notifications sont maintenant disponibles en espagnol, italien, polonais, néerlandais et français, selon la langue de votre téléphone."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    func testVersion121ReleaseNotesResolveInEveryBundledLanguage() throws {
        let release = try XCTUnwrap(ReleaseNotes.shipped.first { $0.version == "1.21.0" })
        XCTAssertEqual(release.bullets.count, 4)
        let expected: [String: [String]] = [
            "en": ["Send messages with an optional title, priority, tags and an attachment from a topic screen.", "Share links, text, photos and files to your subscribed topics from other apps.", "Messages that already alerted you no longer alert again when received a second time.", "See when a server refuses sign-in, with a button in the topic screen to check the server user."],
            "de": ["Sende Nachrichten direkt aus einem Thema, auf Wunsch mit Titel, Priorität, Tags und einem Anhang.", "Sende Links, Text, Fotos und Dateien aus anderen Apps an abonnierte Themen.", "Nachrichten, die dich bereits benachrichtigt haben, lösen beim erneuten Empfang keine weitere Benachrichtigung aus.", "Du siehst jetzt, wenn ein Server die Anmeldung ablehnt. Im Thema kannst du über eine Schaltfläche den Server-Benutzer prüfen."],
            "es": ["Envía mensajes desde la pantalla de un tópico, con título, prioridad, etiquetas y un archivo adjunto opcionales.", "Comparte enlaces, texto, fotos y archivos desde otras apps con los tópicos a los que te has suscrito.", "Los mensajes que ya generaron una alerta no vuelven a hacerlo al recibirse de nuevo.", "Ahora se indica si un servidor rechaza el inicio de sesión. Revisa el usuario del servidor con el botón de la pantalla del tópico."],
            "it": ["Invia messaggi dalla schermata di un argomento, con titolo, priorità, tag e un allegato facoltativi.", "Condividi link, testo, foto e file da altre app con gli argomenti a cui sei iscritto.", "I messaggi che hanno già generato un avviso non ne generano un altro se vengono ricevuti di nuovo.", "Ora puoi vedere quando un server rifiuta l'accesso e verificare l'utente del server con il pulsante nella schermata dell'argomento."],
            "pl": ["Wysyłaj wiadomości z ekranu tematu, opcjonalnie dodając tytuł, priorytet, tagi i jeden załącznik.", "Udostępniaj linki, tekst, zdjęcia i pliki z innych aplikacji w subskrybowanych tematach.", "Wiadomości, które już wywołały alert, nie wywołują go ponownie po kolejnym odebraniu.", "Aplikacja informuje teraz, gdy serwer odrzuci logowanie. Przycisk na ekranie tematu pozwala sprawdzić konto na serwerze."],
            "nl": ["Verstuur berichten vanuit een onderwerp, eventueel met een titel, prioriteit, tags en één bijlage.", "Deel links, tekst, foto’s en bestanden vanuit andere apps met de onderwerpen waarop je bent geabonneerd.", "Berichten waarvoor je al een melding hebt gekregen, geven geen nieuwe melding als ze opnieuw binnenkomen.", "Je ziet nu wanneer een server het inloggen weigert. Met de knop in het onderwerp kun je de gebruiker voor die server controleren."],
            "fr": ["Envoyez des messages depuis un sujet, avec un titre, une priorité, des tags et une pièce jointe si vous le souhaitez.", "Partagez des liens, du texte, des photos et des fichiers depuis d’autres apps vers les sujets auxquels vous êtes abonné.", "Les messages qui vous ont déjà alerté ne déclenchent plus d’alerte lorsqu’ils sont reçus une deuxième fois.", "L’app indique désormais quand un serveur refuse la connexion. Un bouton dans le sujet vous permet de vérifier votre utilisateur pour ce serveur."]
        ]
        XCTAssertEqual(Set(Bundle.main.localizations.filter { $0 != "Base" }), Set(expected.keys))
        for (language, bullets) in expected {
            let bundle = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            for (index, key) in expected["en"]!.enumerated() {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: nil, table: nil), bullets[index], language)
            }
        }
    }

    private func stringUnits(_ node: Any) -> [[String: Any]] {
        guard let object = node as? [String: Any] else { return [] }
        if let unit = object["stringUnit"] as? [String: Any] { return [unit] }
        return object.values.flatMap(stringUnits)
    }

    private func placeholders(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:lld|ld|d|@)"#
        let expression = try! NSRegularExpression(pattern: pattern)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            let token = String(text[Range($0.range, in: text)!])
            return token.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
        }.sorted()
    }

    func testGermanPluralFormattingAndSharedNotificationCopy() throws {
        let bundle = try XCTUnwrap(Bundle.main.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        let locale = Locale(identifier: "de_DE")
        XCTAssertNil(DeliveryHealthCopy.retryIntervalLocale(language: "en", locale: locale))
        XCTAssertEqual(DeliveryHealthCopy.retryIntervalLocale(language: "pl", locale: Locale(identifier: "pl_PL")), Locale(identifier: "pl_PL"))
        func value(_ key: String, _ count: Int) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: locale, count)
        }
        XCTAssertEqual(value("%lld hours", 1), "1 Stunde")
        XCTAssertEqual(value("%lld hours", 2), "2 Stunden")
        XCTAssertEqual(value("%lld notifications", 1), "1 Benachrichtigung")
        XCTAssertEqual(value("%lld notifications", 0), "0 Benachrichtigungen")
        XCTAssertEqual(value("%lld notifications", 23), "23 Benachrichtigungen")
        XCTAssertEqual(bundle.localizedString(forKey: "Notification state synchronized", value: nil, table: nil), "Benachrichtigungsstatus synchronisiert")
        let canonicalMIT = OpenSourceLicenses.components[0].notice
        XCTAssertTrue(canonicalMIT.contains("Permission is hereby granted"))
        let plugIns = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let extensionURL = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil).first { $0.pathExtension == "appex" })
        let extensionBundle = try XCTUnwrap(Bundle(url: extensionURL))
        let extensionGerman = try XCTUnwrap(extensionBundle.path(forResource: "de", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(extensionGerman.localizedString(forKey: "Notification state synchronized", value: nil, table: nil), "Benachrichtigungsstatus synchronisiert")
        XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"), "NTFY me nutzt die Kamera nur, um QR-Codes für Themen zu scannen, die du abonnieren möchtest.")
        // Review eligibility uses this prefix in every bundled language, including old messages.
        // A future translator can fix an inconsistent prefix entirely in the catalog.
        for language in Bundle.main.localizations where language != "Base" {
            let localized = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)))
            let prefix = localized.localizedString(forKey: Store.testMessagePrefix, value: nil, table: nil)
            for key in [
                "This is a test notification from NTFY me. Your topic is ready.",
                "This is a test notification from NTFY me. It has a priority of %lld. If you send another one, it may look different."
            ] {
                XCTAssertTrue(localized.localizedString(forKey: key, value: nil, table: nil).hasPrefix(prefix),
                              "\(language): test-message copy must retain its translated prefix")
            }
        }
        XCTAssertTrue(Store.isOwnTestMessage("Dies ist eine Testnachricht von NTFY me. Dein Thema ist bereit."))
        XCTAssertTrue(Store.isOwnTestMessage("This is a test notification from NTFY me. Your topic is ready."))
        XCTAssertFalse(Store.isOwnTestMessage("A real server message"))
        let store = Store(inMemory: true)
        let subscription = store.saveSubscription(baseUrl: "https://localization.invalid", topic: "locale-change")
        let messages = [
            Message(id: "de-test", time: 1_800_000_000, event: "message", topic: "locale-change", message: "Dies ist eine Testnachricht von NTFY me. Dein Thema ist bereit."),
            Message(id: "en-test", time: 1_800_000_001, event: "message", topic: "locale-change", message: "This is a test notification from NTFY me. Your topic is ready."),
            Message(id: "real", time: 1_800_000_002, event: "message", topic: "locale-change", message: "Backup complete")
        ]
        store.save(notificationsFromMessages: messages, withSubscription: subscription)
        messages.forEach { store.recordPresentation(message: $0, baseUrl: "https://localization.invalid") }
        XCTAssertEqual(store.presentedDeliveries().count, 1, "English and German test messages remain excluded across language changes")
        let locked = Notification(context: store.context)
        locked.encryption = NotificationEncryption.locked.rawValue
        locked.message = "Dies ist ein gespeicherter Platzhalter in einer anderen Sprache"
        XCTAssertEqual(locked.formatMessage(), TopicEncryption.lockedPlaceholder)
        XCTAssertEqual(locked.formatMessage(bundle: bundle), bundle.localizedString(forKey: "Encrypted message", value: nil, table: nil))
        locked.encryption = NotificationEncryption.none.rawValue
        XCTAssertEqual(locked.formatMessage(), locked.message, "readable server content must stay verbatim")
    }
}
