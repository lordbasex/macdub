# MacDub · Live translation for Meet — privacy policy

*Last updated: 24 September 2026*

"MacDub · Live translation for Meet" is a Chrome extension that works together with **MacDub**, a macOS app that translates conversations on the user's own Mac.

## What the extension does

On `meet.google.com` pages only, and only while the MacDub app is running on the same computer with live translation started:

- it sends the call the translated voice produced by MacDub (a virtual microphone on the same Mac) instead of the microphone chosen in Meet, and restores the user's microphone when MacDub stops;
- it can post MacDub's translation of what the user says in the meeting's chat;
- it passes the meeting's chat messages to MacDub so MacDub can translate them.

## Data

- **Where data goes:** only to the MacDub app on the same Mac, at `http://127.0.0.1` (the computer itself). The extension sends nothing to any other server, and neither the developer nor anyone else receives it.
- **What is exchanged:** the text of chat messages (and their author's display name, when Meet shows it) from Meet to MacDub; translated text from MacDub to Meet's chat; whether live translation is running.
- **Audio:** the extension does not record or transmit audio anywhere except into the Meet call itself, as the user's microphone would.
- **Storage:** the extension stores nothing. MacDub may save conversations on the user's Mac (its History), which the user can turn off or delete in MacDub's settings.
- **No analytics, no advertising, no sale or transfer of data**, no remote code.

## Permissions

- `meet.google.com`: to read and post chat messages and to switch the microphone inside Meet.
- `http://127.0.0.1/*`, `http://localhost/*`: to talk to the MacDub app on the same Mac.

## Contact

Federico Pereira — https://github.com/lordbasex/macdub/issues
