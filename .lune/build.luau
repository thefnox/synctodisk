local fs = require("@lune/fs")
local log = require("./libs/log")
local process = require("@lune/process")

type Archs = "aarch64" | "x86_64"

type Platforms = "macos" | "linux" | "windows"

local EXE_NAME = "synctodisk"

local RELEASE_DIR = "release"

local CLI_PATH = "src/init.luau"
local BUNDLE_PATH = `{RELEASE_DIR}/synctodisk.luau`

local BUNDLE_CONFIG = "build/.darklua.json"

local function build_executable(platform: Platforms, arch: Archs)
	local target = `{platform}-{arch}`
	local exe_name = `{EXE_NAME}{platform == "windows" and ".exe" or ""}`
	local exe_path = `{RELEASE_DIR}/{exe_name}`
	local build_result = process.exec("lune", {
		"build",
		BUNDLE_PATH,
		"--output",
		exe_path,
		"--target",
		target,
	}, { stdio = "forward" })
	assert(build_result.ok, build_result.stderr)

	local archive_result: process.ExecResult
	if platform == "windows" then
		archive_result = process.exec("tar", {
			"-czvf",
			`{RELEASE_DIR}/synctodisk-{target}.tar.gz`,
			"-C",
			RELEASE_DIR,
			exe_name,
		}, { stdio = "forward" })
	else
		archive_result = process.exec("tar", {
			"-cJvf",
			`{RELEASE_DIR}/synctodisk-{target}.tar.xz`,
			"-C",
			RELEASE_DIR,
			exe_name,
		}, { stdio = "forward" })
	end

	assert(archive_result.ok, archive_result.stderr)

	fs.removeFile(exe_path)
	log(`Built executable for {target}`)
end

local function build_executables()
	local bundle_result =
		process.exec("darklua", { "process", "--config", BUNDLE_CONFIG, CLI_PATH, BUNDLE_PATH })
	assert(bundle_result.ok, bundle_result.stderr)
	log("Bundled CLI source code")

	build_executable("macos", "x86_64")
	build_executable("macos", "aarch64")
	build_executable("linux", "x86_64")
	build_executable("linux", "aarch64")
	build_executable("windows", "x86_64")

	fs.removeFile(BUNDLE_PATH)
end

do
	if fs.isDir(RELEASE_DIR) then
		fs.removeDir(RELEASE_DIR)
	end
	fs.writeDir(RELEASE_DIR)
end

local start = os.clock()
build_executables()

local elapsed = os.clock() - start
print(string.format("Finished build in %.2f seconds", elapsed))
