import Foundation

/// A small table of everyday emoji, found by name or by what they are used for. It is built in, so searching it never
/// leaves the Mac.
enum LauncherEmoji {
    static let table: [(emoji: String, words: String)] = [
        ("😀", "grinning face smile happy"), ("😄", "smile happy joy laugh"), ("😂", "tears of joy laugh lol funny"), ("🙂", "slight smile"),
        ("😉", "wink"), ("😊", "blush smile happy"), ("😍", "heart eyes love"), ("🥰", "smiling hearts love"), ("😘", "kiss blow"),
        ("😎", "cool sunglasses"), ("🤔", "thinking hmm"), ("😐", "neutral face"), ("😴", "sleeping tired zzz"), ("😢", "cry sad tear"),
        ("😭", "sob crying loud"), ("😡", "angry mad rage"), ("😱", "scream shocked fear"), ("🤯", "mind blown exploding head"),
        ("🥳", "party celebrate birthday"), ("🤗", "hug hugging"), ("🙄", "eye roll"), ("😅", "sweat smile relief nervous"),
        ("🤣", "rolling floor laughing rofl"), ("😇", "angel innocent halo"), ("🤩", "star struck wow"), ("😬", "grimace awkward"),
        ("👍", "thumbs up yes good ok approve"), ("👎", "thumbs down no bad"), ("👏", "clap applause bravo"), ("🙌", "raised hands praise hooray"),
        ("🙏", "pray please thanks folded hands"), ("🤝", "handshake deal agreement"), ("💪", "muscle strong flex"), ("👋", "wave hello goodbye hi"),
        ("✌️", "peace victory"), ("🤞", "fingers crossed luck"), ("👌", "ok hand perfect"), ("☝️", "point up one"), ("👀", "eyes look watching"),
        ("🧠", "brain think smart"), ("❤️", "red heart love"), ("💔", "broken heart sad"), ("💙", "blue heart"), ("💚", "green heart"),
        ("🔥", "fire hot lit flame"), ("✨", "sparkles magic shine new"), ("⭐", "star favorite"), ("🌟", "glowing star"), ("💯", "hundred perfect score"),
        ("🎉", "party popper celebrate tada congratulations"), ("🎊", "confetti celebrate"), ("🎂", "birthday cake"), ("🎁", "gift present"),
        ("✅", "check done yes complete tick"), ("❌", "cross no wrong cancel"), ("⚠️", "warning caution alert"), ("❗", "exclamation important"),
        ("❓", "question mark"), ("💡", "idea light bulb"), ("📌", "pin pushpin"), ("📎", "paperclip attach"), ("🔒", "lock secure private"),
        ("🔓", "unlock open"), ("🔑", "key password"), ("🔔", "bell notification"), ("🔕", "bell off mute"), ("📣", "megaphone announce"),
        ("📝", "memo note write"), ("📄", "document page file"), ("📁", "folder"), ("📅", "calendar date"), ("📆", "calendar tear off"),
        ("⏰", "alarm clock time"), ("⌛", "hourglass wait time"), ("⏳", "hourglass flowing wait"), ("🕐", "clock one o'clock time"),
        ("📧", "email mail message"), ("📞", "phone call telephone"), ("📱", "phone mobile"), ("💻", "laptop computer mac"), ("🖥️", "desktop computer"),
        ("⌨️", "keyboard"), ("🖱️", "mouse computer"), ("🔋", "battery power"), ("🔌", "plug power electric"), ("📷", "camera photo"),
        ("🎵", "music note song"), ("🎧", "headphones music audio"), ("🎮", "game controller video game"), ("📚", "books study read"),
        ("🔍", "search magnifying glass find"), ("🔗", "link chain url"), ("🛠️", "tools hammer wrench build"), ("⚙️", "gear settings cog"),
        ("🐛", "bug insect error"), ("🚀", "rocket launch fast ship"), ("🎯", "target bullseye goal"), ("🏆", "trophy winner prize"),
        ("💰", "money bag cash"), ("💸", "money wings spend"), ("💳", "credit card pay"), ("📈", "chart up growth increase"), ("📉", "chart down decrease"),
        ("📊", "bar chart graph stats"), ("🧾", "receipt invoice"), ("🏠", "house home"), ("🏢", "office building work"), ("✈️", "airplane travel flight plane"),
        ("🚗", "car drive"), ("🚲", "bicycle bike"), ("🌍", "earth globe world europe africa"), ("🌎", "earth globe americas"), ("🌏", "earth globe asia"),
        ("☀️", "sun sunny weather"), ("🌙", "moon night"), ("⛅", "partly cloudy weather"), ("🌧️", "rain weather"), ("❄️", "snowflake cold winter"),
        ("🌈", "rainbow"), ("🌸", "cherry blossom flower spring"), ("🌹", "rose flower"), ("🌳", "tree nature"), ("🍎", "apple fruit red"),
        ("🍕", "pizza food"), ("🍔", "burger hamburger food"), ("🍟", "fries food"), ("🍜", "noodles ramen food"), ("🍣", "sushi food"),
        ("🍰", "cake dessert"), ("🍫", "chocolate"), ("☕", "coffee hot drink tea"), ("🍵", "tea green hot drink"), ("🍺", "beer drink"), ("🍷", "wine drink"),
        ("🐶", "dog puppy pet"), ("🐱", "cat kitten pet"), ("🦊", "fox"), ("🐼", "panda"), ("🦄", "unicorn magic"), ("🐢", "turtle slow"),
        ("🤖", "robot bot ai"), ("👻", "ghost boo"), ("💩", "poop"), ("🙈", "see no evil monkey"), ("🎃", "pumpkin halloween"), ("🎄", "christmas tree"),
        ("➡️", "arrow right next"), ("⬅️", "arrow left back"), ("⬆️", "arrow up"), ("⬇️", "arrow down"), ("🔄", "refresh reload repeat arrows"),
        ("➕", "plus add"), ("➖", "minus subtract"), ("✖️", "multiply times x"), ("➗", "divide"), ("™️", "trademark"), ("©️", "copyright"),
        ("🇮🇳", "india flag"), ("🇺🇸", "usa united states flag america"), ("🇬🇧", "uk united kingdom britain flag"), ("🇪🇺", "european union flag"),
    ]

    /// The emoji whose words match `query`, best first.
    static func search(_ query: String, limit: Int = 6) -> [(emoji: String, words: String)] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }
        var scored: [(entry: (emoji: String, words: String), score: Int, order: Int)] = []
        for (order, entry) in table.enumerated() {
            // Each word of the name is tried, so "thumb" finds "thumbs up" at once.
            let best = entry.words.split(separator: " ").compactMap { FuzzyMatcher.score(text, in: String($0)) }.max()
            if let best, best >= 600 { scored.append((entry, best, order)) }
        }
        // Equal matches keep the order of the table, so the most common emoji come first.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.entry)
    }
}
