local fs = require("@lune/fs")
assert(fs.isFile("src/imageSync.luau"), "Image transport is not implemented")
local images = require("../src/imageSync")
local root = "test/.image-output"
local receive = images.new(root)
local bytes = "\137PNG\13\10\26\10"
local encoded = "iVBORw0KGgo="
assert(receive({ type = "image_begin", path = { "Folder1", "Folder2", "Sword.png" }, size = #bytes }).success)
assert(not receive({ type = "image_chunk", offset = 2, data = encoded }).success)
assert(receive({ type = "image_chunk", offset = 0, data = encoded }).success)
assert(receive({ type = "image_end" }).success)
assert(fs.readFile(root .. "/Folder1/Folder2/Sword.png") == bytes)
assert(receive({ type = "image_begin", path = { "Folder1", "Folder2", "Sword.png" }, size = #bytes }).success)
assert(not receive({ type = "image_end" }).success, "partial transfers must not overwrite")
assert(fs.readFile(root .. "/Folder1/Folder2/Sword.png") == bytes)
for _, name in { "..", "a/b", "a\\b", "C:", "CON", "a.", "a " } do
	assert(not receive({ type = "image_begin", path = { name, "x.png" }, size = #bytes }).success, name)
end
assert(not images.new(nil)({ type = "image_begin", path = { "x.png" }, size = #bytes }).success)
fs.removeDir(root)
print("PASS: image writes, ordering, incomplete overwrite protection, unsafe paths, opt-in")
