# Chrome Web Store listing — MacDub · Live translation for Meet

Texts and assets for the Chrome Web Store Developer Dashboard. Package with
`scripts/package-extension.sh`; privacy policy in [PRIVACY.md](PRIVACY.md) (publish it at a
public URL, e.g. the file on GitHub).

## Store listing

**Name:** MacDub · Live translation for Meet

**Summary (132 chars max):**
Talk in any language on Google Meet: MacDub translates you and the others on your Mac, voice and chat.

**Description:**

> MacDub is a macOS app that translates conversations on your own Mac, with Apple's on-device speech recognition and translation. This extension connects it to Google Meet:
>
> • The call hears you translated — in the voice you choose in MacDub, even your own Personal Voice. The extension switches Meet's microphone to MacDub's translated voice while live translation runs, and gives you back your microphone when it stops. Meet's mute is always respected.
> • Your translated words can also be posted in the meeting chat.
> • Chat messages from the others are translated by MacDub and shown next to the conversation.
>
> Requires the MacDub app on a Mac with macOS 26 or later (https://github.com/lordbasex/macdub). The extension only talks to MacDub on your Mac (127.0.0.1): nothing is sent to any server.

**Category:** Communication (or Productivity)  **Language:** English (add Spanish and Portuguese)

## Privacy practices tab

- **Single purpose:** Connect Google Meet to the MacDub macOS app for live translation of the user's conversation (voice and chat).
- **Permission justifications:**
  - Host `meet.google.com`: read and post chat messages, and replace the microphone track with MacDub's translated voice during the call.
  - Host `127.0.0.1` / `localhost`: exchange translation text and status with the MacDub app on the same computer.
- **Remote code:** No.
- **Data usage:** "Website content" (chat messages) and "Personally identifiable information" (chat author display names) are handled only locally; not sold, not transferred to third parties, not used for purposes unrelated to the single purpose, not used for creditworthiness.
- **Privacy policy URL:** https://github.com/lordbasex/macdub/blob/main/docs/chrome-extension/PRIVACY.md

## Assets

- Icon 128×128: `extensions/meet-chat/icons/icon-128.png`
- Screenshots 1280×800 (1 to 5): MacDub's live translation screen during a Meet call; the Meet chat with a translated message; Settings › Extensions.
- Small promo tile 440×280 (optional).

## After it is published

1. Put the extension's id in `ChromeExtension.webStoreID` (Sources/MacDub/Support/ChromeExtension.swift): Settings › Extensions then opens the store, and Chrome offers the extension on its next launch.
2. Accept requests from that id only (the chat bridge in AppState accepts any `chrome-extension://` origin today).
