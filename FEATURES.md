# Hearthmail vs Apple Mail and Gmail

Status as of 18 Nov 2026. ✅ built · 🔜 possible, not built yet · ⚠️ possible with limits · ❌ not possible

## Reading and organizing

| Feature (from) | Status | Notes |
|---|---|---|
| Unified inbox, many accounts (both) | ✅ | |
| Emails look as designed (both) | ✅ | Real WebKit engine, wide newsletters scaled to fit |
| Block tracking pixels / remote images (Apple: Mail Privacy Protection) | ✅ | Apple also hides your IP through its servers; that relay is ❌ |
| Inline images, attachments open/save (both) | ✅ | |
| Collapse quoted replies "•••" (Gmail) | ✅ | |
| Categories / Primary-Promotions tabs (both) | ✅ | Local AI |
| Priority / important (Gmail), Priority messages (Apple) | ✅ | |
| Needs reply (Gmail nudges) | ✅ | |
| VIPs (Apple) | ✅ | VIP mail always counts as Priority |
| Remind me / Snooze (both) | ⚠️ | Stored on this computer; other devices still show the email |
| Follow-up reminder if no reply (Apple, Gmail nudge) | ✅ | |
| Flag, read/unread, archive, delete, junk / not junk, move (both) | ✅ | Undo after archive, delete, junk and move; delete in Trash erases |
| Filters: unread, flagged, attachments (Apple) | ✅ | |
| Mark all as read | ✅ | |
| Mute conversation (both) | ⚠️ | New replies archived automatically while Hearthmail is open |
| Block sender (both) | ⚠️ | Their mail goes to Junk while Hearthmail is open |
| Unsubscribe button (both) | ✅ | One-click (RFC 8058), email or web page |
| Phishing / scam warning (Gmail) | ✅ | Forged-sender check + AI |
| Translate email (Gmail, Apple Intelligence) | ✅ | translategemma:4b |
| Summarize (both) | ✅ | |
| Add event to Calendar (Apple data detectors) | ✅ | AI finds date and time, Calendar confirms |
| Swipe to archive/delete on phones (both) | ✅ | |
| Keyboard shortcuts (both) | ✅ | Apple Mail's: ⌘N, ⌘R, ⇧⌘R, ⇧⌘F, ⌃⌘A, ⌘⌫, Delete, ↑/↓, ⇧⌘U, ⇧⌘L, ⇧⌘J, ⇧⌘N, ⌃⌘S, ⇧⌘D (send), ⌘, |
| Conversations (both) | ✅ | One row per conversation with a count; earlier messages shown under the open one |
| Select several emails, act on all | 🔜 | |
| New-mail notifications, Dock badge | ✅ | Instant (IMAP IDLE) while the app runs |
| Notifications when the app is closed | ❌ | Needs a server watching your mail 24/7 |
| Print / save as PDF | ✅ | |
| Package tracking card (Gmail) | 🔜 | AI can extract tracking numbers |
| Sender logos (BIMI, Apple Branded Mail) | 🔜 | |
| Rules / filters running on the server (Gmail filters, Sieve) | ❌ | Gmail filters aren't reachable over IMAP; local rules (block, mute) work |

## Writing and sending

| Feature (from) | Status | Notes |
|---|---|---|
| Write for me, rewrite, tone, grammar (Gmail Help me write, Apple Writing Tools) | ✅ | |
| Quick replies (both) | ✅ | |
| Suggested subject | ✅ | |
| Formatting: bold, lists | ✅ | Markdown, sent as real HTML; your line breaks are kept |
| Write in another language | ✅ | Uses the writing model (better at writing other languages) |
| Forward with attachments (both) | ✅ | |
| Attach files (both) | ✅ | |
| Contact autocomplete (both) | ✅ | Learned from your mail, stays on this computer |
| Per-account signatures (both) | ✅ | |
| Templates (Gmail) | ✅ | |
| Undo send (both) | ✅ | 5–30 seconds; quitting sends waiting messages instead of dropping them |
| Send later / schedule (both) | ⚠️ | Sent by this app, so the Mac must be on with the app open (or it sends when opened). Gmail's server-side scheduling isn't reachable over IMAP |
| Drafts (both) | ✅ | Autosaved every 30 s (replacing the previous copy), Edit Draft to continue, removed after sending |
| Smart Compose (inline autocomplete while typing) | 🔜 | Possible with a small fast model |
| Rich text editor (fonts, colors) | 🔜 | Markdown covers bold/lists/links today |
| Read receipts | ❌ | Not standard email; trackers |
| Gmail confidential mode, AMP dynamic email | ❌ | Gmail-only, closed |
| Hide My Email, Mail Drop (iCloud) | ❌ | Apple services with no public API |
| Large files via Google Drive / iCloud links | ❌ | Needs those cloud services |
| Vacation auto-reply | ⚠️🔜 | Gmail needs its web API (extra permission); Microsoft and many servers support it differently |

## Search

| Feature | Status | Notes |
|---|---|---|
| Keyword search (server side, Gmail's own engine on Gmail) | ✅ | All words must match; from:, to:, subject:, has:attachment, is:unread, is:flagged, after:, before:, "phrases" |
| Natural-language search ("flight to Lisbon in December") | ✅ | AI turns it into filters |
| Search by meaning (semantic / vector) | ✅ | Local index, see below |
| Ask your inbox ("when does my flight leave?") | ✅ | |
| Search all mail offline | 🔜 | Index has the meaning, not full text |

## Local AI: which model does what

Measured on this Mac (M3 Pro, 36 GB) with `tool/model_bench.dart`:

| Job | Model | Result |
|---|---|---|
| Sorting, summaries, search planning, event finding | **gemma4:12b-mlx** | Priority correct 18/20 (qwen3.6: 14/20); category 19/20; ~0.7 s per email |
| Writing replies and drafts | **gemma4:12b-mlx** | ~29 tokens/s, short reply in ~1.7 s |
| Search by meaning | **embeddinggemma:300m** | Right email first 40/40 on hard queries (qwen3-embedding 0.6b: 38/40), 12 ms per email, 621 MB |
| Translating mail you read | **translategemma:4b** | Most faithful (gemma4 added a made-up "Dear [Name]" and mistranslated Hindi) |
| Translating text you send | **gemma4:12b-mlx** | More natural German than translategemma |

`qwen3.6:35b-a3b` is faster at writing (53 tokens/s) but uses 23 GB of memory, sorts less reliably, and earlier mixed up who sent what. It is not needed and can be removed (`ollama rm qwen3.6:35b-a3b`) to free disk space.

### How semantic search works
Each email (subject, sender, date, first 1,500 characters) becomes a 512-number "meaning" vector made by embeddinggemma, stored per account in a small file on this Mac (about 2 KB per email). A search compares the question against all of them (around 10 ms for 20,000 emails), then merges those results with the server's keyword results and lets the AI rank the best. A separate vector database isn't needed at this size: a plain scan is exact and fast. Indexing runs in the background on its own connection: the latest 3,000 emails per account by default (adjustable in Settings).
