# macOS network entitlement review — 3 October 2026

Apple rejected native Mac **1.0.0 (101)** under **2.4.5 Performance: Hardware Compatibility (macOS)**. The automated message asks for removal of `com.apple.security.network.server` if unnecessary, or an explanation in both the review response and App Review Information if needed. Submission: `e9c86f1d-ebc6-46a2-995d-54867ef1adc9`.

## Required functionality

The native Desktop viewer uses the pinned LiveKit WebRTC SDK **150.7871.02** for self-hosted Memoh workspaces. `Homem/Core/DesktopModel.swift` creates a peer connection, a `display-input` data channel, and a receive-only video transceiver. It gathers ICE candidates and submits its offer over authenticated HTTPS. Desktop video and ICE/data-channel traffic use ephemeral UDP sockets. `disconnect()` closes the data channel and peer connection. `HomemMac/MacTools.swift` presents this viewer through the Workspace menu, initially in View Only mode.

Apple's [server entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server) and [client entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client) explain that UDP permissions govern data flow as well as connection initiation. Receiving UDP traffic requires the server entitlement, including in an application that initiates its session.

## Sandbox diagnostic

A development-signed, sandboxed native probe used the same pinned WebRTC framework and offer/ICE gathering sequence as the app. The executable and framework were identical between runs; only `com.apple.security.network.server` changed in the app signature.

| Network entitlements | UDP ICE candidates | TCP ICE candidates | Gathering completed |
| --- | ---: | ---: | --- |
| Client only | 0 | 4 | Yes |
| Client and server | 4 | 4 | Yes |

This confirms that removing the server entitlement prevents the native WebRTC UDP path from gathering candidates. The diagnostic tested ICE gathering, not a complete remote video/control session. Probe files and raw logs remain outside the repository; local network addresses and credentials are omitted.

Authenticated read-only checks of the existing review server confirmed Desktop enabled, available, running, and supported for all five demo agents. The review steps select **Taki Shiina** and **Workspace > Open Desktop in New Window** (Command-Shift-D). View Only starts enabled; users can turn it off to control the remote desktop.

## Review correction

The server entitlement is retained because the desktop feature needs it. Its source declaration now includes a comment explaining the UDP requirement. No executable change or replacement upload is needed for this clarification.

The existing App Review Information was preserved and extended with the entitlement explanation, Apple's documentation link, the sandbox diagnostic, and precise demo steps. The saved notes were read back from Apple's API and verified. Existing demo credentials were retained.

A response is saved as an **unsent draft** in App Store Connect. Sending it to Apple's review team requires explicit authorization under the session's messaging rule. After that authorization, send the draft and resubmit the existing native build, retaining manual release. Current version state remains **REJECTED** and submission state **UNRESOLVED_ISSUES** until the response/resubmission steps complete.

## Prepared response

Hello App Review,

Homem needs com.apple.security.network.server for its native WebRTC remote desktop viewer. The self-hosted server supplies a remote agent desktop. Homem negotiates the session over authenticated HTTPS, then receives desktop video and ICE/data-channel traffic through ephemeral UDP sockets. Pointer and keyboard input use the WebRTC data channel when View Only is turned off. Closing the desktop closes the peer connection.

Apple's documentation explains that UDP network entitlements restrict data flow as well as initiation, so UDP apps usually need both network.client and network.server:
https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server

We verified the requirement using a sandboxed diagnostic with the same pinned native WebRTC SDK and offer/ICE gathering path as the submitted app: the client entitlement alone produced 0 UDP ICE candidates, while enabling both produced 4. Removing network.server would prevent normal UDP desktop transport.

We have added this explanation and review steps to App Review Information. To view the feature in build 1.0.0 (101), select Self-hosted Server, sign in with the existing review API address and demo credentials, select Taki Shiina, then choose Workspace > Open Desktop in New Window (Command-Shift-D). Desktop access is enabled, available, and running on the review server. The viewer starts in View Only; turn it off to test control.

Please continue reviewing the submitted native Mac build with this entitlement explanation. Thank you.
