# synctodisk

A CLI tool that syncs Roblox Studio ModuleScripts to disk in real time via a WebSocket connection and a Rojo sourcemap. Built with [Lune](https://github.com/filiptibell/lune) and compiled into standalone executables.

When running, `synctodisk` starts a local WebSocket server. A companion Roblox Studio plugin sends `sync` and `delete` messages as you edit behavior-tree ModuleScripts in Studio; `synctodisk` writes or removes the corresponding files on disk, keeping your Rojo project in sync.

## Installation

Download the latest binary for your platform from the [Releases](../../releases) page:

| Platform | File |
|----------|------|
| Linux (x86\_64) | `synctodisk-linux-x86_64.tar.xz` |
| Linux (aarch64) | `synctodisk-linux-aarch64.tar.xz` |
| macOS (x86\_64) | `synctodisk-macos-x86_64.tar.xz` |
| macOS (aarch64 / Apple Silicon) | `synctodisk-macos-aarch64.tar.xz` |
| Windows (x86\_64) | `synctodisk-windows-x86_64.tar.gz` |

Extract the archive and place the `synctodisk` (or `synctodisk.exe`) binary somewhere on your `PATH`.

## Usage

```
synctodisk [CONFIG] [OPTIONS]
```

### Arguments

| Argument | Description |
|----------|-------------|
| `[CONFIG]` | Path to the JSON config file. Defaults to `btree-sync.config.json` in the current directory. |

### Options

| Option | Description |
|--------|-------------|
| `-h`, `--help` | Print usage information |
| `-v`, `--version` | Print version information |

### Examples

Start the server using the default config in the current directory:
```sh
synctodisk
```

Start the server using a specific config file:
```sh
synctodisk path/to/my-config.json
```

## Config File

`synctodisk` is configured through a JSON file. By default it looks for `btree-sync.config.json` in the current working directory.

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `watchedPaths` | `string[]` | One or more DataModel paths (e.g. `"ServerScriptService.MyGame.Trees"`). Only instances that are equal to or descendants of a watched path will be synced to disk. |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `port` | number | `34876` | The local port the WebSocket server listens on. The Studio plugin must connect to the same port. |
| `sourcemapPath` | string | `"sourcemap.json"` | Path to the Rojo-generated sourcemap that maps DataModel paths to file paths on disk. Keep `rojo sourcemap --watch` running alongside `synctodisk` so this stays up to date. |
| `luaurcPath` | string | `".luaurc"` | Path to the project's `.luaurc` file. When present, `synctodisk` rewrites bare `require("some/path")` calls to `require("@alias/...")` using the aliases defined there. |

### Example Config

```json
{
  "watchedPaths": [
    "ServerScriptService.MyGame.Trees",
    "ReplicatedStorage.SharedTrees"
  ],
  "port": 34876,
  "sourcemapPath": "sourcemap.json",
  "luaurcPath": ".luaurc"
}
```

A minimal config only needs `watchedPaths`:

```json
{
  "watchedPaths": ["ServerScriptService.MyGame.Trees"]
}
```

## Typical Workflow

1. In your Rojo project root, create `btree-sync.config.json` with the paths you want to sync.
2. Run `rojo sourcemap --watch` (or `rojo sourcemap`) to generate / keep `sourcemap.json` current.
3. Run `synctodisk` (or `synctodisk path/to/btree-sync.config.json`).
4. Open Roblox Studio with the companion plugin active. The plugin connects to `ws://localhost:34876`.
5. Edit behavior-tree ModuleScripts in Studio — changes are written to disk automatically.
6. Press **Ctrl+C** to stop the server.

## Building from Source

Prerequisites:
- [Rokit](https://github.com/rojo-rbx/rokit) — installs the required toolchain

```sh
# Install tools (lune, darklua, stylua)
rokit install

# Build all platform binaries into release/
lune run build
```

### Bumping the Version

```sh
lune run bump
```

This prompts for a new semver version string, then updates `build/.darklua.json` (which injects `VERSION` at compile time).

### Creating a Release

1. Run `lune run bump` and commit the version change.
2. Create and publish a new GitHub Release with a semver tag (e.g. `v0.2.0`).
3. The `release.yml` workflow automatically builds all platform binaries and uploads them as release assets.

