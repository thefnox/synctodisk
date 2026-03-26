local describe = zune.testing.describe
local test = zune.testing.test
local expect = zune.testing.expect

local lib = require("../src/lib")
local buildIndex = lib.buildIndex
local countEntries = lib.countEntries
local buildAliasList = lib.buildAliasList
local rewriteRequires = lib.rewriteRequires
local isUnderWatchedPath = lib.isUnderWatchedPath
local deriveFilePath = lib.deriveFilePath
local folderPathFromFilePath = lib.folderPathFromFilePath
local rewriteInstanceRequires = lib.rewriteInstanceRequires

------------------------------------------------------------------------
-- buildIndex
------------------------------------------------------------------------

describe("buildIndex", function()
	test("indexes a top-level node", function()
		local index = {}
		buildIndex({ name = "Foo", className = "ModuleScript", filePaths = { "src/Foo.luau" } }, "", index)
		expect(index["Foo"]).toBe("src/Foo.luau")
	end)

	test("DataModel root skips its own name so children key from empty parent", function()
		local index = {}
		local root = {
			name = "game",
			className = "DataModel",
			filePaths = {},
			children = {
				{ name = "ServerScriptService", className = "Service", filePaths = { "src/SSS.luau" } },
			},
		}
		buildIndex(root, "", index)
		expect(index["game"]).toBeNil()
		expect(index["ServerScriptService"]).toBe("src/SSS.luau")
	end)

	test("builds dot-separated keys for nested hierarchy", function()
		local index = {}
		local root = {
			name = "game",
			className = "DataModel",
			filePaths = {},
			children = {
				{
					name = "ServerScriptService",
					className = "Service",
					filePaths = {},
					children = {
						{ name = "Trees", className = "ModuleScript", filePaths = { "src/Trees.luau" } },
					},
				},
			},
		}
		buildIndex(root, "", index)
		expect(index["ServerScriptService.Trees"]).toBe("src/Trees.luau")
	end)

	test("uses first filePath when multiple are present", function()
		local index = {}
		buildIndex(
			{ name = "Foo", className = "ModuleScript", filePaths = { "first.luau", "second.luau" } },
			"",
			index
		)
		expect(index["Foo"]).toBe("first.luau")
	end)

	test("node with empty filePaths is not added to index", function()
		local index = {}
		buildIndex({ name = "Folder", className = "Folder", filePaths = {} }, "", index)
		expect(index["Folder"]).toBeNil()
	end)

	test("node without filePaths field is not added to index", function()
		local index = {}
		buildIndex({ name = "Ghost", className = "Folder" }, "", index)
		expect(index["Ghost"]).toBeNil()
	end)

	test("concatenates non-empty parentPath with dot", function()
		local index = {}
		buildIndex(
			{ name = "Leaf", className = "ModuleScript", filePaths = { "src/a/b/Leaf.luau" } },
			"Root.Middle",
			index
		)
		expect(index["Root.Middle.Leaf"]).toBe("src/a/b/Leaf.luau")
	end)

	test("multiple children from the same parent are all indexed", function()
		local index = {}
		local parent = {
			name = "Parent",
			className = "Folder",
			filePaths = {},
			children = {
				{ name = "A", className = "ModuleScript", filePaths = { "src/A.luau" } },
				{ name = "B", className = "ModuleScript", filePaths = { "src/B.luau" } },
				{ name = "C", className = "ModuleScript", filePaths = { "src/C.luau" } },
			},
		}
		buildIndex(parent, "", index)
		expect(index["Parent.A"]).toBe("src/A.luau")
		expect(index["Parent.B"]).toBe("src/B.luau")
		expect(index["Parent.C"]).toBe("src/C.luau")
	end)

	test("deeply nested three levels under DataModel root", function()
		local index = {}
		local root = {
			name = "game",
			className = "DataModel",
			filePaths = {},
			children = {
				{
					name = "ReplicatedStorage",
					className = "Service",
					filePaths = {},
					children = {
						{
							name = "Shared",
							className = "Folder",
							filePaths = {},
							children = {
								{
									name = "Utils",
									className = "ModuleScript",
									filePaths = { "src/Shared/Utils.luau" },
								},
							},
						},
					},
				},
			},
		}
		buildIndex(root, "", index)
		expect(index["ReplicatedStorage.Shared.Utils"]).toBe("src/Shared/Utils.luau")
	end)
end)

------------------------------------------------------------------------
-- countEntries
------------------------------------------------------------------------

describe("countEntries", function()
	test("empty table returns 0", function()
		expect(countEntries({})).toBe(0)
	end)

	test("single entry returns 1", function()
		expect(countEntries({ a = "x" })).toBe(1)
	end)

	test("counts multiple string-keyed entries", function()
		expect(countEntries({ a = "1", b = "2", c = "3" })).toBe(3)
	end)
end)

