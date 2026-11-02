# MyAgenda

SwiftUI notebook app for iPad (Apple Pencil) and iPhone. iOS 26.5, SwiftData + CloudKit,
PencilKit. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, Swift 5 language mode.
The owner (Alex) writes in Romanian; every user-facing string and every reply to him is in Romanian.
Goal, in his words: „o aplicație cât mai utilă și minimalistă”.

## How we work

Each change goes through five roles, each a project agent in `.claude/agents/`:

1. `product-owner`: what the user should experience, and what is out of scope.
2. `architect`: how to build it in this codebase. Files, data, risks.
3. `developer`: implements the architect's design, then typechecks and builds.
4. `reviewer`: critical review of the diff. Bugs, regressions, simpler ways.
5. `tester`: runs the app on the simulators and checks the product owner's criteria.

The main session orchestrates. It passes each role the previous roles' output and reports to Alex at the end.

## Rules

- Never commit, unless Alex asks for it.
- Do not touch `MyAgenda/Models/TimerActivityAttributes.swift`.
- Before editing `MyAgenda/Drawing/CustomInkView.swift`, back it up. Then make targeted edits only.
- Model changes must stay CloudKit-safe: every stored property has a default, nothing unique, relationships optional.
- Match the surrounding code: comment density, naming, idiom.

## Checks after every change

Typecheck in Swift 5 and Swift 6 mode, then build:

```bash
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
find MyAgenda -name '*.swift' > "$TMPDIR/myagenda-files.txt"
swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios26.5-simulator -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault @"$TMPDIR/myagenda-files.txt"
swiftc -typecheck -swift-version 6 -sdk "$SDK" -target arm64-apple-ios26.5-simulator -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault @"$TMPDIR/myagenda-files.txt"
xcodebuild -scheme MyAgenda -configuration Debug -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)' -derivedDataPath "$TMPDIR/myagenda-dd" build
```

## Simulators

- iPad Pro 11-inch (M5) and iPhone 17 Pro. Bundle id: `GrowthCompany.MyAgenda`.
- Neither simulator is signed into iCloud.
- The store is `Library/Application Support/default.store` in the app's data container (`xcrun simctl get_app_container <udid> GrowthCompany.MyAgenda data`).
- Back up the store before a test that writes data, and restore it afterwards.
