# omarchy-backup

Saves your [Omarchy](https://omarchy.org/) setup (configs, customizations, installed packages, enabled services) into one file, and puts it all back on a fresh install.

It lives in the Omarchy menu under **System > Omarchy Backup**:

| Row | What it does |
|---|---|
| **Back Up Now** | Saves a backup to `~/Backups/omarchy/` |
| **Restore** | Picks a backup, lets you choose what to restore, and restores it |
| **Saved Backups** | Lists your backups and undo files |
| **Open Backup Folder** | Opens `~/Backups/omarchy/` in the file manager |

## What a backup holds

- **Config files that differ from a fresh install.** Omarchy puts the same files into every new home folder (`/etc/skel`): `~/.config/hypr`, `~/.config/omarchy` (menu extensions, hooks, branding, `shell.json`, your themes and backgrounds), the terminal configs, `~/.bashrc`, and more. omarchy-backup compares yours with those defaults and saves only what you changed or added. It also saves the uwsm environment, `environment.d`, your systemd user units, autostart entries, default apps (`mimeapps.list`), fontconfig, mise, web apps and TUI launchers with their icons, your own fonts, and Omarchy's settings in `~/.local/state/omarchy` (toggles, default apps, weather location, power profiles, workspace layouts). The full list is in [`share/paths`](share/paths).
- **App settings:** everything else in `~/.config`, such as VSCodium's `settings.json`, LibreOffice, Inkscape, Pinta, gh, omamail, Spotify and your own apps' configs. Browser profiles, Signal, caches, and files holding logins are left out (see below).
- **Editor extensions and GNOME/GTK app settings:** the extension lists of VSCodium, VS Code, Cursor and Windsurf, installed again by name on restore, and the settings apps keep in dconf (Nautilus, Evince, the file chooser), saved as text with `dconf dump`.
- **Claude Code configuration:** `~/.claude/settings.json`, your `CLAUDE.md`, skills, agents, commands, hooks, themes, the list of installed plugins and their marketplaces (a restore installs the plugins again), and the memory of every project (`~/.claude/projects/*/memory`). Your login, chats, prompt history and `~/.claude.json` (account details and caches) stay out; skills synced from your claude.ai account come back when you sign in.
- **Your scripts in `~/.local/bin`**, and the mise tools listed in `~/.config/mise/config.toml` (Omarchy installs Claude Code, Codex, gh and Node this way). A restore installs those tools again.
- **Default launchers you deleted**, such as web apps or autostart entries. A restore deletes them again.
- **Themes and shell plugins installed from git** (`omarchy theme install`, `omarchy plugin add`, such as omamail), as their URL and commit plus any files you changed in them. A restore clones them again, because Omarchy treats a theme with a `.git` folder as third-party and won't run its Lua or terminal configs. Copying the files alone would drop that protection. Which plugins are on, and where their bar widgets sit, is kept in `~/.config/omarchy/shell.json`, which is saved too.
- **The theme, background and font**, by name.
- **Packages:** everything you installed explicitly from the Arch and Omarchy repos, AUR packages, Flatpak apps, and the Omarchy default packages you uninstalled.
- **Enabled system and user services, your groups and your timezone.**
- **System drop-ins in `/etc` that no package owns**, such as logind and sleep drop-ins, modprobe options, sysctl settings, udev rules and keyd. Files that need root to read are skipped with a warning; the backup itself never asks for sudo.

It doesn't save browser profiles (browser sync brings them back), Signal's messages and keys, TeamViewer's machine ID, SSH or GPG keys, keyrings, or the documents in your home folder. It also leaves out logins: files whose names contain `credentials`, `token`, `secret` or `password`, `*.pem` files, `~/.config/gh/hosts.yml`, and Claude's login. Files over 100 MB are skipped with a warning. Omarchy's own packages (`omarchy`, `omarchy-settings`) aren't restored either, since they follow the channel; the restore tells you if the backup came from another channel.

## The backup file

A backup is one file, `~/Backups/omarchy/omarchy-backup-<host>-<date>.tar.zst`. It is a zstd-compressed tar archive:

- `manifest.json` comes first. It is plain JSON: packages, services, theme, font, the list of saved files and git repos.
- `home/...` holds the saved files from your home folder, and `system/etc/...` the files from `/etc`.

Print the manifest with `omarchy-backup show <file> --json`, or `tar --zstd -xOf <file> manifest.json | jq`.

It is an archive rather than a single JSON file so that binary files (fonts, backgrounds, icons) keep their bytes, modes and symlinks, and it stays small: about 1 MB for a typical setup. Only you can read the file (mode 600). It holds your configs as they are, including `~/.config/git/config`, so keep it private.

## Install

### From the AUR

Not published yet: new AUR account registration is paused (as of 2026-09-26). Once it's there:

```sh
omarchy pkg aur add omarchy-backup      # or: yay -S omarchy-backup
```

**System > Omarchy Backup** appears in the Omarchy menu at your next login. To add it right away, open **Omarchy Backup** from the app launcher, or run `omarchy-backup setup`.

### Build the package yourself

makepkg downloads the tagged release from GitHub and checks it against the checksum in the PKGBUILD:

```sh
git clone https://github.com/popovoleksandr/omarchy-backup.git
cd omarchy-backup/packaging/aur
makepkg -si
```

### From a checkout

Without the package, run it straight from the repository. `setup` adds the menu rows pointing at the checkout:

```sh
git clone https://github.com/popovoleksandr/omarchy-backup.git ~/Projects/omarchy-backup
~/Projects/omarchy-backup/bin/omarchy-backup setup
```

### Requirements

- Omarchy 4 (tested on 4.0.4), whose menu reads `~/.config/omarchy/extensions/omarchy-menu.jsonc`.
- bash, jq, tar, zstd, gum, git and curl. Omarchy has all of them; the package depends on them.
- yay for AUR packages, and flatpak for Flatpak apps. Omarchy ships yay; a restore installs flatpak if the backup has Flatpak apps.

## Restoring on a fresh install

1. Install Omarchy, log in and connect to the network.
2. Copy the backup file onto the machine: plug in the USB drive (it mounts under `/run/media/<you>/`) or download it to `~/Downloads`.
3. Install omarchy-backup (see [Install](#install)).
4. Open **System > Omarchy Backup > Restore**, or run `omarchy-backup restore`. Pick the backup from the list; it finds backups in `~/Backups/omarchy`, `~/Downloads`, your home folder and USB drives, or you can browse to one.
5. Tick what to restore, confirm, and enter your sudo password once when asked.
6. Reboot.

The steps run in this order:

| Step | Default | What it does |
|---|---|---|
| `packages` | on | Installs the missing repo packages with pacman. You can review and untick packages first, such as another machine's GPU drivers. Names that no longer exist are listed at the end. |
| `aur` | on | Installs the missing AUR packages with yay. Packages that moved to the official repos come from there. Packages the AUR doesn't know, like ones you built from a file, are listed for you to install yourself. |
| `flatpak` | on | Installs the missing Flatpak apps, adding Flathub if needed. |
| `repos` | on | Clones the git themes and plugins at their saved commit, then puts back your changes to them. New shell plugins are checked with `omarchy plugin validate` and the running shell rescans them, as `omarchy plugin add` does. |
| `files` | on | Puts back the saved config files and deletes the default launchers you had deleted. Symlinks into the old home folder are pointed at the new one. |
| `tools` | on | Runs `mise install` for the tools in the restored `~/.config/mise/config.toml`, such as claude, codex, gh and node. Without this step, Omarchy's launchers install each one the first time you run it. |
| `claude` | on | Adds the Claude Code plugin marketplaces and installs your plugins again with `claude plugin install`. The saved plugin list alone points at plugin files a new machine doesn't have, so Claude would show them as "failed to load". |
| `apps` | on | Loads the GNOME/GTK app settings with `dconf load` (it sets the saved keys and leaves the rest) and installs the missing editor extensions, then lists any the editor's marketplace doesn't have. |
| `etc` | off | Installs the saved `/etc` drop-ins as root, then reloads systemd, udev and sysctl. |
| `look` | on | Sets the theme, then the background and the font. |
| `system` | on | Enables the services that were enabled, adds you to the groups you were in, and sets the timezone. It only enables; it never disables anything. |
| `prune` | off | Uninstalls the Omarchy default packages you had uninstalled. |

Before a restore replaces or deletes a file, it saves the current one. At the end it packs those into an undo file, `~/.local/state/omarchy-backup/undo-<date>.tar.zst`. `omarchy-backup restore <undo file>` puts them back. Files the restore added, where there was nothing before, stay.

Restoring twice is safe: files that already match, packages already installed and repos already cloned are skipped.

## Command line

```
omarchy-backup create [-o <file|folder>] [--full]
omarchy-backup restore [<file>] [--only <steps>] [--skip <steps>] [--dry-run] [--yes]
omarchy-backup show <file> [--json]
omarchy-backup list
omarchy-backup open
omarchy-backup setup | unsetup | menu
```

- `create --full` also saves files that still match Omarchy's defaults, for a complete snapshot of those folders.
- `restore --dry-run` prints what each step would do and changes nothing. Combine it with `--only` to check one step, for example `--dry-run --only files`.
- `restore --only packages,aur` or `--skip look` choose the steps without the checklist; steps are comma-separated.
- `restore --yes` runs the default steps without asking, which is useful from a script.

## Choosing what's saved

Add lines to `~/.config/omarchy-backup/paths`, in the same format as [`share/paths`](share/paths):

```
include ~/.config/VSCodium/User/settings.json
include ~/.config/omarchy-aum-logo
exclude ~/.config/omarchy/backgrounds/*.mp4
```

An `include` is a file or a folder in your home folder or in `/etc`, or a pattern such as `~/.claude/projects/*/memory`. A file named on its own in an include is saved even when an exclude matches it; that is how you keep a login you do want, such as `include ~/.config/gh/hosts.yml`. From `/etc`, a folder's files are saved only if no package owns them, while a single file you name is saved in any case. An `exclude` is a path or a pattern, where `*` also matches across `/`. This file itself is part of every backup.

Backups go to `~/Backups/omarchy`. To change that, put `BACKUP_DIR=~/somewhere/else` into `~/.config/omarchy-backup/config`. `MAX_FILE_MB=500` there raises the size limit for single files (`0` removes it).

## Removing

```sh
omarchy-backup unsetup                 # System > Omarchy Backup out of the menu
omarchy pkg drop omarchy-backup        # or: sudo pacman -R omarchy-backup
```

If the package is already gone, the menu row has hidden itself: it only shows while `omarchy-backup` is installed. Your backups stay in `~/Backups/omarchy`.

## How it works

- **Finding customizations.** `create` walks everything `/etc/skel` puts in a new home folder, plus the includes, and compares each file byte for byte with its `/etc/skel` copy. A `.git` folder marks a git repo, which is saved by its `origin` URL, commit and `git status` changes instead.
- **Menu.** The Omarchy menu reads a single user file, `~/.config/omarchy/extensions/omarchy-menu.jsonc`, so `setup` inserts a block between `// >>> omarchy-backup >>>` and `// <<< omarchy-backup <<<`. It checks that the file still parses before writing, and keeps a copy of the previous version as `omarchy-menu.jsonc.bak.omarchy-backup`. The package also adds a login autostart entry (`/etc/xdg/autostart/omarchy-backup-menu.desktop`) that runs `omarchy-backup setup --auto`, which adds or refreshes the block unless you ran `unsetup`.
- **sudo.** Creating a backup never needs root. A restore asks for sudo once, and only when a selected step needs it: packages, AUR, Flatpak, `/etc`, services, groups, timezone, or prune (and tools, if mise itself is missing).

## Files

| File | Purpose |
|---|---|
| `bin/omarchy-backup` | The command: option parsing, `show`, `list`, `open` |
| `lib/create.sh` | Making a backup |
| `lib/restore.sh` | The restore steps |
| `lib/menu.sh` | Adding and removing the menu block |
| `lib/common.sh` | Shared paths and helpers |
| `share/paths` | What gets saved by default |
| `share/menu.jsonc` | The System > Omarchy Backup block (`@CMD@` becomes the command) |
| `share/omarchy-backup.desktop`, `share/omarchy-backup.svg` | App launcher entry and icon |
| `share/omarchy-backup-menu.desktop` | The login autostart entry that keeps the menu block in place |
| `tests/run.sh` | Backs up a made-up home folder and restores it into a fresh one (`make test`) |
| `Makefile` | `make DESTDIR=… PREFIX=/usr install`, used by the PKGBUILD |
| `packaging/aur/` | PKGBUILD, install messages, and the release scripts ([how to publish](packaging/aur/README.md)) |

## Tested

Tested on 2026-09-26 with Omarchy 4.0.4 (stable), gum 2.0.0, GNU tar 1.35, zstd 1.5.7 and yay 13.0.1.

- Verified: `create` on a real, customized Omarchy 4.0.4 install took 6 seconds and made a 1.4 MB backup: 183 files (8 changed, 175 added, including the settings of 20 apps, Claude Code's settings, plugin list and memory files), the omamail plugin repo, 3 `/etc` drop-ins, 184 repo and 5 AUR packages, 20 VSCodium extensions, dconf settings, and 44 enabled services. The archive holds no browser profile, Signal data, cache folder, credentials file, gh token, Claude login, chat or `~/.claude.json`.
- Verified: a dry run of the apps step on this machine finds all 20 VSCodium extensions installed and would load 8 dconf sections.
- Verified: restoring that backup into a home folder freshly copied from `/etc/skel` reproduced all 85 files byte for byte, with the same modes. Symlinks into the old home folder pointed into the new one. A second restore changed nothing. Restoring the undo file put Omarchy's defaults back.
- Verified: a dry run of every step against the machine the backup came from reported nothing to do. A dry run of a backup edited to hold missing, unknown and moved packages, an unknown AUR name, a Flatpak app, a git theme, a disabled service, a new group, another timezone, another theme, a missing font and another channel took the right action for each, and listed the problems at the end.
- Verified: the interactive restore through a terminal: the checklist starts with the right steps ticked and honors `--skip`, and the package review defaults to no.
- Verified: `tests/run.sh` (64 checks) covers changed, added, untouched, excluded, oversized and removed files, symlinks, a git theme with local changes cloned from a local repository, extra and pattern includes, what's kept out of `~/.claude`, the mise tools step, Claude plugins (user scope only), an Omarchy plugin from git, app settings with caches, logins and Signal left out, a login saved on purpose, editor extensions (including one the marketplace lacks) and dconf, backups with unsafe paths, undo, and adding and removing the menu block.
- Verified: a dry run of the tools step on this machine lists claude, codex, gh and node and would run `mise install`.
- Verified: a real restore of the `repos`, `files` and `claude` steps into a fresh home cloned the omamail shell plugin from GitHub at its saved commit, and `claude plugin list` there shows rust-analyzer-lsp enabled. In a separate fresh home holding only the restored plugin list, Claude reported the plugin as "failed to load" until `claude plugin install` downloaded it again.
- Verified: the menu block parsed with Omarchy's own `MenuModel.js` lands under System, after Shutdown, next to existing extension entries.
- Verified: `makepkg` builds the package from the working tree.
- Not yet verified: a full restore on a real fresh install, where pacman, yay and flatpak actually install packages; and clicking the menu rows in a live session.

## License

[MIT](LICENSE)