------------------------------------------------------------------------
-- buildAliasList
------------------------------------------------------------------------

describe("buildAliasList", function()
	test("empty aliases returns empty list", function()
		local list = buildAliasList({})
		expect(#list).toBe(0)
	end)

	test("single alias produces list of length 1 with correct fields", function()
		local list = buildAliasList({ myalias = "src/foo/" })
		expect(#list).toBe(1)
		expect(list[1].name).toBe("myalias")
		expect(list[1].root).toBe("src/foo/")
	end)

	test("sorts longer roots before shorter roots", function()
		local list = buildAliasList({
			short = "src/",
			long = "src/some/deep/path/",
		})
		expect(#list).toBe(2)
		expect(list[1].root).toBe("src/some/deep/path/")
		expect(list[2].root).toBe("src/")
	end)

	test("three aliases are fully sorted longest-root-first", function()
		local list = buildAliasList({
			a = "aa/",
			b = "bbbbbb/",
			c = "cccc/",
		})
		expect(#list).toBe(3)
		expect(list[1].root).toBe("bbbbbb/")
		expect(list[2].root).toBe("cccc/")
		expect(list[3].root).toBe("aa/")
	end)

	test("name and root fields are preserved correctly", function()
		local list = buildAliasList({ game = "src/game/" })
		expect(list[1].name).toBe("game")
		expect(list[1].root).toBe("src/game/")
	end)
end)

------------------------------------------------------------------------
-- rewriteRequires
------------------------------------------------------------------------

describe("rewriteRequires", function()
	test("empty aliasList returns source unchanged", function()
		local src = 'local x = require("some/path")'
		expect(rewriteRequires(src, {})).toBe(src)
	end)

	test("require with no matching alias is reconstructed identically", function()
		local src = 'local x = require("unrelated/path")'
		local result = rewriteRequires(src, { { name = "foo", root = "src/foo/" } })
		expect(result).toBe(src)
	end)

	test("require matching alias root is rewritten with @ prefix", function()
		local result = rewriteRequires(
			'local x = require("src/foo/bar")',
			{ { name = "foo", root = "src/foo/" } }
		)
		expect(result).toBe('local x = require("@foo/bar")')
	end)

	test("require already prefixed with @ is not rewritten", function()
		local src = 'local x = require("@foo/bar")'
		local result = rewriteRequires(src, { { name = "foo", root = "src/foo/" } })
		expect(result).toBe(src)
	end)

	test("multiple requires in one source are each rewritten independently", function()
		local src = 'require("src/a/x")\nrequire("src/b/y")\nrequire("other/z")'
		local aliasList = {
			{ name = "a", root = "src/a/" },
			{ name = "b", root = "src/b/" },
		}
		local result = rewriteRequires(src, aliasList)
		expect(result).toBe('require("@a/x")\nrequire("@b/y")\nrequire("other/z")')
	end)

	test("single-quoted require strings are not matched", function()
		local src = "local x = require('src/foo/bar')"
		local result = rewriteRequires(src, { { name = "foo", root = "src/foo/" } })
		expect(result).toBe(src)
	end)

	test("longer alias root takes priority over shorter one", function()
		-- With sorting by longest root first, src/deep/mod/ should match before src/
		local aliasList = {
			{ name = "deep", root = "src/deep/mod/" },
			{ name = "top", root = "src/" },
		}
		local result = rewriteRequires('require("src/deep/mod/file")', aliasList)
		expect(result).toBe('require("@deep/file")')
	end)

	test("path that only partially shares alias root prefix is not rewritten", function()
		-- "src/foobar/x" should not match alias root "src/foo/"
		local src = 'require("src/foobar/x")'
		local result = rewriteRequires(src, { { name = "foo", root = "src/foo/" } })
		expect(result).toBe(src)
	end)

	test("require with extra whitespace inside parens is matched", function()
		local result = rewriteRequires(
			'require(  "src/foo/bar")',
			{ { name = "foo", root = "src/foo/" } }
		)
		expect(result).toBe('require("@foo/bar")')
	end)
end)

------------------------------------------------------------------------
-- isUnderWatchedPath
------------------------------------------------------------------------

describe("isUnderWatchedPath", function()
	test("exact match with a watched path returns true", function()
		expect(isUnderWatchedPath("ServerScriptService.Trees", { "ServerScriptService.Trees" })).toBe(true)
	end)

	test("direct child of a watched path returns true", function()
		expect(isUnderWatchedPath("ServerScriptService.Trees.Oak", { "ServerScriptService.Trees" })).toBe(true)
	end)

	test("deep descendant of a watched path returns true", function()
		expect(
			isUnderWatchedPath("ServerScriptService.Trees.Oak.Leaf", { "ServerScriptService.Trees" })
		).toBe(true)
	end)

	test("path that shares prefix but not dot boundary is not a descendant", function()
		-- "ServerScriptService.TreesExtra" should NOT match "ServerScriptService.Trees"
		expect(isUnderWatchedPath("ServerScriptService.TreesExtra", { "ServerScriptService.Trees" })).toBe(
			false
		)
	end)

	test("completely unrelated path returns false", function()
		expect(isUnderWatchedPath("ReplicatedStorage.Shared", { "ServerScriptService.Trees" })).toBe(false)
	end)

	test("empty watched list always returns false", function()
		expect(isUnderWatchedPath("Anything.Goes", {})).toBe(false)
	end)

	test("matches second watched path when first does not match", function()
		local watched = { "ServerScriptService.Trees", "ReplicatedStorage.Shared" }
		expect(isUnderWatchedPath("ReplicatedStorage.Shared.Utils", watched)).toBe(true)
	end)

	test("top-level service path matches itself exactly", function()
		expect(isUnderWatchedPath("ServerScriptService", { "ServerScriptService" })).toBe(true)
	end)
end)

------------------------------------------------------------------------
-- deriveFilePath
------------------------------------------------------------------------

describe("deriveFilePath", function()
	test("single-segment path has no parent, returns nil and false", function()
		local path, ok = deriveFilePath("Root", { Root = "src/Root.luau" })
		expect(path).toBeNil()
		expect(ok).toBe(false)
	end)

	test("parent with init.luau: child placed inside same folder", function()
		local index = { ["Foo.Bar"] = "src/Foo/Bar/init.luau" }
		local path, ok = deriveFilePath("Foo.Bar.Baz", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/Baz.luau")
	end)

	test("parent with init.lua: child placed inside same folder", function()
		local index = { ["Foo.Bar"] = "src/Foo/Bar/init.lua" }
		local path, ok = deriveFilePath("Foo.Bar.Baz", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/Baz.luau")
	end)

	test("parent with .luau extension: child placed in sibling folder", function()
		local index = { ["Foo.Bar"] = "src/Foo/Bar.luau" }
		local path, ok = deriveFilePath("Foo.Bar.Baz", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/Baz.luau")
	end)

	test("parent with .lua extension: child placed in sibling folder", function()
		local index = { ["Foo.Bar"] = "src/Foo/Bar.lua" }
		local path, ok = deriveFilePath("Foo.Bar.Baz", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/Baz.luau")
	end)

	test("parent with plain directory path: child placed inside it", function()
		local index = { ["Foo.Bar"] = "src/Foo/Bar/" }
		local path, ok = deriveFilePath("Foo.Bar.Baz", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/Baz.luau")
	end)

	test("two segments remaining: intermediate becomes subdirectory", function()
		local index = { ["Foo"] = "src/Foo/init.luau" }
		local path, ok = deriveFilePath("Foo.Bar.Baz", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/Baz.luau")
	end)

	test("most specific ancestor wins over shallow one", function()
		local index = {
			["A"] = "src/A/init.luau",
			["A.B"] = "src/A/B/init.luau",
		}
		local path, ok = deriveFilePath("A.B.C", index)
		expect(ok).toBe(true)
		-- should use A.B not A
		expect(path).toBe("src/A/B/C.luau")
	end)

	test("no ancestor in index returns nil and false", function()
		local path, ok = deriveFilePath("Foo.Bar.Baz", {})
		expect(path).toBeNil()
		expect(ok).toBe(false)
	end)

	test("two-segment path with no parent in index returns nil and false", function()
		local path, ok = deriveFilePath("Foo.Bar", {})
		expect(path).toBeNil()
		expect(ok).toBe(false)
	end)

	-- Sibling inference: parent folder has no filePath but a sibling is in the index
	test("infers directory from direct sibling with regular file", function()
		-- Foo.Bar is a plain folder (not in index); Foo.Bar.existing is a sibling
		local index = { ["Foo.Bar.existing"] = "src/Foo/Bar/existing.luau" }
		local path, ok = deriveFilePath("Foo.Bar.newchild", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/newchild.luau")
	end)

	test("infers directory from direct sibling with init.luau file", function()
		local index = { ["Foo.Bar.existing"] = "src/Foo/Bar/existing/init.luau" }
		local path, ok = deriveFilePath("Foo.Bar.newchild", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/newchild.luau")
	end)

	test("infers directory from nested descendant sibling", function()
		-- Only a grandchild is in the index under Foo.Bar
		local index = { ["Foo.Bar.nested.deep"] = "src/Foo/Bar/nested/deep.luau" }
		local path, ok = deriveFilePath("Foo.Bar.newchild", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/newchild.luau")
	end)

	test("infers directory from nested descendant with init.luau", function()
		local index = { ["Foo.Bar.nested.deep"] = "src/Foo/Bar/nested/deep/init.luau" }
		local path, ok = deriveFilePath("Foo.Bar.newchild", index)
		expect(ok).toBe(true)
		expect(path).toBe("src/Foo/Bar/newchild.luau")
	end)

	test("reproduces the real-world case: new script under a plain folder watched path", function()
		-- behavior.trees is a plain Folder with no filePath; only behavior.trees.test exists
		local index = {
			["ServerScriptService.Game_Server.behavior.trees.test"] = "places/game/server/behavior/trees/test.lua",
		}
		local path, ok = deriveFilePath("ServerScriptService.Game_Server.behavior.trees.Animal", index)
		expect(ok).toBe(true)
		expect(path).toBe("places/game/server/behavior/trees/Animal.luau")
	end)

end)

------------------------------------------------------------------------
-- folderPathFromFilePath
------------------------------------------------------------------------

describe("folderPathFromFilePath", function()
	test("plain directory path returned unchanged", function()
		expect(folderPathFromFilePath("src/Foo/Bar")).toBe("src/Foo/Bar")
	end)

	test("trailing slash stripped from plain directory", function()
		expect(folderPathFromFilePath("src/Foo/Bar/")).toBe("src/Foo/Bar")
	end)

	test(".luau extension stripped", function()
		expect(folderPathFromFilePath("src/Foo/Bar.luau")).toBe("src/Foo/Bar")
	end)

	test(".lua extension stripped", function()
		expect(folderPathFromFilePath("src/Foo/Bar.lua")).toBe("src/Foo/Bar")
	end)

	test("init.luau returns parent directory", function()
		expect(folderPathFromFilePath("src/Foo/Bar/init.luau")).toBe("src/Foo/Bar")
	end)

	test("init.lua returns parent directory", function()
		expect(folderPathFromFilePath("src/Foo/Bar/init.lua")).toBe("src/Foo/Bar")
	end)

	test("derived .luau path from deep tree gives correct dir", function()
		expect(folderPathFromFilePath("places/game/server/behavior/trees/Animal.luau")).toBe(
			"places/game/server/behavior/trees/Animal"
		)
	end)
end)

------------------------------------------------------------------------
-- rewriteInstanceRequires
------------------------------------------------------------------------

describe("rewriteInstanceRequires", function()
	local aliases = {
		{ name = "Game", root = "places/game/" },
		{ name = "Common", root = "places/common/" },
	}

	test("path found in index with alias match is rewritten", function()
		local index = {
			["ServerScriptService.Game_Server.behavior.tasks.randomWait"] = "places/game/server/behavior/tasks/randomWait.lua",
		}
		local src = "BT.task(require([[@game/ServerScriptService/Game_Server/behavior/tasks/randomWait]]), nil, {})"
		local result = rewriteInstanceRequires(src, index, aliases)
		expect(result).toBe('BT.task(require("@Game/server/behavior/tasks/randomWait"), nil, {})')
	end)

	test("path not found in index is left unchanged", function()
		local src = "require([[@game/ServerScriptService/Missing/Module]])"
		local result = rewriteInstanceRequires(src, {}, aliases)
		expect(result).toBe(src)
	end)

	test("init.luau path in index strips /init suffix", function()
		local index = { ["Foo.Bar"] = "places/game/foo/bar/init.luau" }
		local result = rewriteInstanceRequires("require([[@game/Foo/Bar]])", index, aliases)
		expect(result).toBe('require("@Game/foo/bar")')
	end)

	test("init.lua path in index strips /init suffix", function()
		local index = { ["Foo.Bar"] = "places/game/foo/bar/init.lua" }
		local result = rewriteInstanceRequires("require([[@game/Foo/Bar]])", index, aliases)
		expect(result).toBe('require("@Game/foo/bar")')
	end)

	test("no alias match emits bare file path require", function()
		local index = { ["Foo.Bar"] = "other/path/bar.lua" }
		local result = rewriteInstanceRequires("require([[@game/Foo/Bar]])", index, aliases)
		expect(result).toBe('require("other/path/bar")')
	end)

	test("multiple instance requires in one source are each rewritten", function()
		local index = {
			["A.X"] = "places/game/a/x.lua",
			["B.Y"] = "places/common/b/y.lua",
		}
		local src = "require([[@game/A/X]]) require([[@game/B/Y]])"
		local result = rewriteInstanceRequires(src, index, aliases)
		expect(result).toBe('require("@Game/a/x") require("@Common/b/y")')
	end)

	test("empty index leaves source unchanged", function()
		local src = "require([[@game/Foo/Bar]])"
		local result = rewriteInstanceRequires(src, {}, {})
		expect(result).toBe(src)
	end)
end)
