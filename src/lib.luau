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

local function deriveFilePath(dmPath: string, index: { [string]: string }): (string?, boolean)
	local segments: { string } = {}
	for seg in dmPath:gmatch("[^.]+") do
		table.insert(segments, seg)
	end

	for i = #segments - 1, 1, -1 do
		local ancestorPath = table.concat(segments, ".", 1, i)
		local ancestorFile = index[ancestorPath]
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

return {
	buildIndex = buildIndex,
	countEntries = countEntries,
	buildAliasList = buildAliasList,
	rewriteRequires = rewriteRequires,
	isUnderWatchedPath = isUnderWatchedPath,
	deriveFilePath = deriveFilePath,
}
