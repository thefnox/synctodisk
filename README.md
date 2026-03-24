# synctodisk

A CLI tool that syncs behavior trees from a Roblox DataStore to your local filesystem as JSON files. Built with [Lune](https://github.com/filiptibell/lune) and compiled into standalone executables.

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
| `[CONFIG]` | Path to the TOML config file. Defaults to `synctodisk.toml` in the current directory. |

### Options

| Option | Description |
|--------|-------------|
| `-h`, `--help` | Print usage information |
| `-v`, `--version` | Print version information |
| `-w`, `--watch` | Continuously poll the DataStore and sync on an interval |
| `-q`, `--quiet` | Suppress all output |

### Examples

Sync once using the default config file in the current directory:
```sh
synctodisk
```

Sync once using a specific config file:
```sh
synctodisk path/to/my-config.toml
```

Watch mode — poll every N seconds and re-sync whenever new trees appear:
```sh
synctodisk --watch
synctodisk my-config.toml --watch
```

## Config File

`synctodisk` is configured through a [TOML](https://toml.io) file. By default it looks for `synctodisk.toml` in the current working directory, but you can pass any path on the command line.

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `universe_id` | integer | The **Universe ID** of your Roblox experience. Found on the [Creator Dashboard](https://create.roblox.com/dashboard/creations) under the experience settings. |
| `place_id` | integer | The **Place ID** of the starting place in your experience. |
| `api_key` | string | A Roblox **Open Cloud API key** with `DataStore` read permissions for the target universe. Create one at [create.roblox.com/credentials](https://create.roblox.com/credentials). |

### Optional Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `output` | string | `"trees"` | Local directory where synced behavior tree JSON files are written. Created automatically if it does not exist. |
| `datastore` | string | `"BehaviorTrees"` | Name of the Roblox DataStore that contains the behavior tree entries. |
| `poll_interval` | integer | `5` | How often (in seconds) to re-sync when running in `--watch` mode. |

### Example Config

```toml
# synctodisk.toml

universe_id   = 12345678       # Your Roblox Universe ID
place_id      = 87654321       # Your starting Place ID
api_key       = "your-open-cloud-api-key"

# Optional
output        = "trees"        # Output directory (default: "trees")
datastore     = "BehaviorTrees" # DataStore name (default: "BehaviorTrees")
poll_interval = 10             # Seconds between syncs in watch mode (default: 5)
```

Each DataStore entry is written to `<output>/<key>.json`. Any characters in the key that are not alphanumeric, hyphens, or underscores are replaced with `_`.

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
