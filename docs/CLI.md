# The `galdr` CLI

`galdr` brings Galdr's prompts, boxes and markdown renderer to shell scripts. Each verb asks one question or draws one thing. The answer goes to stdout, so `$(...)` captures it. The prompt itself is drawn on the terminal (`/dev/tty`), not on stdout, so capturing or piping never swallows the UI. Build it with `./build.sh`; the binary lands in `bin/galdr`.

```sh
branch=$(git branch --format='%(refname:short)' | galdr pick --header "Branch?")
galdr approve "Check out $branch?" && git checkout "$branch"
```

## Verbs

| Verb | Does | Prints |
|---|---|---|
| [`pick`](#pick) | choose one item (or several with `--multi`) from a list | the chosen item(s) |
| [`refine`](#refine) | choose one item by typing to fuzzy-filter | the chosen item |
| [`enter`](#enter) | read one line of text | the text |
| [`draft`](#draft) | read multi-line text | the text |
| [`approve`](#approve) | ask a yes/no question | nothing; the answer is the exit code |
| [`design`](#design) | draw text in a styled box | the box |
| [`md`](#md) | page or print a markdown file | the rendered file (print mode) |
| [`themes`](#themes) | show the built-in themes | a swatch per theme |

## Global options

### Arguments and flags

- Flags go after the verb, in any order, mixed with positional arguments: `galdr pick --header H a b c`.
- A flag takes its value as the next argument (`--header Title`) or after `=` (`--header=Title`).
- `--multi`, `--password`, `--print` and `--help` are switches. They take no value. Write `--multi`, not `--multi=true`; the `=` form is not recognized for switches.
- `--` ends the flags. Everything after it is positional. Use it when an item starts with `--`: `galdr pick --selected=--force -- --force --soft`.
- An unknown flag is an error: `galdr` names it on stderr and exits 2.
- A number flag (`--height`, `--width`, `--pad`) that does not parse as an integer falls back to its default.
- `galdr --help` (also `-h` or `help`) and `galdr VERB --help` print the usage summary to **stdout** and exit 0. `galdr` with no arguments and an unknown verb print it to **stderr** and exit 2.

### `--theme` and `GALDR_THEME`

`--theme NAME` picks the color theme: `nightfall` (default), `daybreak`, `ember`, `synth` or `moss`. `GALDR_THEME=NAME` does the same for every call; `--theme` wins when both are set. An unknown name falls back to `nightfall` without an error. `galdr themes` shows them all.

### `--color`

`--color auto|always|never` controls color in the output of `design`, `md` (print mode) and `themes`. It has no effect on the interactive prompts.

| Mode | Behavior |
|---|---|
| `auto` (default) | Color only when stdout is a terminal. Piped or captured output is plain text. |
| `always` | Always emit ANSI escapes. Uses the detected color depth, or 256 colors if the environment says none. This overrides `NO_COLOR`. |
| `never` | Plain text. |

### `NO_COLOR` and `TERM`

- A non-empty `NO_COLOR` turns color off, in prompts and in `auto` output. Bold and other attributes stay; highlighted parts use reverse video.
- Color depth is detected from the environment: `COLORTERM=truecolor` or `24bit`, and several known terminals (iTerm, WezTerm, Ghostty, kitty, Alacritty, VS Code, ...), get 24-bit color. `TERM=linux` gets 16 colors. Everything else gets 256.
- `TERM=dumb` **or an unset `TERM`** means the terminal cannot move the cursor. Prompts then fall back to plain line-by-line questions on `/dev/tty` (see below). `design`, `md` and `themes` print without color in `auto` mode.

### Without a terminal

Prompts need a controlling terminal (`/dev/tty`), not a terminal on stdin or stdout. `echo items | galdr pick` and `x=$(galdr enter)` both work interactively.

When `/dev/tty` cannot be opened (CI, cron, `ssh host cmd` without `-t`, detached jobs), each prompt answers from a flag instead:

| Verb | Flag that answers | Without it |
|---|---|---|
| `pick`, `refine` | `--selected ITEM` (must equal one of the items) | error, exit 2 |
| `enter`, `draft` | `--value TEXT` | error, exit 2 |
| `approve` | `--default yes\|no` (must be `yes` or `no`) | error, exit 2 |

The error names the flag to pass:

```console
$ galdr pick a b c
galdr: no interactive terminal; pass --selected to answer non-interactively
$ echo $?
2
```

With `TERM=dumb` (or unset) and a working `/dev/tty`, galdr asks plain questions on the terminal instead, and the answer flags above are **not** used as answers:

| Verb | Plain fallback |
|---|---|
| `pick` | Lists the items numbered from 1 and asks for a number. With `--multi`, asks for several numbers separated by spaces. Repeats on invalid input. |
| `refine` | Same as `pick` (no filtering). |
| `enter` | Prints the header (or the placeholder) followed by `: ` and reads a line. `--password` turns echo off. |
| `draft` | Reads lines until a line containing only `.`. |
| `approve` | Asks `Question? [Y/n]` (`[y/N]` with `--default no`). Accepts `y`, `yes`, `n`, `no`, any case; an empty line takes the default. |

End of input (ctrl+d on an empty line) in a plain prompt counts as a cancel (exit 130), except in `draft`, where it ends the text.

### Output

- The result goes to stdout followed by a newline. Nothing else is written to stdout.
- Errors and the usage text go to stderr.
- Prompts draw inline, under the shell prompt, and clean up after themselves. `md` without `--print` takes over the whole screen and gives it back on exit.
- In an interactive prompt, ctrl+z suspends galdr like any other program. `fg` brings it back.

### Diagnostics

Galdr never writes diagnostics to the terminal. `GALDR_LOG=path` sends its log to a file; `GALDR_TRACE=1` adds a line per event-loop iteration.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success. For `approve`: the answer was yes. |
| 1 | `approve` only: the answer was no. |
| 2 | Usage or input error: no verb, unknown verb, unknown flag, no items, `--selected` not among the items, unknown tone or border, `md` file missing or unreadable, no terminal and no answering flag, or the terminal could not be put in raw mode. |
| 130 | Cancelled: Esc or ctrl+c (and `q` in `pick` and `approve`), or end of input in a plain prompt. |

`approve` returning 1 means `set -e` scripts must test it with `if` or `&&`, not call it bare. A cancelled `$(galdr ...)` under `set -e` stops the script, which is usually what you want.

## pick

```
galdr pick [--header H] [--multi] [--height N] [--selected S] [--theme T] ITEM...
... | galdr pick [flags]
```

Shows a list and prints the chosen item. Items come from the arguments. With no arguments, they come from stdin, one per line; blank lines are dropped and other lines are kept as they are. If arguments are given, stdin is ignored.

With `--multi`, each item gets a checkbox. Enter prints every checked item on its own line, in list order. If nothing is checked, Enter prints nothing and exits 0.

| Flag | Default | Meaning |
|---|---|---|
| `--header H` | none | Bold line above the list. |
| `--multi` | off | Allow checking several items. |
| `--height N` | `10` | Visible rows. Capped at the number of items; longer lists scroll. |
| `--selected S` | none | The answer when there is no terminal. Must equal one item exactly, or galdr exits 2. It does not move the cursor in the interactive prompt. With `--multi`, it answers with that one item. |

Keys:

| Key | Action |
|---|---|
| ↑ `k` ctrl+p / ↓ `j` ctrl+n | Move |
| Home `g` / End `G` | First / last item |
| PgUp / PgDn | Move 8 rows |
| Enter | Choose (with `--multi`: confirm the checked items) |
| Space or `x` | `--multi` only: check or uncheck the current item |
| `a` | `--multi` only: check all; if all are checked, uncheck all |
| Esc, ctrl+c, `q` | Cancel (exit 130) |

Examples:

```sh
flavor=$(galdr pick vanilla chocolate strawberry)
```

```sh
# Several at once: one result per line.
galdr pick --multi --header "Remove which?" *.log |
  while IFS= read -r f; do rm -- "$f"; done
```

```console
$ printf 'main\n\ndev\nfeature/x\n' | galdr pick --selected dev
dev
$ galdr pick --selected z a b c
galdr pick: --selected "z" is not one of the items
$ echo $?
2
```

## refine

```
galdr refine [--header H] [--placeholder P] [--height N] [--selected S] [--theme T] ITEM...
... | galdr refine [flags]
```

Shows a query line above the list. Typing fuzzy-filters the items and ranks the best matches first; matched letters are underlined. A counter shows matches out of the total. Enter prints the highlighted item. Items come from the arguments or stdin, as for `pick`. Choose one item only; there is no `--multi`.

| Flag | Default | Meaning |
|---|---|---|
| `--header H` | none | Bold line above the query. |
| `--placeholder P` | `type to filter…` | Shown in the empty query line. |
| `--height N` | `10` | Visible result rows. Capped at the number of items. |
| `--selected S` | none | The answer when there is no terminal. Must equal one item exactly, or galdr exits 2. |

Keys:

| Key | Action |
|---|---|
| Any character | Add to the query |
| ↑ ctrl+p / ↓ ctrl+n | Move through the matches |
| PgUp / PgDn | Move 10 rows |
| Enter | Choose (does nothing when nothing matches) |
| Esc, ctrl+c | Cancel (exit 130) |
| ← → Home End, ctrl+a/e/b/f/w/u/k, Backspace, Delete | Edit the query, as in [`enter`](#enter) |

`j`, `k` and `q` are ordinary letters here: they go into the query. Pasted text is added to the query.

Examples:

```sh
file=$(git ls-files | galdr refine --header "Open which file?") && "$EDITOR" "$file"
```

```sh
# Kill a process by name.
pid=$(ps -eo pid=,comm= | galdr refine --placeholder "process…" | awk '{print $1}')
[ -n "$pid" ] && kill "$pid"
```

## enter

```
galdr enter [--header H] [--placeholder P] [--value V] [--password] [--theme T]
```

Reads one line of text and prints it. The result can be empty.

| Flag | Default | Meaning |
|---|---|---|
| `--header H` | none | Bold line above the field. |
| `--placeholder P` | `type something…` | Shown while the field is empty. |
| `--value V` | empty | Starts the field with this text. Also the answer when there is no terminal (`--value ""` answers with an empty line). |
| `--password` | off | Shows `•` for each character. The real text is still printed to stdout. |

Keys (readline-style):

| Key | Action |
|---|---|
| Enter | Accept |
| Esc, ctrl+c | Cancel (exit 130) |
| ← ctrl+b / → ctrl+f | Move one character |
| alt+← ctrl+← / alt+→ ctrl+→ | Move one word |
| Home ctrl+a / End ctrl+e | Start / end of line |
| Backspace / Delete ctrl+d | Delete before / under the cursor |
| ctrl+w, alt+Backspace | Delete the word before the cursor |
| ctrl+u / ctrl+k | Delete to the start / end of the line |

Pasted newlines and tabs become spaces.

Examples:

```sh
name=$(galdr enter --header "Your name" --placeholder "Ada Lovelace")
```

```sh
token=$(galdr enter --password --header "API token") || exit 1
```

```console
$ galdr enter --value hello
hello
```

## draft

```
galdr draft [--header H] [--placeholder P] [--height N] [--value V] [--theme T]
```

A multi-line editor with line numbers. ctrl+d saves and prints the text. Enter starts a new line.

| Flag | Default | Meaning |
|---|---|---|
| `--header H` | none | Bold line above the editor. |
| `--placeholder P` | `write something…` | Shown while the editor is empty. |
| `--height N` | `8` | Rows of text visible. Longer text scrolls. |
| `--value V` | empty | Starts the editor with this text (it may contain newlines). Also the answer when there is no terminal. |

Keys:

| Key | Action |
|---|---|
| ctrl+d | Save and print |
| Esc, ctrl+c | Cancel (exit 130) |
| Enter | New line |
| Tab | Insert 4 spaces |
| ← → ↑ ↓, ctrl+b/f/p/n | Move |
| alt+← ctrl+← / alt+→ ctrl+→ | Move one word |
| Home ctrl+a / End ctrl+e | Start / end of line |
| ctrl+Home / ctrl+End | Start / end of text |
| PgUp / PgDn | Move one screen |
| Backspace / Delete | Delete before / under the cursor, joining lines at the edges |
| ctrl+u / ctrl+k | Delete to the start / end of the line (ctrl+k at the end joins the next line) |

Examples:

```sh
notes=$(galdr draft --header "Release notes" --height 12)
```

```console
$ galdr draft --value "$(printf 'feat: add login\n\nUses OAuth.')"
feat: add login

Uses OAuth.
```

## approve

```
galdr approve [--default yes|no] [--affirmative LABEL] [--negative LABEL] [--theme T] [QUESTION...]
```

Asks a yes/no question with two buttons. Prints nothing. The answer is the exit code: 0 for yes, 1 for no, 130 for cancel. All positional arguments are joined with spaces to form the question, so quoting is optional. With no question, it asks `Are you sure?`.

| Flag | Default | Meaning |
|---|---|---|
| `--default yes\|no` | `yes` | The button highlighted at the start. Also the answer when there is no terminal. Must be exactly `yes` or `no` (any case); any other value is a usage error, exit 2 — a misspelled default is never silent consent. |
| `--affirmative LABEL` | `Yes` | Label of the yes button. |
| `--negative LABEL` | `No` | Label of the no button. |


Keys:

| Key | Action |
|---|---|
| ← → Tab `h` `l` | Switch between the buttons |
| Enter | Accept the highlighted button |
| `y` `Y` / `n` `N` | Answer yes / no at once |
| Esc, ctrl+c, `q` | Cancel (exit 130) |

Examples:

```sh
galdr approve "Deploy to production?" && ./deploy.sh
```

```sh
if galdr approve --default no --affirmative Delete --negative Keep "Delete $dir?"; then
  rm -rf -- "$dir"
fi
```

```console
$ galdr approve --default no "Deploy?"; echo $?
1
$ galdr approve --default yes "Deploy?"; echo $?
0
```

## design

```
galdr design [--tone T] [--border B] [--pad N] [--width N] [--align A] [--title T] [--theme T] [--color C] LINE...
... | galdr design [flags]
```

Draws text in a box and prints it. It never prompts, so it works the same with or without a terminal. Each argument is one line. With no arguments, lines come from stdin (blank lines are dropped). With no lines at all, it draws an empty box. The text is bold, in the tone's color; so is the border.

| Flag | Default | Meaning |
|---|---|---|
| `--tone T` | `primary` | `neutral`, `primary`, `secondary`, `accent`, `info`, `success`, `warning` or `danger`, any case. Anything else exits 2. |
| `--border B` | the theme's: `rounded`, or `sharp` for ember, `double` for synth | `none`, `rounded`, `sharp` (or `normal`), `thick`, `double`, `dashed`, `heavy-dashed`, `block`, `half` (or `inner-half`), `ascii`. Anything else exits 2. |
| `--pad N` | `1` | Spaces left and right of the text. Blank rows above and below are `N/2`, rounded down, so `--pad 1` adds none. |
| `--width N` | widest line | Width of the text area inside the padding. Longer lines are cut with `…`. |
| `--align A` | `left` | `left`, `center` or `right`. Any other value means left. |
| `--title T` | none | Title set into the top border. |

Examples (captured output, so no color):

```console
$ galdr design "Hello, Ada"
╭────────────╮
│ Hello, Ada │
╰────────────╯
```

```console
$ galdr design --border double --pad 2 --align center --width 30 "Build passed" "12 tests, 0 failures"
╔══════════════════════════════════╗
║                                  ║
║           Build passed           ║
║       12 tests, 0 failures       ║
║                                  ║
╚══════════════════════════════════╝
```

```console
$ galdr design --border ascii --title Status "all good"
+- Status -+
| all good |
+----------+
```

## md

```
galdr md [--print] [--width N] [--theme T] [--color C] FILE
```

Renders a markdown file. It covers headings, paragraphs with bold, italic, code, strikethrough and links, bullet, numbered and task lists, block quotes, fenced code, rules and pipe tables.

- **Pager** (stdout is a terminal, no `--print`): full screen, with the file name in the header and the scroll position in the footer. Text is centered, at most 100 columns wide, and re-wraps when the window is resized. `--width` is ignored. Exits 0 on quit.
- **Print** (`--print`, or stdout is not a terminal): writes the rendered file to stdout, wrapped to `--width` columns. Color follows `--color`.

`FILE` is required and must be a regular file; galdr does not read markdown from stdin (`/dev/stdin` is rejected). A missing or unreadable file exits 2.

| Flag | Default | Meaning |
|---|---|---|
| `--print` | off (on when stdout is not a terminal) | Print instead of paging. |
| `--width N` | `80` | Wrap width in print mode. |

If the pager cannot start (for example `TERM=dumb`), galdr prints the file instead, at 80 columns, ignoring `--width`.

Pager keys:

| Key | Action |
|---|---|
| ↑ `k` / ↓ `j` | Scroll one line |
| PgUp `b` / PgDn Space `f` | Scroll one page |
| `u` / `d` | Scroll half a page |
| Home `g` / End `G` | Top / end |
| Mouse wheel | Scroll 3 lines |
| `t` | Next theme |
| `q`, Esc, ctrl+c | Quit |

Examples:

```sh
galdr md README.md                # page it
galdr md --print CHANGELOG.md | head -40
```

```console
$ galdr md --print --width 50 notes.md
 RELEASE NOTES

Version 1.4 adds --dry-run and fixes two bugs.

• faster startup
☑ docs updated

 Flag │ Meaning
──────┼────────
 -n   │ dry run
```

## themes

```
galdr themes [--color C]
```

Prints one three-line swatch per built-in theme: the name, one block of color per tone (neutral through danger), and whether it is dark or light. It shows every theme, so `--theme` has no effect. The swatches are background colors: without color (piped, `--color never`, `NO_COLOR`) only the names and `dark`/`light` remain.

```sh
galdr themes                 # look at them
GALDR_THEME=ember galdr pick a b c
```

## Recipes

### Commit helper

Pick the type, write the message, confirm, commit.

```sh
#!/bin/sh
set -e
type=$(galdr pick --header "Commit type" feat fix docs refactor test chore)
scope=$(galdr enter --header "Scope (optional)" --placeholder "api, ui, …")
summary=$(galdr enter --header "Summary" --placeholder "what changed")
body=$(galdr draft --header "Details (ctrl+d when done)" --height 6)

subject="$type${scope:+($scope)}: $summary"
galdr design --tone info --title Commit "$subject"
galdr approve "Commit this?" || exit 0
if [ -n "$body" ]; then
  git commit -m "$subject" -m "$body"
else
  git commit -m "$subject"
fi
```

### Switch branch

```sh
#!/bin/sh
branch=$(git branch --format='%(refname:short)' | galdr refine --header "Switch to") || exit 0
git switch "$branch"
```

### Deploy with a safe default

The same script works by hand and in CI. In CI there is no terminal, so `--default` answers; it is `no` unless the job opts in.

```sh
#!/bin/sh
env=$(galdr pick --header "Deploy where?" --selected "${DEPLOY_ENV:-staging}" staging production) || exit $?
if [ "$env" = production ]; then
  galdr approve --default "${CONFIRM_PROD:-no}" --affirmative Deploy --negative Abort \
    "Deploy $(git rev-parse --short HEAD) to production?" || { echo "aborted"; exit 1; }
fi
galdr design --tone success "Deploying to $env"
./deploy.sh "$env"
```

### Clean up branches

Check several merged branches, delete them after one confirmation.

```sh
#!/bin/sh
gone=$(git branch --merged main --format='%(refname:short)' | grep -vx main |
       galdr pick --multi --header "Delete which merged branches?") || exit 0
[ -n "$gone" ] || exit 0
galdr approve --default no "Delete $(echo "$gone" | wc -l | tr -d ' ') branches?" &&
  echo "$gone" | xargs git branch -d
```
