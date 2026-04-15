--!strict
--!optimize 2

-- synctodisk: Syncs Roblox Studio ModuleScripts to disk via WebSocket + Rojo sourcemap.
-- Run: synctodisk [CONFIG] [OPTIONS]
--
-- Requires sync.config.json in the project root (or pass a custom path).
-- Minimal example:
--   { "watchedPaths": ["ServerScriptService.MyGame.Trees"] }
-- Full options:
--   {
--     "watchedPaths": ["ServerScriptService.MyGame.Trees", "ReplicatedStorage.SharedTrees"],
--     "port": 34876,
--     "sourcemapPath": "sourcemap.json",
--     "luaurcPath": ".luaurc"
--   }
-- Only DataModel paths that equal or are descendants of a watchedPath entry will be written.

local net = require("@lune/net")
local fs = require("@lune/fs")
local task = require("@lune/task")
local serde = require("@lune/serde")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local lib = require("@self/lib")
local buildIndex = lib.buildIndex
local countEntries = lib.countEntries
local buildAliasList = lib.buildAliasList
local rewriteRequires = lib.rewriteRequires
local rewriteInstanceRequires = lib.rewriteInstanceRequires
local rewriteGameRequires = lib.rewriteGameRequires
local isUnderWatchedPath = lib.isUnderWatchedPath
local deriveFilePath = lib.deriveFilePath
local folderPathFromFilePath = lib.folderPathFromFilePath

------------------------------------------------------------------------
-- Version header
------------------------------------------------------------------------

local VERSION = (_G.VERSION or "DEBUG") :: string
local DEFAULT_CONFIG = "sync.config.json"

local function Color(text: string, color: stdio.Color): string
	return `{stdio.color(color)}{text}{stdio.color("reset")}`
end

local function Style(text: string, style: stdio.Style): string
	return `{stdio.style(style)}{text}{stdio.style("reset")}`
end

------------------------------------------------------------------------
-- CLI argument parsing
------------------------------------------------------------------------

local args = process.args

local function print_usage()
	print(Color(Style("USAGE:", "bold"), "yellow"))
	print("\tsynctodisk [CONFIG] [OPTIONS]")
	print("")
	print(Color(Style("ARGUMENTS:", "bold"), "yellow"))
	print(
		`\t{stdio.color("cyan")}[CONFIG]{stdio.color("reset")}\t\tPath to JSON config file (default: {DEFAULT_CONFIG})`
	)
	print("")
	print(Color(Style("OPTIONS:", "bold"), "yellow"))
	print(`\t{stdio.color("green")}-h, --help{stdio.color("reset")}\t\tPrint this help message`)
	print(`\t{stdio.color("green")}-v, --version{stdio.color("reset")}\t\tPrint version information`)
end

if table.find(args, "-v") or table.find(args, "--version") then
	print(VERSION)
	return
end

print(`{Color("synctodisk", "green")} {VERSION}`)

if table.find(args, "-h") or table.find(args, "--help") then
	print_usage()
	return
end

local configPath = DEFAULT_CONFIG
for _, arg in args do
	if string.sub(arg, 1, 1) ~= "-" then
		configPath = arg
		break
	end
end

------------------------------------------------------------------------
-- Types
------------------------------------------------------------------------

type SourcemapNode = lib.SourcemapNode
type AliasEntry = lib.AliasEntry

type Config = {
	watchedPaths: { string }, -- required: DataModel paths the tool is allowed to write under
	port: number,
	sourcemapPath: string,
	luaurcPath: string,
}

type Ack = {
	type: string,
	success: boolean,
	message: string,
}

------------------------------------------------------------------------
-- Config
------------------------------------------------------------------------

local readOk, rawOrErr = pcall(fs.readFile, configPath)
if not readOk then
	print(`[synctodisk] ERROR: {configPath} not found: {rawOrErr}`)
	print("[synctodisk] Create sync.config.json with at least:")
	print('  { "watchedPaths": ["ServerScriptService.MyGame.Trees"] }')
	process.exit(1)
