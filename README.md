# Hearthmail

An email app with a private AI assistant. All AI runs locally through
[Ollama](https://ollama.com); no email content leaves your computer.
Built with Flutter, so one codebase targets macOS, Windows, Android and iOS.

## AI features

| Feature | Where |
|---|---|
| **Smart inbox**: sorts mail into Priority, Needs reply and categories (Work, Finance, Travel, …) | Sidebar (runs automatically; ✨ re-sorts) |
| **Summarize**: TL;DR, action items, key dates | Reading pane |
| **Quick replies**: 3 one-click replies, expanded into a full draft | Reading pane |
| **Reply with AI**: describe what to say ("yes, but Thursday") and get a draft | Reading pane |
| **Write for me**: turn rough notes into an email | Composer |
| **Rewrite**: Improve, Shorter, More detail, Formal, Friendly, Fix grammar, Format | Composer |
| **Custom edits**: "mention the deadline is Friday" | Composer → Write for me |
| **Subject suggestions** | Composer ✨ next to Subject |
| **AI search**: plain-English search turned into server filters, then ranked by relevance | Search bar (✨ switch) |
| **Ask your inbox**: answers questions like "when does my flight leave?" from your mail | Search results |
| **Catch me up**: digest of unread mail grouped by what needs attention | Top bar |
| **Search by meaning**: local vector index, merged with keyword search | Search bar |
| **Translate**: emails in other languages, and your drafts into any language | Reading pane, Composer |
| **Add to Calendar**: finds the date/time in an email | Reading pane |
| **Phishing warning** | Reading pane, list |

Plus the everyday Apple Mail / Gmail features: Remind me (snooze), Send later,
Undo send, follow-up reminders, VIPs, mute, block, unsubscribe, forward,
attachments, templates, signatures, contact autocomplete, filters and swipe
actions. See [FEATURES.md](FEATURES.md) for the full comparison, what isn't
possible, and which local model does what.

Formatting: the composer accepts light Markdown (`**bold**`, `- bullets`),
which is sent as real formatted HTML with a plain-text fallback.

## Run it (macOS)

Requirements: Xcode, Flutter, and Ollama with these models:

```bash
ollama pull gemma4:12b            # sorting, summaries, writing
ollama pull embeddinggemma:300m   # search by meaning
ollama pull translategemma:4b     # translation (optional)
```

```bash
flutter run -d macos
```

For a standalone app: `flutter build macos`. The app is written to
`build/macos/Build/Products/Release/Hearthmail.app`.

## Accounts

Add as many accounts as you like. They all stay connected, and their mail
appears together in **All Inboxes** (each email shows a colored label for its
account). AI sorting, search and "Catch me up" cover every account at once.
Expand an account in the sidebar to open its folders. Replies are sent from
the account that received the email, and new messages have a **From** picker.

Three ways to sign in:

- **Sign in with Google**: Gmail and Google Workspace (many universities).
- **Sign in with Microsoft**: Outlook.com and Microsoft 365 (many
  universities). Microsoft 365 no longer accepts passwords from mail apps.
- **App password**: Gmail, iCloud, Yahoo, Fastmail or any IMAP/SMTP server.
  Providers are detected automatically or looked up via autoconfig.

Google and Microsoft sign-in need a free, one-time app registration. See
[OAUTH_SETUP.md](OAUTH_SETUP.md). Passwords and sign-in tokens are stored in
the macOS Keychain.

## Project layout

```
lib/
  services/ai/       AI layer, independent of Flutter and the mail code
    ai_provider.dart     interface: swap in another AI backend here
    ollama_provider.dart local Ollama implementation
    email_ai.dart        all email prompts and features
  services/
    mail_service.dart    IMAP/SMTP via enough_mail (one per account, operations serialized)
    oauth.dart           Sign in with Google / Microsoft (PKCE + loopback redirect)
    settings_store.dart  preferences + keychain
    triage_cache.dart    remembers AI sorting per message
  state/app_state.dart   app logic (ChangeNotifier)
  ui/                    screens; adapts 3-pane (desktop) ↔ 1-pane (phone)
tool/ai_smoke.dart       live test of every AI feature against Ollama
tool/model_bench.dart    compares models on search, sorting, speed and translation
```

## Other platforms

- **Windows**: `flutter run -d windows` (on a Windows PC with Ollama installed).
- **Android/iOS**: phones can't run Ollama. Point Settings → *Ollama address*
  at your Mac (e.g. `http://192.168.1.20:11434`, with Ollama started using
  `OLLAMA_HOST=0.0.0.0`). Alternatively, add an on-device provider by
  implementing `AiProvider`.

## Tests

```bash
flutter test                                  # unit tests
dart run tool/ai_smoke.dart gemma4:12b-mlx    # live AI check (Ollama must be running)
```

## License

MIT. See [LICENSE](LICENSE).
