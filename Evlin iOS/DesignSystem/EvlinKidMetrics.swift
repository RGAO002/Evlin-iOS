import CoreGraphics

/// Recurring layout values from the JSX prototype. Sourced by inspection of
/// `home.jsx`, `task-detail.jsx`, `bypass.jsx`, `consequence-a.jsx`,
/// `consequence-b.jsx`, `home-reflection.jsx`, `primitives.jsx`.
enum EvlinKidMetrics {
    enum Padding {
        static let screenH: CGFloat = 20      // every screen is 0/20px horizontal
        static let screenTop: CGFloat = 8     // most screens
        static let screenBottom: CGFloat = 30 // most screens
        static let cardInner: CGFloat = 22    // EvCard default in primitives.jsx is 20; hero cards use 22
        static let listGap: CGFloat = 10      // task row gap
    }

    enum Radius {
        static let card: CGFloat = 20         // EvCard
        static let cardLarge: CGFloat = 22    // task evidence camera button
        static let row: CGFloat = 18          // TaskRow
        static let chip: CGFloat = 999        // pill chip
        static let button: CGFloat = 18       // EvBigButton
        static let progressBar: CGFloat = 999
    }

    enum Size {
        static let buttonHeight: CGFloat = 58 // EvBigButton
        static let buttonHeightLg: CGFloat = 60 // reflection-flow buttons
        static let progressBarThick: CGFloat = 14 // home time hero
        static let progressBarThin: CGFloat = 4   // reflection step bar
        static let segPip: CGFloat = 5            // home quest pips
        static let taskCheckCircle: CGFloat = 30  // task row check circle
    }

    enum Letter {
        static let tightTitle: CGFloat = -0.8     // h1 hero
        static let mediumTitle: CGFloat = -0.6    // h2
        static let body: CGFloat = -0.2           // body
        static let upperLabel: CGFloat = 0.8      // ALL-CAPS labels
    }
}