end

local configRaw = rawOrErr :: string

local parseOk, parsed = pcall(function()
	return serde.decode("json", configRaw)
end)
if not parseOk or type(parsed) ~= "table" then
	print(`[synctodisk] ERROR: {configPath} is not valid JSON: {parsed}`)
	process.exit(1)
end

local p = parsed :: { [string]: unknown }

if type(p.watchedPaths) ~= "table" or #(p.watchedPaths :: { unknown }) == 0 then
	print("[synctodisk] ERROR: config must contain a non-empty 'watchedPaths' array.")
	print('  Example: { "watchedPaths": ["ServerScriptService.MyGame.Trees"] }')
	process.exit(1)
end

local watchedPaths: { string } = {}
for _, v in p.watchedPaths :: { unknown } do
	if type(v) == "string" then
		table.insert(watchedPaths, v :: string)
	end
end

local config: Config = {
	watchedPaths = watchedPaths,
	port = if type(p.port) == "number" then p.port :: number else 34876,
	sourcemapPath = if type(p.sourcemapPath) == "string" then p.sourcemapPath :: string else "sourcemap.json",
	luaurcPath = if type(p.luaurcPath) == "string" then p.luaurcPath :: string else ".luaurc",
}

print(`[synctodisk] Loaded {configPath}`)
print(`[synctodisk] Watching {#config.watchedPaths} path(s):`)
for _, wp in config.watchedPaths do
	print(`[synctodisk]   • {wp}`)
end

------------------------------------------------------------------------
-- Sourcemap index: DataModel path -> file path on disk
------------------------------------------------------------------------

local function loadSourcemapIndex(path: string): { [string]: string }
	local index: { [string]: string } = {}
	local ok, raw = pcall(fs.readFile, path)
	if not ok then
		print(`[synctodisk] WARNING: Cannot read sourcemap '{path}': {raw}`)
		return index
	end
	local smParseOk, sm = pcall(serde.decode, "json", raw :: string)
	if not smParseOk then
		print(`[synctodisk] WARNING: Failed to parse sourcemap JSON: {sm}`)
		return index
	end
	buildIndex(sm :: SourcemapNode, "", index)
	return index
end

------------------------------------------------------------------------
-- .luaurc alias loading
------------------------------------------------------------------------

local function loadAliases(path: string): { [string]: string }
	local aliases: { [string]: string } = {}
	local ok, raw = pcall(fs.readFile, path)
	if not ok then
		return aliases
	end
	local rcParseOk, rc = pcall(serde.decode, "json", raw :: string)
	if not rcParseOk or type(rc) ~= "table" then
		return aliases
	end
	local rcTable = rc :: { [string]: unknown }
	if type(rcTable.aliases) ~= "table" then
		return aliases
	end
	for name, root in rcTable.aliases :: { [string]: string } do
		-- Skip the lune type definition alias — only useful for type checking, not runtime paths.
		if name == "lune" then
			continue
		end
		local normalized = tostring(root):gsub("\\", "/")
		if normalized:sub(-1) ~= "/" then
			normalized ..= "/"
		end
		aliases[name] = normalized
	end
	return aliases
end

------------------------------------------------------------------------
-- Filesystem helpers
------------------------------------------------------------------------

-- Creates all directory segments in path, tolerating already-existing dirs.
local function mkdirp(path: string)
	local normalized = path:gsub("\\", "/")
	local current = ""
	for segment in normalized:gmatch("[^/]+") do
		current = if current == "" then segment else current .. "/" .. segment
		if not fs.isDir(current) then
			local ok, err = pcall(fs.writeDir, current)
			if not ok and not fs.isDir(current) then
				error(`mkdirp: failed at '{current}': {err}`)
			end
		end
	end
end

------------------------------------------------------------------------
-- Sync message handler
------------------------------------------------------------------------

type SyncMessage = {
	dmPath: string,
	source: string?,
	instanceType: string,
}

