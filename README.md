# AI File Renamer for macOS

A background service that watches the folders you choose and, when a new file appears there, reads its content with the Claude API and renames it automatically. Names start with the date from the content and a short Title Case title: for example, `scan0012.pdf` becomes `2026-10-15 Acme Invoice.pdf`. When the content shows no date, the name starts with the date the file was downloaded instead, so every name starts with a date. Identical copies are marked `(duplicate)`.

## How it works

- Runs as a **launchd user agent**: it starts at login and restarts if it crashes.
- Checks the watched folders every few seconds. It waits for a file to stop changing first, and skips partial downloads (`.crdownload`, `.download`, `.part`, …), hidden files and folders.
- Sends the content to Claude (`claude-opus-5-5`, low effort, structured JSON output) and asks for a descriptive name. The extension is never changed, and a different file with the same name gets ` 2`, ` 3`, … added.
- Files that were already in a folder when you installed are left alone. Each file is processed only once: it is tracked by inode, so a renamed file is not picked up again.
- Your API key is stored in the **macOS Keychain**, not in a file.

| File type | How the content is read |
|---|---|
| PDF | First 3 pages sent to Claude as a document (text and scans) |
| PNG, JPG, GIF, WEBP, HEIC, TIFF, BMP | Sent as an image (converted and resized with `sips` when needed) |
| DOC, DOCX, RTF, ODT, webarchive | Converted to text with the built-in `textutil` |
| Text and code files (txt, md, csv, json, html, py, …) | Read directly |
| XLSX, PPTX | Text extracted from the file |
| ZIP | The list of files inside |
| Pages, Numbers, Keynote, DMG | Spotlight metadata, where available |
| Videos, audio, large files, password-protected PDFs, anything else | File details (kind, length, download source, dates) plus a Quick Look preview frame |

Folders are renamed too, from the list of files inside them and any readme or notes. App bundles and folders that apps save into (`Chrome`, `Telegram Lite`, …; see `keep_folder_names`) are left alone. A new folder is only renamed once nothing inside it has changed for a few seconds.

A file whose extension is wrong or missing but that is really a PDF or image is read as one and gets the right extension.

## Install

Requires Python 3 (the Xcode Command Line Tools one is enough) and an [Anthropic API key](https://console.anthropic.com/).

```bash
git clone https://github.com/spilafas/osx-download-files-automator.git
cd osx-download-files-automator
./install.sh                         # choose folders in a Finder dialog
# or: ./install.sh ~/Downloads ~/Desktop/Scans
```

The installer creates a virtualenv, asks for your API key (input is hidden), writes the config and starts the service.

### Folder permissions (Downloads, Desktop, Documents)

macOS protects these folders from background processes, and only you can allow access, in System Settings. No script can turn it on, not even with `sudo`. To make it one switch, the service runs inside its own small app, `~/Applications/AI File Renamer.app`.

If access is needed, `install.sh` opens **System Settings → Privacy & Security → Full Disk Access** and shows the app in Finder. Drag **AI File Renamer** into the list, turn it on, and the installer confirms once access works.

Running `install.sh` again keeps the same app, so you don't have to allow access again. A new app is only built when `launcher.c` changes, and then macOS asks again.

## Configuration

Edit `~/Library/Application Support/AIFileRenamer/config.json`, then restart the service with the command above.

| Key | Default | Meaning |
|---|---|---|
| `watch_folders` | `["~/Downloads"]` | Folders to watch (top level only) |
| `model` | `claude-opus-5-5` | Claude model |
| `effort` | `low` | `low` / `medium` / `high`: higher is slower and costs more |
| `naming_instructions` | date first (YYYY-MM-DD), 2 to 5 word Title Case title | How names should look. Write your own style here |
| `max_name_chars` | `60` | Hard cap on name length |
| `max_pdf_pages` | `3` | PDF pages sent to Claude |
| `workers` | `4` | Files processed in parallel by `--existing` |
| `date_fallback` | `download` | Date to use when the content has none: `download`, or `none` to leave the date out |
| `rename_folders` | `true` | Rename folders as well as files |
| `keep_folder_names` | `Chrome`, `Telegram Lite`, … | Folder names never to rename |
| `only_new_files` | `true` | Leave files that existed before install alone |
| `dry_run` | `false` | Log the suggested names without renaming |
| `poll_interval_seconds` | `5` | How often to check the folders |
| `settle_seconds` | `3` | How long a file must be unchanged before it is processed |
| `max_text_chars` | `20000` | How much text to send per file |
| `max_file_mb` | `25` | Skip files larger than this |

To change watched folders, run `./install.sh` again with the new folders.

## Use it manually

```bash
PY="$HOME/Library/Application Support/AIFileRenamer/venv/bin/python"
"$PY" ai_renamer.py --file ~/Downloads/scan001.pdf --dry-run   # preview the name
"$PY" ai_renamer.py --file ~/Downloads/scan001.pdf             # rename it
```

## Rename files that were already there

New files are renamed automatically. To also rename the files that were in the folders before you installed:

```bash
cd "$HOME/Library/Application Support/AIFileRenamer"
venv/bin/python ai_renamer.py --existing --dry-run --limit 20   # preview 20 names
venv/bin/python ai_renamer.py --existing                         # rename them all
venv/bin/python ai_renamer.py --add-dates                        # date names that have none (no API calls)
venv/bin/python ai_renamer.py --add-days                         # turn YYYY-MM names into YYYY-MM-DD
venv/bin/python ai_renamer.py --undo                             # put the old names back
```

Every rename is recorded in `renames.jsonl` in that folder, so `--undo` can restore a whole run. Files that already have a good name are left as they are, and a file is never processed twice.

## Logs

```bash
tail -f ~/Library/Logs/AIFileRenamer.log
```

## Change the API key

```bash
RESET_KEY=1 ./install.sh
```

The installer checks the key with the API before saving it.

## Uninstall

```bash
./uninstall.sh            # stop and remove the service, keep the config
./uninstall.sh --purge    # also remove the config, state, venv and Keychain key
```

## Privacy

The content of every new file in a watched folder is sent to the Anthropic API. Don't watch folders that hold documents you don't want sent there.
