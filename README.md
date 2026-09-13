# insh

`insh` keeps encrypted environment variables in Git and loads them into your
shell. A **profile** selects a backend repository and a master key. Within a
profile, **namespaces** provide ordered layers of environment variables.

One binary, with `git` as its only runtime dependency. Shell integration supports
Bash, Zsh, Fish, and Nushell.

## Install

Requires Zig 0.16.0 to build:

```sh
zig build -Doptimize=ReleaseSafe --prefix ~/.local
```

Put `~/.local/bin` on your `PATH`. Use ReleaseSafe to retain runtime checks.

## Set up a profile

Create a private GitHub repository and a PAT with Contents read/write access,
then initialize the default profile:

```sh
insh init
insh add --type env --key API_KEY
insh add -n company --type env --key SHARED_TOKEN
insh add -n project1 --type env --key API_KEY
insh sync
```

`add` prompts with input hidden. For scripts, use `--stdin`. Secret values are
never accepted as command-line arguments. Writes are encrypted immediately and
stay local until `sync`. Namespaces are created by their first write.

Configure another backend with its own key:

```sh
insh profile create work
# Equivalent: insh --profile work init

insh profile default work
insh --profile work add -n project1 --type env --key API_KEY
```

`profile create` uses the same repo/PAT prompts and key-import options as `init`.
Each profile has independent credentials, encrypted cache, and pending changes.
Profile names and defaults are local to each machine. Namespaces and their keys
and values travel together in the profile's encrypted Git backend.

## Enable shell integration

Add the matching line to your shell startup file. Use the binary's absolute path
if it is not yet on your `PATH`.

| Shell | Startup configuration |
| --- | --- |
| Bash | Add `eval "$(insh shell-init bash)"` to `~/.bashrc`. |
| Zsh | Add `eval "$(insh shell-init zsh)"` to `~/.zshrc`. |
| Fish | Add `insh shell-init fish \| source` to `~/.config/fish/config.fish`. |
| Nushell | Run `insh shell-init nu \| save -f ~/.config/nushell/insh.nu` once, then add `source ~/.config/nushell/insh.nu` to `config.nu`. Regenerate the file if you move the binary. |

The startup integration loads the saved default profile and its default layers.
It defines an `insh` shell function so activation can change the current shell.
Without integration, activation commands fail with setup guidance. Other commands
work directly from the binary.

## Compose namespaces

```sh
insh profile use work
insh activate company project1
insh status
```

Precedence runs from lowest to highest:

```text
original shell environment -> profile globals -> company -> project1
```

Globals overwrite existing shell values. Later namespaces overwrite earlier
ones. Keys unique to any selected layer remain available. Activation replaces
the previous namespace selection:

```sh
insh activate project2       # globals + project2; company/project1 are removed
insh activate --global      # globals only
insh activate               # refresh the current selection
insh deactivate             # remove insh's applied environment
```

Activation uses the encrypted local cache plus pending changes, without a network
request. Adding or syncing values does not refresh running shells. Reactivate
explicitly to load the latest local values.

Unknown namespaces, invalid profiles, corrupt data, and authentication failures
leave the terminal unchanged. A deleted override falls back to the next layer.

Switching or deactivating restores the previous value of keys that still match
what insh applied, or unsets them if they were originally absent. Manual edits
and manual unsets survive cleanup. An explicit activation overwrites selected
keys even when they were manually edited, and remembers those edits for the
next restoration. Equality is the test: an edit to the same value as insh's
applied value is indistinguishable from no edit.

The restoration snapshot covers exported environment variables. Unexported
shell variables are outside that snapshot. Nushell environment values are
restored in their external string form; `PATH` is converted back to a list.

## Profile selection and defaults

Every command selects its profile in this order:

1. An explicit `--profile NAME`, before or after the command.
2. The current terminal's active profile.
3. The machine's saved default, initially named `default`.

```sh
insh profile use work        # this terminal only; loads work's default layers
insh profile default home   # fresh terminals; does not change this one
insh --profile work profile defaults company project1
insh --profile work profile defaults   # clear default layers to globals only
insh profile list
```

Switching profiles cleans up the previous profile's environment before applying
the new profile's globals and default layers. Each terminal has independent
activation state. A child shell inherits the current environment; if it runs the
startup integration, it restores inherited insh values before loading the saved
default. Deactivation leaves the terminal's profile selection in place for
subsequent writes.

Unqualified writes always target globals in the selected profile, regardless of
active namespaces. Namespace writes require `-n`:

```sh
insh add --type env --key GLOBAL_TOKEN
insh add -n project1 --type env --key API_KEY
insh --profile home add -n project1 --type env --key API_KEY
```

Profile names use ASCII letters, digits, underscores, and hyphens, starting with
a letter or digit, up to 64 characters. Namespace names accept those components
separated by `/`, up to 128 characters total. `project1/prod` is a literal name
with no automatic inheritance. `global` is reserved; omit `-n` to write globals.

## Inspect and remove keys

```sh
insh namespace list
insh status
insh status -n company -n project1
insh remove -n project1 --type env --key API_KEY
insh sync
```

`status` shows the selected profile, ordered layers, and the source of each
available key. It includes pending changes and never prints values. It describes
what the next activation will load, not whether a running shell has refreshed.

`remove` stages an explicit encrypted deletion for one namespace/key pair.
Deleting a namespaced override reveals a global or earlier-layer value. Deleting
a global key does not remove namespaced versions. Removing the last key retains
the namespace's identity, so it can still be selected as an empty layer.