local function handleSync(
	msg: SyncMessage,
	index: { [string]: string },
	aliasList: { AliasEntry },
	watched: { string }
): Ack?
	local dmPath = msg.dmPath or ""
	local instanceType = msg.instanceType or ""
	local source = msg.source or ""

	if not isUnderWatchedPath(dmPath, watched) then
		return nil
	end

	if instanceType ~= "ModuleScript" and instanceType ~= "Folder" then
		return {
			type = "ack",
			success = false,
			message = `Skipped: instanceType '{instanceType}' is not ModuleScript or Folder`,
		}
	end

	-- Look up path in sourcemap; fall back to derivation for brand-new instances
	-- (ones created in Studio before sourcemap:watch has had a chance to regenerate).
	local filePath = index[dmPath]
	local derived = false
	if not filePath then
		local dp, ok = deriveFilePath(dmPath, index)
		if not ok or not dp then
			return {
				type = "ack",
				success = false,
				message = `No sourcemap entry for '{dmPath}' and cannot derive path from parent`,
			}
		end
		filePath = dp
		derived = true
	end

	local tag = if derived then " (derived)" else ""

	if instanceType == "Folder" then
		-- deriveFilePath always appends .luau; resolve the actual directory path.
		local dir = folderPathFromFilePath(filePath)
		local ok, err = pcall(mkdirp, dir)
		if not ok then
			return {
				type = "ack",
				success = false,
				message = `Could not create directory '{dir}': {err}`,
			}
		end
		return { type = "ack", success = true, message = `Dir OK: {dir}{tag}` }
	end

	-- ModuleScript: if a same-name directory already exists (Rojo folder-style
	-- module layout), write to stem/init.luau and remove the stale flat file.
	if not filePath:match("/init%.luau?$") then
		local stem = filePath:match("^(.-)%.luau?$")
		if stem and fs.isDir(stem) then
			if fs.isFile(filePath) then
				pcall(fs.removeFile, filePath)
			end
			filePath = stem .. "/init.luau"
		end
	end

	-- Rewrite both file-path and instance-path requires.
	local rewriteLog: { string } = {}
	local rewritten = rewriteRequires(source, aliasList, rewriteLog)
	rewritten = rewriteInstanceRequires(rewritten, index, aliasList, rewriteLog)
	rewritten = rewriteGameRequires(rewritten, index, aliasList, rewriteLog)
	for _, entry in rewriteLog do
		print(`[synctodisk]   ↪ {entry}`)
	end
	local parentDir = filePath:match("^(.*)/[^/]*$")
	if parentDir and parentDir ~= "" then
		local dirOk, dirErr = pcall(mkdirp, parentDir)
		if not dirOk then
			return {
				type = "ack",
				success = false,
				message = `Could not create parent directory: {dirErr}`,
			}
		end
	end

	local writeOk, writeErr = pcall(fs.writeFile, filePath, rewritten)
	if not writeOk then
		return {
			type = "ack",
			success = false,
			message = `Write failed for '{filePath}': {writeErr}`,
		}
	end

	return { type = "ack", success = true, message = `Wrote: {filePath}{tag}` }
end

------------------------------------------------------------------------
-- Delete handler
------------------------------------------------------------------------

local function handleDelete(dmPath: string, index: { [string]: string }, watched: { string }): Ack?
	if not isUnderWatchedPath(dmPath, watched) then
		return nil
	end

	-- Prefer the sourcemap entry; fall back to derivation for files that were
	-- written optimistically before the sourcemap was regenerated.
	local filePath = index[dmPath]
	if not filePath then
		local dp, ok = deriveFilePath(dmPath, index)
		if not ok or not dp then
			return { type = "ack", success = true, message = `No entry for '{dmPath}', nothing to delete` }
		end
		filePath = dp
	end

	if fs.isFile(filePath) then
		local ok, err = pcall(fs.removeFile, filePath)
		if not ok then
			return { type = "ack", success = false, message = `Delete failed for '{filePath}': {err}` }
		end
		return { type = "ack", success = true, message = `Deleted: {filePath}` }
	elseif fs.isDir(filePath) then
		local ok, err = pcall(fs.removeDir, filePath)
		if not ok then
			return { type = "ack", success = false, message = `Delete dir failed for '{filePath}': {err}` }
		end
		return { type = "ack", success = true, message = `Deleted dir: {filePath}` }
	else
		return { type = "ack", success = true, message = `Not on disk: '{filePath}', nothing to delete` }
	end
