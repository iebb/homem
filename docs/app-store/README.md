# App Store preparation

Current review corrections and resubmission status: [September 27, 2026](REVIEW-2026-09-27.md).

The [September 26 consent implementation](REVIEW-2026-09-26.md) was removed at the owner’s request; its notes are historical.

The preparation notes below describe earlier work from September 18, 2026 and are retained as history.

App: Homem · `ad.neko.homem` · Apple ID `6812852139` · Kitta Ltd

## Saved in App Store Connect

- Version 1.0 remains **Prepare for Submission**; manual release is selected.
- English (U.S.), Simplified Chinese, Japanese, and Spanish (Spain): subtitle, promotional text, description, and keywords. Source copy is in `metadata.json`.
- Promotional text and descriptions now lead with the cloud computer; desktop/terminal access comes before the agent-chat feature. The name, subtitles, keywords, and in-app terminology were not changed in this copy pass.
- Support URL in all four localizations: https://docs.kitta.co/homem/support/
- Privacy Policy URL in all four localizations: https://docs.kitta.co/homem/
- Both public pages are deployed from `kitta-co/privacy-policy` on GitHub Pages (commit `705bb4b`), linked from the docs home page, and use the existing public support contact `support@ieb.app`. Publication copies are in `SUPPORT.md` and `PRIVACY.md`.
- Primary category Productivity; secondary category Utilities.
- Copyright: 2026 Kitta Ltd.
- The user has supplied the review server URL in review notes. The supplied credentials work in the app and browser, but the App Store Connect review username/password fields remain blank: browser input attempts did not persist. Save them in App Review Information before submission.
- Ten current screenshots each are uploaded to the iPhone 6.9-inch and 13-inch iPad galleries and verified after reloading. The earlier five iPhone 6.5-inch screenshots remain. See `screenshots/README.md` for sources and exports.
- Build **18 / 1.0.0** is attached to the draft and was verified after reloading App Store Connect. Replace it with a current processed build containing the dynamic workspace/navigation, sharing and terminal fixes.

## Still required before submission

- Save the supplied working review credentials in App Store Connect; keep the review server available throughout review.
- Review contact email and phone number remain blank. Existing first/last name fields contain Kitta / Labs; confirm the reviewer contact details.
- Confirm server-side retention and provider practices before completing/publishing App Privacy answers. The native client has no advertising/tracking/analytics SDK; this does **not** mean that conversations, uploads, or account data sent to the selected server are never collected.
- Finish/verify age rating and content-rights declarations. The age-rating questionnaire was being edited interactively and was left alone.
- Confirm pricing, territories, and any applicable business/trader information.

## Share extension release check

The application embeds `ad.neko.homem.share`, using the containing app's existing Keychain access group `$(AppIdentifierPrefix)ad.neko.homem`. Automatic signing must provision both targets with the same team and matching build/version numbers. No App Group container or externally shared credentials are required.

Xcode Cloud build 26 compiled and archived successfully, but distribution export failed because `ad.neko.homem.share` was not registered. On 2026-09-18, the explicit App ID **Homem Share Extension** was registered under **Kitta Ltd / 7P8CLHDH5G**. Xcode Cloud can now create its managed provisioning profiles. Register future extension bundle IDs in the same Apple Developer team before the first Cloud archive; the Cloud export service cannot register them automatically. No application code or entitlement changes were needed for this signing fix.

After updating, open Homem once so it can publish the saved-account directory to Keychain. Other apps' system share sheets can then choose an account, workspace, and bot. Up to 20 files (50 MB each) are copied locally, streamed to a new `Shared-…` folder under `/data`, and removed from the extension's temporary storage on completion/dismissal. The sheet stays open during uploads; a partial failure can retry only remaining files.

Validation: iPhone simulator build and focused token/date/auth/file regression tests; live official-server token usage; Photos → Share → Homem → Max successfully uploaded the app-icon fixture into `/data/Shared-20260918-0219-062FA7D6`.

No App Store review submission or release was performed.

