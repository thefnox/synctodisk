--!strict
--!optimize 2

---- Imports ----

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

---- Types ----

type Config = {
	place_id: number,
	universe_id: number,
	api_key: string,
	output: string,
	datastore: string?,
	poll_interval: number?,
}

---- Settings ----

local VERSION = (_G.VERSION or "DEBUG") :: string

local DEFAULT_DATASTORE = "BehaviorTrees"
local DEFAULT_POLL_INTERVAL = 5
local DEFAULT_OUTPUT = "trees"
local CONFIG_FILE = "synctodisk.toml"

local OPEN_CLOUD_BASE = "https://apis.roblox.com/datastores/v1/universes"

---- Helpers ----

local quiet = false

local function Style(text: string, style: stdio.Style): string
	return `{stdio.style(style)}{text}{stdio.style("reset")}`
end

local function Color(text: string, color: stdio.Color): string
	return `{stdio.color(color)}{text}{stdio.color("reset")}`
end

local function log(text: string)
	if quiet then
		return
	end
	print(`{Color("[synctodisk]", "cyan")} {text}`)
end

local function err(text: string)
	stdio.ewrite(`{Color("[synctodisk]", "red")} {Color("error:", "red")} {text}\n`)
end

---- Config ----

local function load_config(path: string): Config
	if not fs.isFile(path) then
		err(`Config file not found: {path}`)
		err(`Create a {CONFIG_FILE} with the required fields. See README.md for details.`)
		process.exit(1)
	end

	local contents = fs.readFile(path)
	local ok, config = pcall(serde.decode, "toml" :: "toml", contents)
	if not ok then
		err(`Failed to parse config file: {config}`)
		process.exit(1)
	end

	local cfg = config :: Config

	if not cfg.place_id then
		err("Config missing required field: place_id")
		process.exit(1)
	end

	if not cfg.universe_id then
		err("Config missing required field: universe_id")
		process.exit(1)
	end

	if not cfg.api_key then
		err("Config missing required field: api_key")
		process.exit(1)
	end

	cfg.output = cfg.output or DEFAULT_OUTPUT
	cfg.datastore = cfg.datastore or DEFAULT_DATASTORE
	cfg.poll_interval = cfg.poll_interval or DEFAULT_POLL_INTERVAL

	return cfg
end

---- Sync ----

local function fetch_datastore_keys(config: Config): { string }
	local url =
		`{OPEN_CLOUD_BASE}/{config.universe_id}/standard-datastores/datastore/entries?datastoreName={net.urlEncode(config.datastore or DEFAULT_DATASTORE)}`

	local response = net.request({
		url = url,
		method = "GET",
		headers = {
			["x-api-key"] = config.api_key,
		},
	})

	if not response.ok then
		err(`Failed to list DataStore keys: HTTP {response.statusCode} – {response.body}`)
		process.exit(1)
	end

	local ok, body = pcall(serde.decode, "json" :: "json", response.body)
	if not ok then
		err(`Failed to parse DataStore response: {body}`)
		process.exit(1)
	end

	local keys: { string } = {}
	for _, entry in (body :: any).keys or {} do
		table.insert(keys, entry.key)
	end
	return keys
end

local function fetch_entry(config: Config, key: string): any
	local url =
		`{OPEN_CLOUD_BASE}/{config.universe_id}/standard-datastores/datastore/entries/entry?datastoreName={net.urlEncode(config.datastore or DEFAULT_DATASTORE)}&entryKey={net.urlEncode(key)}`

	local response = net.request({
		url = url,
		method = "GET",
		headers = {
			["x-api-key"] = config.api_key,
		},
	})

	if not response.ok then
		err(`Failed to fetch entry '{key}': HTTP {response.statusCode} – {response.body}`)
		return nil
	end

	local ok, data = pcall(serde.decode, "json" :: "json", response.body)
	if not ok then
		err(`Failed to parse entry '{key}': {data}`)
		return nil
	end

	return data
end

local function sync_once(config: Config)
	log(`Syncing behavior trees from DataStore '{config.datastore}'...`)

	if not fs.isDir(config.output) then
		fs.writeDir(config.output)
	end

	local keys = fetch_datastore_keys(config)

	if #keys == 0 then
		log("No behavior trees found in DataStore.")
		return
	end

	local synced = 0
	for _, key in keys do
		local data = fetch_entry(config, key)
		if data == nil then
			continue
		end

		local safe_name = string.gsub(key, "[^%w%-_]", "_")
		local out_path = `{config.output}/{safe_name}.json`
		local encoded = serde.encode("json", data, true)
		fs.writeFile(out_path, encoded)
		synced += 1
	end

	log(`Synced {synced} behavior tree(s) to '{config.output}/'.`)
end

---- Entry Point ----

print(`{Color("synctodisk", "green")} {VERSION}`)

local args = process.args

local function print_usage()
	print(Color(Style("USAGE:", "bold"), "yellow"))
	print("\tsynctodisk [CONFIG] [OPTIONS]")
	print("")
	print(Color(Style("ARGUMENTS:", "bold"), "yellow"))
	print(`\t{stdio.color("cyan")}[CONFIG]{stdio.color("reset")}\t\tPath to config file (default: {CONFIG_FILE})`)
	print("")
	print(Color(Style("OPTIONS:", "bold"), "yellow"))
	print(`\t{stdio.color("green")}-h, --help{stdio.color("reset")}\t\tPrint this help message`)
	print(`\t{stdio.color("green")}-v, --version{stdio.color("reset")}\t\tPrint version information`)
	print(`\t{stdio.color("green")}-w, --watch{stdio.color("reset")}\t\tContinuously poll and sync on an interval`)
	print(`\t{stdio.color("green")}-q, --quiet{stdio.color("reset")}\t\tSuppress output`)
end

if table.find(args, "-h") or table.find(args, "--help") then
	print_usage()
	return
end

if table.find(args, "-v") or table.find(args, "--version") then
	return
end

local config_path = CONFIG_FILE
for _, arg in args do
	if string.sub(arg, 1, 1) ~= "-" then
		config_path = arg
		break
	end
end

local watch_mode = table.find(args, "-w") ~= nil or table.find(args, "--watch") ~= nil
local quiet_mode = table.find(args, "-q") ~= nil or table.find(args, "--quiet") ~= nil

if quiet_mode then
	quiet = true
end

local config = load_config(config_path)

if watch_mode then
	log(`Watch mode enabled. Polling every {config.poll_interval}s...`)
	log("Press Ctrl+C to stop.")
	while true do
		sync_once(config)
		task.wait(config.poll_interval or DEFAULT_POLL_INTERVAL)
	end
else
	sync_once(config)
end