end

------------------------------------------------------------------------
-- State: live sourcemap index and alias list (hot-reloaded on change)
------------------------------------------------------------------------

local indexRef: { value: { [string]: string } } = { value = loadSourcemapIndex(config.sourcemapPath) }
local aliasesRef: { value: { [string]: string } } = { value = loadAliases(config.luaurcPath) }

print(`[synctodisk] Sourcemap: {countEntries(indexRef.value)} entries`)
print(`[synctodisk] Aliases  : {countEntries(aliasesRef.value)} active`)

-- Watch sourcemap for changes (poll every 2 seconds).
-- Also reloads aliases in case .luaurc was edited.
local lastSourcemapContent = ""
task.spawn(function()
	while true do
		task.wait(2)
		local ok, raw = pcall(fs.readFile, config.sourcemapPath)
		if ok and raw ~= lastSourcemapContent then
			lastSourcemapContent = raw :: string
			local smParseOk, sm = pcall(serde.decode, "json", raw :: string)
			if smParseOk then
				local newIndex: { [string]: string } = {}
				buildIndex(sm :: SourcemapNode, "", newIndex)
				indexRef.value = newIndex
				aliasesRef.value = loadAliases(config.luaurcPath)
				print(`[synctodisk] Sourcemap reloaded: {countEntries(newIndex)} entries`)
			end
		end
	end
end)

------------------------------------------------------------------------
-- WebSocket server
------------------------------------------------------------------------

local function encode(value: { [string]: unknown }): string
	return serde.encode("json", value)
end

local startOk, startErr = pcall(function()
	net.serve(config.port, {
		handleWebSocket = function(socket)
			print("[synctodisk] Client connected")

			while true do
				local msg = socket:next()
				if msg == nil then
					break
				end

				local decodeOk, decoded = pcall(serde.decode, "json", msg :: string)
				if not decodeOk then
					socket:send(encode({ type = "ack", success = false, message = "Invalid JSON" }))
					continue
				end

				local d = decoded :: { [string]: unknown }
				local msgType = tostring(d.type or "")

				if msgType == "ping" then
					socket:send(encode({ type = "pong" }))
				elseif msgType == "sync" then
					local aliasList = buildAliasList(aliasesRef.value)
					local syncMsg: SyncMessage = {
						dmPath = tostring(d.dmPath or ""),
						source = if type(d.source) == "string" then d.source :: string else "",
						instanceType = tostring(d.instanceType or ""),
					}
					local ack = handleSync(syncMsg, indexRef.value, aliasList, config.watchedPaths)
					if ack then
						socket:send(encode(ack :: { [string]: unknown }))
						local icon = if ack.success then "✓" else "✗"
						print(`[synctodisk] {icon} {ack.message}`)
					end
				elseif msgType == "delete" then
					local ack = handleDelete(tostring(d.dmPath or ""), indexRef.value, config.watchedPaths)
					if ack then
						socket:send(encode(ack :: { [string]: unknown }))
						local icon = if ack.success then "✓" else "✗"
						print(`[synctodisk] {icon} {ack.message}`)
					end
				elseif msgType == "disconnect" then
					socket:send(encode({ type = "ack", success = true, message = "Bye" }))
					break
				end
			end

			print("[synctodisk] Client disconnected")
		end,
	})
end)

if not startOk then
	print(`[synctodisk] ERROR: Failed to start server: {startErr}`)
	print(`[synctodisk] Is port {config.port} already in use?`)
	process.exit(1)
end

print(`[synctodisk] Listening on ws://localhost:{config.port}  (Ctrl+C to stop)`)