Implementation references: Apple’s [share-extension activation keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html) and [extension data-handling guidance](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html).

## Workspace layouts

Desktop input now uses the native iOS keyboard directly, with committed IME text, backspace on an empty input buffer, newline/tab keysym mapping, hardware navigation keys, and a scrolling shortcut row (modifiers, arrows, F1–F12, Home/End and Delete). Runtime input writes are queued in order and each complete key press/release is sent together, preventing rapid repeated characters from overlapping. Fullscreen presents the same desktop connection from a standalone screen or workspace pane; view-only mode still blocks input. Validation: iPhone simulator build, six desktop connection/input tests, and localization coverage passed. Live fullscreen/keyboard UI verification remains pending because simulator coordinate taps were inconsistent.

The Add pane menu supports additional chats, files, terminals and desktops. Each chat can select its own agent and conversation. Pane menus reorder the added panes; each pane closes independently. Automatic layout uses chat on the left and two tools on the right on iPad, a grid for larger sets, and a vertical split on iPhone. Side-by-side, stacked and grid arrangements are also available; overflowing layouts scroll instead of shrinking panes beyond usability. Automatic two/three-pane dividers remain resizable and accessible. Desktops start in view-only mode.

Workspace content is bounded below the navigation bar. Embedded file browsing and conversation selection use local controls instead of replacing the workspace title. iPad app tabs sit at the bottom. The chat sidebar uses a compact native navigation title and compose button, sidebar-scoped search, and native sidebar list styling. The oversized in-list Chats heading and redundant Recent section were removed on regular-width windows. The workspace picker stays top-left; the agent picker appears once in the detail toolbar, including when no conversation is selected. Sidebar width adapts from 280–380 points (320 preferred). This follows Apple's [sidebar](https://developer.apple.com/design/human-interface-guidelines/sidebars) and [split-view](https://developer.apple.com/design/human-interface-guidelines/split-views) guidance. Verified visually on the 13-inch iPad simulator in landscape and portrait, including opening a conversation; simulator build and localization checks passed.

Validation: simulator build, two focused geometry tests (all four arrangements, 1–8 panes, narrow/keyboard/iPad sizes), localization coverage, live iPad pane add/remove and two independent real conversations, and iPhone portrait split with the software keyboard. The review server's desktop connection still disconnects; this layout change does not claim to resolve that server connection problem.

The iPhone 17 Pro Max and iPad Pro 13-inch simulators have both authorized official and review accounts. Five MyGO agents with five-star card icons and real conversations are configured on the review server. Temporary credential-transfer test code was removed. App Privacy still needs confirmation of whether Kitta operates or receives data from a Memoh service. App Store review has not been submitted.

Terminal follow-up: periodic WebSocket pings keep idle shells alive through proxies, and an explicit keyboard-dismiss button is available in standalone and split panes. Standalone terminals hide the app tab bar. Simulator build passed; live iPad idle/reuse and iPhone keyboard dismissal were verified.

## Supermarket and saved workspaces

Supermarket uses server-side `q`, `page`, and `limit` parameters. It debounces search, loads the next page near the end of the list, deduplicates apps by registry/app ID, and retries failed pages without discarding earlier results. The introductory Apps and skills block has been removed. A live review-server check returned 154 apps, distinct page-one/page-two entries, and Google Calendar for the calendar query.

Each agent has its own saved workspace, scoped to the signed-in account/server/team. Selecting a sidebar conversation replaces the primary chat only. Pane handles support drag-and-drop ordering (including the primary chat); header menus switch pane type or agent and retain accessible move commands. Saved layouts include pane order, arrangement, split sizes, secondary chats, file folders and desktop mode. Connections reopen when the workspace is restored; running terminal processes are not serialized. Unsent first-message payloads are excluded from the saved layout to prevent replay after relaunch.

Validation: simulator build, focused pagination/retry and workspace-persistence/isolation tests, localization coverage, live catalog API checks and iPad sidebar navigation. Simulator coordinate interaction was unavailable for the pane toolbar, so drag-and-drop was not exercised live in this pass.
