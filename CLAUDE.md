# synctodisk – Claude Context

## What this project does

**synctodisk** is a CLI tool that runs on your development machine and accepts WebSocket connections from a Roblox Studio plugin. When Studio saves a ModuleScript or Folder, it sends a message over the socket; synctodisk writes the source to the matching file on disk (resolved via a Rojo sourcemap) and optionally rewrites bare `require("path/...")` calls into `require("@alias/...")` form using `.luaurc` aliases.

The intended workflow is:

```
Roblox Studio plugin  --WebSocket-->  synctodisk  -->  disk file  -->  git
```

## Tech stack

| Tool | Role |
|---|---|
| **Lune** (`0.10.4`) | Luau runtime — executes the CLI at dev time and drives the build scripts |
| **darklua** (`0.18.0`) | Bundles `src/init.luau` + `src/lib.luau` into a single `release/synctodisk.luau`, strips types, injects the `VERSION` global |
| **Zune** (`0.5.4`) | Luau test runner — used for unit tests only (not lune, since zune has a built-in testing library) |
| **rokit** | Toolchain manager — `rokit.toml` pins all of the above |
| **StyLua** (`2.4.0`) | Code formatter |

## Source layout

```
src/
  init.luau      # CLI entry point: config parsing, IO, WebSocket server
  lib.luau       # Pure utility functions (no IO) — required by both init.luau and the tests

.lune/
  build.luau     # Build script: bundles then compiles executables for 5 targets
  bump.luau      # Interactive version bump: edits build/.darklua.json
  libs/
    darklua_version.luau  # Read/write VERSION from darklua config
    log.luau              # Simple print wrapper

build/
  .darklua.json  # darklua config: bundler settings + VERSION injection

test/
  synctodisk.spec.lua  # Zune unit tests for all pure functions in src/lib.luau
  example.spec.lua     # Minimal boilerplate example

release/         # Build output (gitignored except pre-built archives)
```

## Important design decisions

### `src/lib.luau` — pure function module
All logic that has no IO dependency lives in `lib.luau` and is `require`d by both `init.luau` and the test suite. This keeps the pure functions unit-testable without spinning up a lune runtime with full IO.

### `require("@self/lib")` — alias-based require in init.luau
The `.luaurc` defines `"self": "src"`. `init.luau` uses `require("@self/lib")` (not `require("./lib")`) because darklua's bundler resolves `./` paths from the project root, not from the source file's location. The `@self` alias correctly resolves to `src/lib.luau` in both lune (at runtime) and darklua (at bundle time).

### WebSocket method syntax
Lune's WebSocket userdata methods **must** use colon syntax: `socket:next()`, `socket:send(...)`. Using dot syntax (`socket.next()`) fails at runtime with "bad argument `self`" because the `self` argument is not passed.

### `rewriteRequires` pattern
The gsub pattern `require%s*%(%s*"([^@][^"]*)"` deliberately does **not** consume the closing `)`. The replacement strings must therefore also omit the closing `)`, leaving the original one in place. Adding `)` to both the pattern-match and the replacement would produce a double-paren bug.

## Common commands

```bash
# Run tests
zune test ./test/synctodisk.spec.lua

# Bundle only (fast, validates darklua can resolve all requires)
darklua process --config build/.darklua.json src/init.luau release/synctodisk.luau

# Full build (requires lune cross-compilation support on Linux/macOS)
lune run build

# Interactive version bump (edits build/.darklua.json)
lune run bump
```

## Versioning & releases

The canonical version lives in `build/.darklua.json` under the `inject_global_value` rule for `VERSION`. The `bump.luau` script edits this file interactively.

Releases are published by:
1. Bumping the version with `lune run bump`
2. Committing and tagging (`git tag v<version>`)
3. Pushing the tag — the GitHub Actions workflow (`.github/workflows/release.yml`) triggers on a published release and uploads the compiled archives

The CI builds five targets: `macos-x86_64`, `macos-aarch64`, `linux-x86_64`, `linux-aarch64`, `windows-x86_64`.
