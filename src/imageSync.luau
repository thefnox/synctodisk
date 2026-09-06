--!strict
local fs = require("@lune/fs")

local ImageSync = {}
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local decode: { [number]: number } = {}
for index = 1, #ALPHABET do
	decode[string.byte(ALPHABET, index)] = index - 1
end

-- Each connection owns one bounded transfer. Nothing is written before image_end.
function ImageSync.new(root: string?): ({ [string]: any }) -> { [string]: any }
	local path: string? = nil
	local size = 0
	local received = 0
	local chunks: { string } = {}
	return function(message: { [string]: any }): { [string]: any }
		local ok, result = pcall(function(): string
			assert(root and root ~= "", "Image sync disabled: set imageOutputRoot in config")
			if message.type == "image_check" then
				return "Image sync ready"
			elseif message.type == "image_begin" then
				path = nil
				chunks = {}
				received = 0
				assert(type(message.path) == "table" and #message.path > 0 and #message.path <= 64, "Invalid path")
				local segments: { string } = {}
				for _, segment in message.path do
					assert(type(segment) == "string" and #segment > 0 and #segment <= 200, "Invalid path segment")
					assert(not segment:find('[%c<>:"/\\|?*]') and not segment:match("[%. ]$"), "Unsafe path segment")
					local stem = string.upper(segment:match("^[^.]+") or "")
					assert(
						stem ~= "CON"
							and stem ~= "PRN"
							and stem ~= "AUX"
							and stem ~= "NUL"
							and not stem:match("^COM[1-9]$")
							and not stem:match("^LPT[1-9]$"),
						"Reserved filename"
					)
					table.insert(segments, segment)
				end
				assert(segments[#segments]:sub(-4) == ".png", "Only PNG images are accepted")
				assert(
					type(message.size) == "number"
						and message.size >= 8
						and message.size <= 2 * 1024 * 1024
						and message.size % 1 == 0,
					"Invalid image size"
				)
				size = message.size
				path = root .. "/" .. table.concat(segments, "/")
				return "Image transfer ready"
			elseif message.type == "image_chunk" then
				assert(path, "No active image transfer")
				assert(message.offset == received, "Unexpected chunk offset")
				local data = message.data
				assert(type(data) == "string" and #data > 0 and #data <= 65536 and #data % 4 == 0, "Invalid chunk")
				local output = table.create(#data / 4)
				for index = 1, #data, 4 do
					local a, b, c, d = string.byte(data, index, index + 3)
					assert(decode[a] and decode[b], "Invalid base64")
					local padding = if c == 61 then 2 elseif d == 61 then 1 else 0
					assert(
						(decode[c] or c == 61)
							and (decode[d] or d == 61)
							and (padding == 0 or index + 3 == #data)
							and (c ~= 61 or d == 61),
						"Invalid base64 padding"
					)
					local value = decode[a] * 262144 + decode[b] * 4096 + (decode[c] or 0) * 64 + (decode[d] or 0)
					local triplet =
						string.char(bit32.extract(value, 16, 8), bit32.extract(value, 8, 8), bit32.extract(value, 0, 8))
					output[(index + 3) / 4] = triplet:sub(1, 3 - padding)
				end
				local bytes = table.concat(output)
				assert(received + #bytes <= size, "Image exceeds declared size")
				table.insert(chunks, bytes)
				received += #bytes
				return "Chunk received"
			elseif message.type == "image_end" then
				assert(path and received == size, "Incomplete image")
				local bytes = table.concat(chunks)
				assert(bytes:sub(1, 8) == "\137PNG\13\10\26\10", "Invalid PNG signature")
				local parent = (path :: string):match("^(.*)/[^/]+$") :: string
				fs.writeDir(parent)
				fs.writeFile(path :: string, bytes)
				local written = path
				path = nil
				chunks = {}
				return "Wrote: " .. (written :: string)
			end
			error("Unknown image message")
		end)
		return { type = "ack", success = ok, message = tostring(result) }
	end
end

return ImageSync
