# insh — feel at home on every server

`insh` is a small Zig CLI for keeping a personal set of encrypted env vars in
sync across every machine you work on. Point it at a **private** GitHub repo
you own, drop your master key on each machine once, and you get a single
command — `insh sync` — that pushes any new vars you've staged and pulls the
rest down as a shell-sourceable file.

It is intentionally tiny: one binary, zero runtime dependencies other than
`git`, no passphrases to remember, no background daemons.

---

## How it works

```
           ┌───────────────────┐       push / pull        ┌──────────────────┐
           │ ~/.inshtaller/    │  ── git (HTTPS + PAT) ──▶│ private GitHub   │
  you ────▶│   master.key      │                          │ repo             │
           │   github_token    │                          │   secrets.enc    │
           │   config.yaml     │                          │   (ciphertext)   │
           │   pending/*.enc   │                          └──────────────────┘
           │   env.sh          │
           └───────────────────┘
```

- The **master key** is generated on `insh init` and never leaves the device.
  It encrypts every env var value using XChaCha20-Poly1305.
- The **GitHub PAT** is stored locally (0600) and injected into `git` via
  `GIT_ASKPASS` — it never appears in argv, URLs, or logs.
- The backend repo stores **one file**, `secrets.enc`: a single authenticated
  ciphertext containing all your env vars. Anyone with read access to the repo
  sees only an opaque blob.
- `config.yaml` stores **key names only**. Values are never written to it, so
  it's always safe to commit, review, and edit.

## Install

Requirements: **Zig 0.15.2** and `git` on `$PATH`.

```sh
git clone https://github.com/<you>/inshtaller.git
cd inshtaller

# user-level install (no sudo) — puts `insh` in ~/.local/bin
zig build -Doptimize=ReleaseSafe --prefix ~/.local

# or system-wide:
sudo zig build -Doptimize=ReleaseSafe --prefix /usr/local
```

Make sure the chosen `bin/` directory is on your `$PATH`. For the user-level
install, most shells do this by default; if not:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

**Why `ReleaseSafe`:** safety checks stay on and speed is close to
`ReleaseFast`. Don't use `ReleaseFast` here — this binary handles key material,
and the runtime checks catch bugs before they have a chance to leak secrets.

## Quickstart

```sh
# 1. Create a PRIVATE GitHub repo, e.g. https://github.com/you/secrets.git
# 2. Create a fine-grained PAT with "Contents: Read/Write" on that repo.

insh init
# → prompts for repo URL + PAT
# → generates ~/.inshtaller/master.key   (keep this safe!)
# → writes   ~/.inshtaller/github_token
# → writes   ~/.inshtaller/config.yaml

insh add --type env --key OPENAI_API_KEY
printf 'postgres://user:pw@host/db' | insh add --type env --key DATABASE_URL --stdin

insh sync
# → clones/pulls the backend repo
# → encrypts the new values into secrets.enc
# → pushes
# → writes one env file per supported shell under ~/.inshtaller/
#     env.sh   (bash + zsh)
#     env.fish (fish)
#     env.nu   (nushell)
```

Then add ONE line to your shell's rc — pick the row that matches your shell:

| Shell     | Line to add                                |
| --------- | ------------------------------------------ |
| bash      | `source ~/.inshtaller/env.sh`   in `~/.bashrc`   |
| zsh       | `source ~/.inshtaller/env.sh`   in `~/.zshrc`    |
| fish      | `source ~/.inshtaller/env.fish` in `~/.config/fish/config.fish` |
| nushell   | `source ~/.inshtaller/env.nu`   in your `$nu.config-path` |

Open a new shell and `$OPENAI_API_KEY` is set. Done.

> `insh sync` also prints these source commands to stdout after each run, so
> you never have to remember which file your shell wants.

## Commands

| Command | Purpose |
| --- | --- |
| `insh init` | One-time setup per machine. Generates the master key and writes the config. |
| `insh add --type env --key K [--stdin]` | Stage a new env var. By default `insh` prompts for the value with input hidden; pass `--stdin` to read it from stdin instead. The value is encrypted immediately and the key name is added to `config.yaml`. Nothing touches the network. |
| `insh sync` | Two-way sync. Pulls the backend repo, decrypts whatever's there, merges in any keys staged locally, re-encrypts, pushes, and writes one env file per supported shell (`env.sh`, `env.fish`, `env.nu`). |
| `insh edit` | Opens `$EDITOR` on `config.yaml` so you can reorder or remove keys. The config never contains values, so this is safe. |
| `insh help` / `insh version` | Self-explanatory. |

## Multi-machine setup

1. On machine A: `insh init`, `insh add …`, `insh sync`.
2. Copy `~/.inshtaller/master.key` to machine B over a trusted channel
   (scp, USB, password manager). This file is the root of trust.
3. On machine B: run `insh init`, choose the same repo URL, and provide a PAT
   (the PAT can differ per machine).
4. Because you kept B's newly-generated key, overwrite it:
   `mv ~/.inshtaller/master.key.from-A ~/.inshtaller/master.key`
5. `insh sync` on B — your vars appear in `~/.inshtaller/env.sh`.

> On first sync against a repo that has other files besides `secrets.enc` and
> `README*`, `insh` refuses to continue. This prevents accidentally pointing at
> the wrong repo and overwriting it.

## On-disk layout

