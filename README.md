# FAP Memo Reviewer

A native Mac app that reviews Word memos with Claude and gives you back a copy with **real Word tracked changes and comments**.

Drop in a `.docx`, pick a review profile, add optional instructions and click **Review**. A new file named `Memo (Reviewed).docx` is saved next to the original, and **Open in Word** takes you straight to it. The original file is never modified.

## Install

1. Download **FAP-Memo-Reviewer.zip** from the latest [release](../../releases), or from the latest successful **Build** run under the repository's **Actions** tab (the zip is under *Artifacts*).
2. Unzip it and drag **FAP Memo Reviewer** into your **Applications** folder.
3. The first time only, open it with a right-click → **Open**. The app isn't notarized by Apple, so macOS asks for confirmation once. On macOS 15 or later, if there's no Open option, go to **System Settings › Privacy & Security** and click **Open Anyway**.

Requires macOS 14 Sonoma or later. Works on Apple silicon and Intel Macs.

## One-time Claude setup

Reviews run through **Claude Code**, Anthropic's official app, signed in with your **existing Claude subscription** (Pro, Max, Team or Enterprise). This app never stores credentials or API keys.

If Claude Code isn't installed or signed in, the app shows a banner with an **Install Claude Code…** or **Sign In…** button. That button opens a Terminal window once to run Anthropic's official installer and sign-in. Everyday reviewing never needs Terminal.

**No surprise API charges.** Before every review the app asks Claude Code how it's signed in. If it's using a pay-per-use Anthropic Console API key, an API key helper, or a third-party provider (Bedrock, Vertex, a gateway), the review is paused and nothing is sent. API-key environment variables are also removed before Claude Code starts. Reviews count toward your normal Claude subscription usage limits.

## Using it

| | |
|---|---|
| **Document** | Drop a `.docx` on the window, click the drop area, use **File › Open Document…** (⌘O), or right-click a file in Finder and choose **Open With › FAP Memo Reviewer**. |
| **Review profile** | Your saved screening criteria. Edit them under **FAP Memo Reviewer › Settings › Profiles** (⌘,). A starting **FAP Screening** profile is included, carried over from the earlier web version. Check it against current policy before relying on it. |
| **Criteria documents** | Attach policy excerpts or checklists (.docx, .pdf, .txt, .md) to a profile under **Settings › Profiles › Criteria Documents** by clicking **Add Files…** or dropping them in. Their text is added to every review using that profile. To update one, remove it and add the newer version. |
| **Instructions** | Optional notes for this memo only, e.g. "Focus on the utilization figures." |
| **Review** | ⌘↩. Usually takes under a minute. You can cancel at any time. |

The reviewed copy contains:

- **Tracked changes** (insertions and deletions) attributed to the name set in **Settings › General** (default "Chris Holm"). Accept or reject them in Word as usual.
- **Comments** anchored to the exact text they refer to, including an **Overall review** comment on the first line.

Settings and profiles are stored only on this Mac, in `~/Library/Application Support/FAP Memo Reviewer/` and the app's preferences.

## What makes the output trustworthy

The app writes Word's own revision markup (`w:ins`, `w:del`, comments). It does not imitate tracked changes with colored text. Every reviewed copy is checked before it is saved:

- Rejecting all of the new changes must reproduce the original text exactly, paragraph by paragraph.
- Accepting them must produce exactly the wording Claude proposed.
- Every part of the file that wasn't edited (styles, headers, footers, footnotes, images, numbering, settings) must be byte-for-byte identical to the original.
- Each change and comment must be present once and correctly linked.

If any check fails, no file is saved and you see the reason.

A suggestion is **left out and listed in the results** instead of being forced in when:

- its quoted text can't be found exactly once (Claude gets one automatic chance to correct it), or
- it would change text inside a field (such as a date or page number), a content control, someone else's tracked change, or an embedded object.

If no suggestion can be placed reliably, no file is produced.

### Current limits

- Only body text (including tables) is reviewed. Headers, footers, footnotes and text boxes are left as they are.
- Changes stay within a paragraph. Adding or removing whole paragraphs is suggested in comments instead.
- `.doc` and macro-enabled `.docm` files must first be saved as `.docx` in Word.

## For developers

```
Sources/ReviewCore/        Document engine, verifier, Claude Code bridge (macOS and Linux)
Sources/FAPMemoReviewer/   SwiftUI app (macOS)
Sources/review-tool/       Command-line harness for the engine
Tests/ReviewCoreTests/     Unit tests and fictional fixture memos
scripts/build-app.sh       Builds and ad-hoc signs the universal .app into dist/
```

- `swift test` runs the engine tests (macOS or Linux).
- `scripts/build-app.sh` builds `dist/FAP Memo Reviewer.app` (macOS with Xcode 16 or the Command Line Tools).
- GitHub Actions runs both on every push. Pushing a tag such as `v1.0.0` publishes a release with the zipped app.
- `python3 scripts/make_fixtures.py` regenerates the fictional test memos (needs `python-docx`). All names and figures in them are invented.
- `swift run review-tool review memo.docx criteria.txt` runs a full review from the command line.
