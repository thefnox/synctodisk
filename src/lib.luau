--!strict
--!optimize 2

-- Pure utility functions extracted from init.luau for testing.
-- No lune/zune IO dependencies — safe to require from any runtime.

export type SourcemapNode = {
	name: string,
	className: string,
	filePaths: { string }?,
	children: { SourcemapNode }?,
}

export type AliasEntry = { name: string, root: string }

------------------------------------------------------------------------
-- Sourcemap index builder
------------------------------------------------------------------------

local function buildIndex(node: SourcemapNode, parentPath: string, index: { [string]: string })
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

------------------------------------------------------------------------
-- Table utilities
------------------------------------------------------------------------

local function countEntries(t: { [string]: string }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

------------------------------------------------------------------------
-- Alias list builder
------------------------------------------------------------------------

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
-- require() rewriter
------------------------------------------------------------------------

local function rewriteRequires(source: string, aliasList: { AliasEntry }): string
	if #aliasList == 0 then
		return source
	end
	return (
		source:gsub('require%s*%(%s*"([^@][^"]*)"', function(path: string): string
			for _, entry in aliasList do
				if path:sub(1, #entry.root) == entry.root then
					return `require("@{entry.name}/{path:sub(#entry.root + 1)}"`
				end
			end
			return `require("{path}"`
		end)
	)
end

------------------------------------------------------------------------
-- Watched-path guard
------------------------------------------------------------------------

local function isUnderWatchedPath(dmPath: string, watched: { string }): boolean
	for _, watchedEntry in watched do
		if dmPath == watchedEntry or dmPath:sub(1, #watchedEntry + 1) == watchedEntry .. "." then
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- File path derivation
------------------------------------------------------------------------

-- For folder nodes that have no filePath in the sourcemap, infer their
-- directory by finding any descendant in the index and stripping as many
-- path components from the end of its file path as it has name segments
-- below the ancestor (plus one extra if it is an init file).
local function inferDirFromSiblings(ancestorPath: string, index: { [string]: string }): string?
	local prefix = ancestorPath .. "."
	for key, sibFile in index do
		if key:sub(1, #prefix) == prefix then
			local rel = key:sub(#prefix + 1)
			local depth = 0
			for _ in rel:gmatch("[^.]+") do
				depth += 1
			end
			local extraForInit = if sibFile:match("/init%.luau?$") then 1 else 0
			local result = sibFile
			for _ = 1, depth + extraForInit do
				local stripped = result:match("^(.*)/[^/]+$")
				if not stripped then
					result = nil :: any
					break
				end
				result = stripped
			end
			if result then
				return result .. "/"
			end
		end
	end
	return nil
end

local function deriveFilePath(dmPath: string, index: { [string]: string }): (string?, boolean)
	local segments: { string } = {}
	for seg in dmPath:gmatch("[^.]+") do
		table.insert(segments, seg)
	end

	for i = #segments - 1, 1, -1 do
		local ancestorPath = table.concat(segments, ".", 1, i)
		local ancestorFile = index[ancestorPath] or inferDirFromSiblings(ancestorPath, index)
		if ancestorFile then
			local baseDir: string
			if ancestorFile:match("/init%.luau?$") then
				baseDir = ancestorFile:match("^(.*)/init%.luau?$") :: string
			elseif ancestorFile:match("%.luau?$") then
				baseDir = ancestorFile:match("^(.-)%.luau?$") :: string
			else
				baseDir = ancestorFile:gsub("/$", "")
			end

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
-- Folder path resolution
------------------------------------------------------------------------

-- Given any file path that deriveFilePath or the sourcemap index may produce,
-- return the corresponding *directory* path for a Folder instance:
--   stem/init.lua[u]  →  stem       (folder-style module)
--   stem.lua[u]       →  stem       (derived path — strip extension)
--   anything else     →  as-is (trailing slash stripped)
local function folderPathFromFilePath(filePath: string): string
	if filePath:match("/init%.luau?$") then
		return filePath:match("^(.*)/init%.luau?$") :: string
	elseif filePath:match("%.luau?$") then
		return filePath:match("^(.-)%.luau?$") :: string
	else
		return filePath:gsub("/$", "")
	end
end

------------------------------------------------------------------------
-- Instance-path require rewriter
------------------------------------------------------------------------

-- Rewrites Roblox instance-path requires emitted by Studio plugins:
--   require([[@game/ServerScriptService/Foo/bar]])
-- Looks the DataModel path up in the sourcemap index, strips the file
-- extension (and /init suffix), then applies alias rewriting identical
-- to rewriteRequires.  Leaves the call unchanged if the path is not
-- found in the index.
local function rewriteInstanceRequires(
	source: string,
	index: { [string]: string },
	aliasList: { AliasEntry }
): string
	return source:gsub(
		"require%s*%(%s*%[%[@game/([^%]]+)%]%]%s*%)",
		function(instancePath: string): string
			local dmPath = instancePath:gsub("/", ".")
			local filePath = index[dmPath]
			if not filePath then
				return `require([[@game/{instancePath}]])`
			end
			-- Strip /init suffix and file extension to get the require path
			local requirePath = filePath:match("^(.*)/init%.luau?$")
				or filePath:match("^(.-)%.luau?$")
				or filePath
			-- Apply alias rewriting (longest root first — caller must pre-sort)
			for _, entry in aliasList do
				if requirePath:sub(1, #entry.root) == entry.root then
					return `require("@{entry.name}/{requirePath:sub(#entry.root + 1)}")`
				end
			end
			return `require("{requirePath}")`
		end
	)
end

------------------------------------------------------------------------

return {
	buildIndex = buildIndex,
	countEntries = countEntries,
	buildAliasList = buildAliasList,
	rewriteRequires = rewriteRequires,
	rewriteInstanceRequires = rewriteInstanceRequires,
	isUnderWatchedPath = isUnderWatchedPath,
	deriveFilePath = deriveFilePath,
	folderPathFromFilePath = folderPathFromFilePath,
}