```
~/.inshtaller/
├── master.key        32 random bytes, mode 0600 (symmetric AEAD key)
├── github_token      GitHub PAT, mode 0600
├── config.yaml       user-editable: version, backend.repo, list of keys
├── pending/          keys staged by `insh add`, cleaned after a successful sync
├── .state/           local clone of the backend repo
├── env.sh            decrypted exports for bash + zsh (mode 0600)
├── env.fish          decrypted exports for fish       (mode 0600)
└── env.nu            decrypted exports for nushell    (mode 0600)
```

Backend repo layout (created for you):

```
secrets.enc          [24-byte nonce][ciphertext][16-byte Poly1305 tag]
                     AEAD AD = "insh:v1" binds the format version.
```

## Security model

**What's encrypted:** all env var values, using XChaCha20-Poly1305 with a
32-byte (256-bit) key. Random 24-byte nonce per blob.

**What's plaintext:** `config.yaml` contains key names (`OPENAI_API_KEY`, …)
but no values.

**What never crosses the network:** the master key. Physically copy it to each
machine you want to sync on.

**What's kept out of logs:** secret values are wrapped in a `Secret` type
whose format output is always `[REDACTED]`. The logger never accepts raw
strings for value fields; leaking a plaintext is a compile-time slip, not a
runtime one. The GitHub PAT is passed to `git` via `GIT_ASKPASS`, so it never
appears in `ps`, `git` error messages, or the remote URL.

**Post-quantum posture:** symmetric AEAD at 256 bits stays safe against a
quantum attacker under Grover (effective ~128-bit security — still far out of
reach). There is no asymmetric crypto anywhere, so Shor's algorithm doesn't
apply. If you want to avoid out-of-band key copy later, the right upgrade is
to add a hybrid ML-KEM (FIPS 203) layer — that's a future extension, not
something v1 needs.

## Recovery

- **Lost `master.key`:** there is no recovery. That's the point. Regenerate
  by pointing `insh init` at a fresh private repo (or delete the old
  `secrets.enc` out of band and re-`init`) and re-add your vars.
- **Leaked PAT:** revoke it on GitHub, generate a new one, overwrite
  `~/.inshtaller/github_token` (mode 0600).
- **Leaked master key:** rotate. Generate a new key locally, decrypt with the
  old key, re-encrypt with the new key, force-push. (Not yet automated — open
  an issue if you need it.)

## Development

```sh
zig build            # compile
zig build test       # run unit tests (crypto roundtrip, YAML, redaction, …)
zig build run -- help
```

Layout:

```
src/
├── main.zig         dispatcher + GIT_ASKPASS shim
├── root.zig         library re-exports for tests
├── paths.zig        ~/.inshtaller path helpers
├── config.zig       tiny YAML parser (version, backend.repo, env[])
├── crypto.zig       XChaCha20-Poly1305 encrypt/decrypt
├── git.zig          std.process.Child wrapper with askpass-injected auth
├── log.zig          Secret wrapper + redacting log helpers
├── provider.zig     shell provider interface (vtable) + registry
├── provider/
│   ├── bash.zig     POSIX export, single-quote escaping
│   ├── zsh.zig      same as bash, kept separate for future divergence
│   ├── fish.zig     `set -gx` with fish-style \' / \\ escaping
│   └── nushell.zig  `$env.KEY = "…"` with double-quote escaping
└── cli/
    ├── init.zig
    ├── add.zig
    ├── edit.zig
    └── sync.zig
```

### Adding a new shell

A shell provider is a file under `src/provider/` that fills in the `Provider`
interface from `src/provider.zig`:

```zig
pub const Provider = struct {
    shell: Shell,
    file_extension: []const u8,  // ".sh", ".fish", ".nu", …
    writeExportFn:        *const fn (w: *std.io.Writer, env: Env) std.io.Writer.Error!void,
    writeSourceCommandFn: *const fn (w: *std.io.Writer, path: []const u8) std.io.Writer.Error!void,
    // writeFile(w, envs) is supplied by the interface — it calls writeExport in a loop.
};
```

Because `Provider` is constructed as a plain struct literal, the compiler
rejects a provider that forgets a field. That's the feature-parity guarantee.

Steps to add, say, `ksh`:

1. Create `src/provider/ksh.zig`, exporting `pub const provider: Provider = .{ … }`
   with the right quoting rules for that shell's strings.
2. Add `ksh` to the `Shell` enum in `src/provider.zig` (and teach
   `Shell.fromPath` about the binary name if it differs).
3. Register it in the `all` array and the `byShell` switch in `provider.zig`.
4. Add unit tests covering the escaping corner cases (embedded quotes,
   backslashes, newlines) — there's one test per shell already under
   `src/provider/*.zig` you can copy.
5. `zig build test` — passes ⇒ `insh sync` now writes `env.ksh` alongside the
   other files on the next run.

No changes to `cli/sync.zig` are needed; it iterates `provider.all`.

The escaping rules baked into each provider:

| Shell    | Export form                 | Safe quoting strategy                             |
| -------- | --------------------------- | ------------------------------------------------- |
| bash/zsh | `export KEY='value'`        | single-quote, embedded `'` → `'\''`               |
| fish     | `set -gx KEY 'value'`       | single-quote, `\\` and `\'` escapes               |
| nushell  | `$env.KEY = "value"`        | double-quote with `\"`, `\\`, `\n`, `\r`, `\t`    |

## License

See `LICENSE`.
