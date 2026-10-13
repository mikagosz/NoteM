import Foundation

/// What the Help window says: each section is a picture of the app with numbered points and the same
/// numbers in the steps next to it. Polish and English side by side, like the rest of NoteM (`Loc.t`).
nonisolated enum HelpContent {
    /// One text in both languages.
    struct Text: Hashable {
        let pl: String
        let en: String
        var current: String { Loc.t(pl, en) }
    }

    /// Which picture stands next to the section; drawn by the app itself in HelpWindow.swift.
    enum Picture { case main, note, palette, quick, tasks, filing, smartFolders, sync, obsidian }

    struct Section {
        let title: Text
        let lead: Text
        /// Numbered like the points on the picture: the first step is point 1.
        let steps: [Text]
        /// The longer description, folded under "More".
        let more: Text?
        let picture: Picture
    }

    struct Card {
        let symbol: String
        let title: Text
        let text: Text
    }

    private static func t(_ pl: String, _ en: String) -> Text { Text(pl: pl, en: en) }

    static let windowTitle = t("NoteM — Pomoc", "NoteM — Help")
    static let title = t("Pierwsze kroki z NoteM", "Getting started with NoteM")
    static let intro = t("Notatki jako zwykłe pliki na Twoim dysku: jedna notatka to jeden folder z tekstem w Markdownie. Bez bazy danych i bez konta.",
                         "Notes as ordinary files on your disk: one note is one folder with its text in Markdown. No database and no account.")

    static let sections: [Section] = [
        Section(title: t("Okno NoteM", "The NoteM window"),
                lead: t("Po lewej wszystkie notatki i to, jak są poukładane. Po prawej to, co wybrałeś.",
                        "All your notes and how they are arranged on the left, whatever you picked on the right."),
                steps: [t("Nowa notatka — przycisk nad listą.", "New note — the button above the list."),
                        t("Start, Zadania, Załączniki i Kosz.", "Start, Tasks, Attachments and Trash."),
                        t("Foldery i tagi — kliknij, żeby zawęzić listę notatek.", "Folders and tags — click one to narrow the list of notes."),
                        t("Start: ostatnie notatki i wyszukiwanie, także po znaczeniu.", "Start: your latest notes and search, by meaning too.")],
                more: t("Folder notatki to zwykły folder w ~/Documents/NoteM (albo w iCloud Drive), widoczny w Finderze. Kolor okładki folderu zmienisz prawym przyciskiem na folderze. Przypięte notatki zostają na górze listy. Układ strony Start — sekcje, kolumny albo stosy — wybierzesz w Ustawieniach → Wygląd.",
                       "A note's folder is an ordinary folder in ~/Documents/NoteM (or in iCloud Drive), visible in Finder. Right-click a folder to change its cover colour. Pinned notes stay at the top of the list. The Start page layout — sections, columns or stacks — is chosen in Settings → Appearance."),
                picture: .main),
        Section(title: t("Pisanie notatki", "Writing a note"),
                lead: t("Formatujesz jak w edytorze tekstu, a pod spodem zostaje czysty Markdown. Zapis jest automatyczny.",
                        "Format as in a word processor, with plain Markdown underneath. Saving is automatic."),
                steps: [t("Pasek formatowania: nagłówki, pogrubienie, listy, lista zadań, tabela i kolory.",
                          "The format bar: headings, bold, lists, a checklist, a table and colours."),
                        t("Tagi notatki — podpowiadają się te, których już używasz.", "The note's tags — the ones you already use are suggested."),
                        t("Rysunek, dyktowanie, eksport i tło notatki: czarne albo białe.",
                          "Drawing, dictation, export and the note background: black or white.")],
                more: t("Notatka zapisuje się sekundę po tym, jak przestaniesz pisać, a poprzednia wersja trafia do historii (do 20 wersji). [[Tytuł innej notatki]] tworzy łącze, a pod edytorem widać, co linkuje do tej notatki. Dyktowanie działa na tym Macu, bez wysyłania dźwięku. Wklej i dopasuj styl (⌥⇧⌘V) zostawia pogrubienia, listy i łącza, a zdejmuje obce czcionki i kolory.",
                       "A note saves a second after you stop typing, and the previous version goes to its history (up to 20 versions). [[Another note's title]] makes a link, and under the editor you see what links to this note. Dictation runs on this Mac, no audio is sent anywhere. Paste and Match Style (⌥⇧⌘V) keeps bold, lists and links and drops the source's fonts and colours."),
                picture: .note),
        Section(title: t("Paleta poleceń", "Command palette"),
                lead: t("⌘K w dowolnym miejscu okna: przejdź do notatki albo wykonaj polecenie bez szukania w menu.",
                        "⌘K anywhere in the window: jump to a note or run a command without hunting through menus."),
                steps: [t("Wpisz kawałek tytułu albo nazwy polecenia — nie musi być dokładny.",
                          "Type part of a title or a command — it does not have to be exact."),
                        t("Polecenia: nowa notatka, przejścia, przypięcie i eksport otwartej notatki.",
                          "Commands: new note, going places, pinning and exporting the open note."),
                        t("Notatki — ↑↓ wybiera, Return otwiera.", "Notes — ↑↓ to choose, Return to open.")],
                more: nil,
                picture: .palette),
        Section(title: t("Szybka notatka", "Quick capture"),
                lead: t("Pomysł z dowolnego programu, bez przełączania się do NoteM.",
                        "An idea from any app, without switching to NoteM."),
                steps: [t("⌥⌘N albo róg ekranu otwiera pływający panel.", "⌥⌘N or a corner of the screen opens a floating panel."),
                        t("Piszesz jak w zwykłej notatce — z formatowaniem i obrazkami.", "Write as in any note — with formatting and images."),
                        t("Zapisz tworzy notatkę; zwykłe reguły katalogowania też działają.",
                          "Save makes it a note; the usual filing rules apply as well.")],
                more: t("Niezapisany tekst w panelu jest brudnopisem: przeżywa zamknięcie programu i restart, a wraca w tym samym panelu. Czerwony przycisk zamknięcia wyrzuca go świadomie. Szybką notatkę włączysz i rogi ekranu wybierzesz w Ustawieniach → Quick Capture. Róg ekranu potrzebuje zgody na Dostępność; skrót ⌥⌘N działa bez niej.",
                       "Unsaved text in the panel is a draft: it survives quitting and restarting and comes back in the same panel. The red close button throws it away on purpose. Quick capture is turned on and its screen corners chosen in Settings → Quick Capture. A screen corner needs the Accessibility permission; the ⌥⌘N shortcut works without it."),
                picture: .quick),
        Section(title: t("Zadania", "Tasks"),
                lead: t("Notatkę oznaczoną jako lista zadań widać w Zadaniach, a licznik mówi, ile jeszcze otwartych.",
                        "A note marked as a task list shows up in Tasks, and the badge says how many are still open."),
                steps: [t("Kółko odhacza całą listę jako zrobioną.", "The circle ticks the whole list off as done."),
                        t("Kliknięcie otwiera notatkę z zadaniami.", "A click opens the note with its tasks."),
                        t("Zrobioną listę usuniesz do Kosza jednym kliknięciem.", "A done list goes to the Trash with one click.")],
                more: t("Notatkę zrobisz listą zadań przyciskiem „Oznacz jako zadania” u góry notatki albo w szybkiej notatce. W treści ⌘⇧L wstawia pole do odhaczania.",
                       "Make a note a task list with “Mark as tasks” at the top of the note, or in quick capture. In the text, ⌘⇧L inserts a checkbox."),
                picture: .tasks),
        Section(title: t("Katalogowanie", "Filing"),
                lead: t("Reguły same odkładają nowe notatki do folderów — „faktura” trafia do Finanse.",
                        "Rules file new notes into folders by themselves — “invoice” goes to Finance."),
                steps: [t("Słowo, którego NoteM szuka w notatce.", "The word NoteM looks for in the note."),
                        t("Folder docelowy; {date} wstawia datę.", "The target folder; {date} puts in the date."),
                        t("Wygrywa pierwsza pasująca reguła — przeciągnij, żeby zmienić kolejność.",
                          "The first matching rule wins — drag to change the order.")],
                more: t("Przenoszone są tylko notatki jeszcze niezakatalogowane, więc edycja notatki, która już ma folder, nie przerzuca jej gdzie indziej.",
                       "Only notes that are not filed yet are moved, so editing a note that already has a folder never makes it hop elsewhere."),
                picture: .filing),
        Section(title: t("Inteligentne foldery", "Smart folders"),
                lead: t("Zapisane wyszukiwania: folder, który sam zbiera notatki spełniające warunki.",
                        "Saved searches: a folder that gathers the notes meeting its conditions by itself."),
                steps: [t("Wbudowane: Dzisiejsze i Przypięte.", "Built in: Today and Pinned."),
                        t("Własne — nazwa, ikona i warunki, np. tag albo tekst w notatce.",
                          "Your own — a name, an icon and conditions, such as a tag or text in the note.")],
                more: nil,
                picture: .smartFolders),
        Section(title: t("Synchronizacja", "Sync"),
                lead: t("Notatki w iCloud Drive są na każdym Twoim Macu. Zmiany z drugiego komputera pojawiają się po kilku sekundach.",
                        "Notes in iCloud Drive are on every Mac of yours. Changes from the other computer show up within seconds."),
                steps: [t("Włącz, żeby trzymać notatki w iCloud Drive.", "Turn it on to keep the notes in iCloud Drive."),
                        t("Gdzie leżą notatki teraz.", "Where the notes are now.")],
                more: t("Gdy ta sama notatka zmieniła się na dwóch Makach bez sieci, NoteM pokazuje obie wersje obok siebie i pyta, którą zostawić — nic nie znika po cichu. Program nie wczyta zmian z chmury, dopóki w edytorze jest coś niezapisanego.",
                       "When the same note changed on two Macs while offline, NoteM shows both versions side by side and asks which to keep — nothing disappears quietly. Changes from the cloud are not loaded while the editor still holds something unsaved."),
                picture: .sync),
        Section(title: t("Obsidian", "Obsidian"),
                lead: t("NoteM może kopiować notatki do sejfu Obsidiana jako zwykłe pliki .md — z tagami, załącznikami i łączami.",
                        "NoteM can copy your notes into an Obsidian vault as ordinary .md files — with tags, attachments and links."),
                steps: [t("Połącz NoteM z Obsidianem — bez tego przycisk Obsidiana się nie pokazuje.",
                          "Connect NoteM to Obsidian — without it the Obsidian button does not show."),
                        t("Wysyłaj automatycznie po każdym zapisie.", "Send automatically after every save."),
                        t("Folder w sejfie, do którego trafiają kopie.", "The vault folder the copies go to.")],
                more: t("Kierunek jest jeden: NoteM nadpisuje tylko pliki, które sam utworzył, i nigdy nie rusza notatek pisanych w Obsidianie. Kryształ przy notatce jest fioletowy, dopóki kopii nie ma w sejfie, a zielony, gdy już jest.",
                       "It goes one way only: NoteM overwrites only files it created itself and never touches notes written in Obsidian. The crystal next to a note is purple until the copy is in the vault, and green once it is."),
                picture: .obsidian),
    ]

    static let goodToKnow = t("Dobrze wiedzieć", "Good to know")
    static let cards: [Card] = [
        Card(symbol: "folder", title: t("Twoje pliki", "Your files"),
             text: t("Każda notatka to folder z note.md. Usuniesz program — notatki zostają i otworzysz je czymkolwiek.",
                     "Every note is a folder with note.md. Delete the app and the notes stay, readable by anything.")),
        Card(symbol: "trash", title: t("Kosz i historia", "Trash and history"),
             text: t("Usunięta notatka czeka w Koszu (domyślnie 30 dni) i wraca do swojego folderu. Każda ma do 20 poprzednich wersji.",
                     "A deleted note waits in the Trash (30 days by default) and goes back to its folder. Each keeps up to 20 earlier versions.")),
        Card(symbol: "square.and.arrow.up", title: t("Eksport", "Export"),
             text: t("Notatkę zapiszesz jako jedną stronę HTML z obrazkami w środku, jako PDF albo wydrukujesz.",
                     "Save a note as a single HTML page with its images inside, as a PDF, or print it.")),
        Card(symbol: "globe", title: t("Język i wygląd", "Language and look"),
             text: t("Polski albo angielski, przełączany od razu, bez restartu. Do tego dziesięć kolorów akcentu.",
                     "Polish or English, switched at once without a restart. Plus ten accent colours.")),
    ]

    static let more = t("Więcej", "More")
    static let less = t("Mniej", "Less")
    /// The line under the Fractal 8 Dev signature — the same as under the title on fractal8.eu.
    static let signatureLine = t("Natywne programy dla macOS, budowane według jednego wzoru.",
                                 "Native macOS software, built to a single pattern.")

    /// Every text of the window, for the check that none is missing a language.
    static var allTexts: [Text] {
        var all = [windowTitle, title, intro, goodToKnow, more, less, signatureLine]
        for s in sections { all += [s.title, s.lead] + s.steps + (s.more.map { [$0] } ?? []) }
        for c in cards { all += [c.title, c.text] }
        return all
    }
}
