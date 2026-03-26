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

print(`{Color("synctodisk", "green")} {VERSION}`)

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

if table.find(args, "-h") or table.find(args, "--help") then
	print_usage()
	return
end

if table.find(args, "-v") or table.find(args, "--version") then
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

type Config = {
	watchedPaths: { string }, -- required: DataModel paths the tool is allowed to write under
	port: number,
	sourcemapPath: string,
	luaurcPath: string,
}

type SourcemapNode = {
	name: string,
	className: string,
	filePaths: { string }?,
	children: { SourcemapNode }?,
}

type AliasEntry = { name: string, root: string }

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

local function buildIndex(node: SourcemapNode, parentPath: string, index: { [string]: string })
	-- The DataModel root node (className == "DataModel") has a project name
	-- like "btree" that does NOT appear in Instance:GetFullName() output.
	-- We skip its name so children map directly to service names.
	local myPath: string
	if node.className == "DataModel" then
		myPath = ""
	elseif parentPath == "" then
		myPath = node.name
	else
		myPath = parentPath .. "." .. node.name
	end

	local filePaths = node.filePaths or {}
	if #filePaths > 0 and myPath ~= "" then
		index[myPath] = filePaths[1]
	end

	for _, child in node.children or {} do
		buildIndex(child, myPath, index)
	end
end

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

local function countEntries(t: { [string]: string }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
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

-- Sorted longest-root-first to prevent short prefix from matching before long one.
local function buildAliasList(aliases: { [string]: string }): { AliasEntry }
	local list: { AliasEntry } = {}
	for name, root in aliases do
		table.insert(list, { name = name, root = root })
	end
	table.sort(list, function(a, b)
		return #a.root > #b.root
	end)
	return list
end

------------------------------------------------------------------------
-- require() rewriting
-- Rewrites require("some/bare/path") -> require("@alias/...") when the
-- bare path starts with a known .luaurc alias root.
-- Leaves require(script.X), require("@alias/...") untouched.
------------------------------------------------------------------------

local function rewriteRequires(source: string, aliasList: { AliasEntry }): string
	if #aliasList == 0 then
		return source
	end
	-- Only match string requires that don't already start with @
	return (
		source:gsub('require%s*%(%s*"([^@][^"]*)"', function(path: string): string
			for _, entry in aliasList do
				if path:sub(1, #entry.root) == entry.root then
					return `require("@{entry.name}/{path:sub(#entry.root + 1)}")`
				end
			end
			return `require("{path}")`
		end)
	)
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

-- Returns true if dmPath equals a watched path or is a descendant of one.
local function isUnderWatchedPath(dmPath: string, watched: { string }): boolean
	for _, watchedEntry in watched do
		if dmPath == watchedEntry or dmPath:sub(1, #watchedEntry + 1) == watchedEntry .. "." then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- Path derivation for instances not yet in the sourcemap
-- (e.g. a task module created in Studio before sourcemap:watch catches up)
------------------------------------------------------------------------

-- Walks up the DataModel path hierarchy to find the nearest ancestor that IS
-- in the sourcemap, then extends its file path with the remaining name segments.
-- Returns the derived file path and true, or nil and false if not possible.
local function deriveFilePath(dmPath: string, index: { [string]: string }): (string?, boolean)
	local segments: { string } = {}
	for seg in dmPath:gmatch("[^.]+") do
		table.insert(segments, seg)
	end

	for i = #segments - 1, 1, -1 do
		local ancestorPath = table.concat(segments, ".", 1, i)
		local ancestorFile = index[ancestorPath]
		if ancestorFile then
			-- Determine the base directory where children of this ancestor live.
			local baseDir: string
			if ancestorFile:match("/init%.luau?$") then
				-- Folder-style module: src/foo/init.luau → children at src/foo/
				baseDir = ancestorFile:match("^(.*)/init%.luau?$") :: string
			elseif ancestorFile:match("%.luau?$") then
				-- Single-file module: src/foo.luau → children would go in src/foo/
				-- (Rojo will eventually promote foo.luau → foo/init.luau automatically
				-- once it sees a sibling file; we write optimistically here.)
				baseDir = ancestorFile:match("^(.-)%.luau?$") :: string
			else
				-- Plain directory entry
				baseDir = ancestorFile:gsub("/$", "")
			end

			-- Append any intermediate path segments as subdirectories, final segment as .luau
			local remaining: { string } = {}
			for j = i + 1, #segments do
				table.insert(remaining, segments[j])
			end

			local derived = baseDir
			for j = 1, #remaining - 1 do
				derived ..= "/" .. remaining[j]
			end
			derived ..= "/" .. remaining[#remaining] .. ".luau"

			return derived, true
		end
	end

	return nil, false
end

------------------------------------------------------------------------
-- Sync handler
------------------------------------------------------------------------

local function handleSync(
	msg: SyncMessage,
	index: { [string]: string },
	aliasList: { AliasEntry },
	watched: { string }
): Ack
	local dmPath = msg.dmPath or ""
	local instanceType = msg.instanceType or ""
	local source = msg.source or ""

	if not isUnderWatchedPath(dmPath, watched) then
		return {
			type = "ack",
			success = false,
			message = `Blocked: '{dmPath}' is not under a watched path`,
		}
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
		local ok, err = pcall(mkdirp, filePath)
		if not ok then
			return {
				type = "ack",
				success = false,
				message = `Could not create directory '{filePath}': {err}`,
			}
		end
		return { type = "ack", success = true, message = `Dir OK: {filePath}{tag}` }
	end

	-- ModuleScript: rewrite requires, ensure parent dir, write file.
	local rewritten = rewriteRequires(source, aliasList)
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

local function handleDelete(dmPath: string, index: { [string]: string }, watched: { string }): Ack
	if not isUnderWatchedPath(dmPath, watched) then
		return {
			type = "ack",
			success = false,
			message = `Blocked: '{dmPath}' is not under a watched path`,
		}
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
				local msg = socket.next()
				if msg == nil then
					break
				end

				local decodeOk, decoded = pcall(serde.decode, "json", msg :: string)
				if not decodeOk then
					socket.send(encode({ type = "ack", success = false, message = "Invalid JSON" }))
					continue
				end

				local d = decoded :: { [string]: unknown }
				local msgType = tostring(d.type or "")

				if msgType == "ping" then
					socket.send(encode({ type = "pong" }))
				elseif msgType == "sync" then
					local aliasList = buildAliasList(aliasesRef.value)
					local syncMsg: SyncMessage = {
						dmPath = tostring(d.dmPath or ""),
						source = if type(d.source) == "string" then d.source :: string else "",
						instanceType = tostring(d.instanceType or ""),
					}
					local ack = handleSync(syncMsg, indexRef.value, aliasList, config.watchedPaths)
					socket.send(encode(ack :: { [string]: unknown }))
					local icon = if ack.success then "✓" else "✗"
					print(`[synctodisk] {icon} {ack.message}`)
				elseif msgType == "delete" then
					local ack = handleDelete(tostring(d.dmPath or ""), indexRef.value, config.watchedPaths)
					socket.send(encode(ack :: { [string]: unknown }))
					local icon = if ack.success then "✓" else "✗"
					print(`[synctodisk] {icon} {ack.message}`)
				elseif msgType == "disconnect" then
					socket.send(encode({ type = "ack", success = true, message = "Bye" }))
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