`edit` opens the selected profile's `config.yaml` with `$EDITOR`. The legacy
`env:` list is informational. Removing names from that list no longer deletes
backend secrets. Use `remove` for deletion and `profile defaults` for selection.

## Sync and multiple machines

`sync` fetches all namespaces from the selected profile's backend, applies its
pending operations, encrypts and pushes the result, then updates the local
cache. Locally staged operations win over fetched values for the same
namespace/key pair. No key is deleted merely because a local config omits it.

Each profile permits one local operation at a time. A concurrent invocation
fails with `ProfileBusy` and can be retried. Git rejects a concurrent remote
update instead of force-pushing it. Pending values and deletions survive a
failed push and are retried on the next sync. Successful syncs also write
profile-local `env.sh`, `env.fish`, and `env.nu` compatibility files containing
globals only. Use shell integration for namespace activation and restoration.

To configure another machine, transfer the profile's master key through a
trusted channel and initialize a profile against the same repository:

```sh
insh --profile work init --key-file /path/to/work-master.key
insh --profile work sync
```

For a password manager that stores text:

```sh
insh --profile work export-key
# On the other machine:
insh --profile work init --key-prompt
```

`export-key` prints the secret key as 64 hexadecimal characters. `--key-prompt`
accepts that format through a hidden interactive prompt. `--key-file` accepts
exactly 32 raw bytes. Importing a different key over an existing one requires
`--force`; deactivate the profile before replacing its key. A different backend
belongs in another profile. Sync refuses a cached Git remote that differs from
its profile configuration.

## Migration from 0.1

The first storage command automatically moves the legacy installation into the
`default` profile. Master key bytes, PAT, config, staged values, the backend
clone, and generated env files are preserved. The migration can resume after
interruption and refuses to overwrite an existing `default` profile.

Replace old `source ~/.inshtaller/env.*` startup lines with the shell integration
above. Generated env files now live inside the profile directory.

Existing backend values become globals. The first successful sync writes the
new authenticated format. **Upgrade every machine using the backend before
syncing with this version.** Version 0.1 cannot decrypt the new format and will
fail authentication rather than prune the backend. Downgrading after that sync
requires restoring an older backend revision and the former local layout;
keep the current version when continuing to use profiles or namespaces.

## Storage and security

```text
~/.inshtaller/
├── default-profile
└── profiles/
    └── work/
        ├── config.yaml          repo URL and legacy key-name list, no values
        ├── master.key           32 bytes, mode 0600
        ├── github_token         mode 0600
        ├── default-layers.json  ordered namespace names, local only
        ├── pending/*.enc        encrypted writes and deletions
        ├── cache.enc            encrypted state after a successful sync
        ├── .state/              local Git clone containing secrets.enc
        └── env.{sh,fish,nu}     plaintext global exports, mode 0600
```

The backend contains one `secrets.enc` file. Its encrypted JSON holds namespace
names, key names, values, and deletion records. XChaCha20-Poly1305 authenticates
the payload with a 32-byte key and a fresh 24-byte nonce. The v2 envelope starts
with `INSH2` and a newline, and uses authenticated associated data `insh:v2`.
Legacy blobs using `insh:v1` remain readable by the new client.

All namespaces in a profile share its key. Anyone holding that key and the
backend data can read every namespace. Use separate profiles, repositories, and
keys for separate access. Profiles do not enforce access boundaries between
processes running as the same operating-system user.

The PAT is provided to Git through a profile-aware `GIT_ASKPASS`, never in argv
or remote URLs. The master key never enters the Git backend. Values are not
written to logs or status output. Generated compatibility files contain plaintext
and have mode 0600. Profile storage directories are created with mode 0700.

Shell integration exports `INSH_PROFILE` and `INSH_NAMESPACES` as selection
metadata. `INSH_HOME` pins the storage location even if a namespace changes
`HOME`. `INSH_STATE` contains an encrypted restoration snapshot, authenticated
with the profile key named by `INSH_STATE_PROFILE`. It is inherited by child
processes. Encoded restoration state is limited to 64 KiB; an oversized
activation fails before modifying the shell. Restoring requires the old
profile's key to remain available.

Keys must be valid environment names and values must be UTF-8 without NUL.
`INSH_*`, `__insh_*`, and shell execution/state variables such as `IFS`,
`BASH_ENV`, `PWD`, and `ENV_CONVERSIONS` are reserved. Quoting preserves spaces,
quotes, dollar signs, and embedded newlines. Input handling trims leading and
trailing CR/LF, as in 0.1. Keep shell tracing disabled when handling secrets;
the Bash, Zsh, and Fish wrappers suppress tracing while applying values.

Lost master keys cannot be recovered from the backend. Back them up through a
trusted channel. Revoke a leaked PAT and replace the profile's `github_token`.
Master-key rotation is not automated.

## Development

```sh
zig fmt --check src build.zig
zig build test
zig build integration
zig build -Doptimize=ReleaseSafe
```

`test` runs Zig unit tests. `integration` builds the binary and runs Python 3
acceptance tests with Bash, Zsh, Fish, and Nushell installed. Tests use temporary
homes and local bare Git repositories, without real credentials or network
access. They cover profile isolation, layered activation, manual edits,
migration, multi-machine sync, explicit deletion, and failure recovery.

The implementation separates profile paths/migration in `profiles.zig`, encrypted
namespace data in `secrets.zig`, argument/default selection in `selection.zig`,
and terminal transitions in `activation.zig`. Shell providers own quoting;
`shell/` holds the integration functions. CLI commands coordinate these modules.

## License

MIT. See [LICENSE](LICENSE).
