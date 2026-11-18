--!strict
-- Formatowanie liczb w stylu Axiom (wspólne dla serwera i klienta).

local Config = require(script.Parent.Config)

local Format = {}

-- 14200 -> "14.2K"
function Format.compact(n: number): string
	local abs = math.abs(n)
	local suffix, div = "", 1
	if abs >= 1e12 then
		suffix, div = "T", 1e12
	elseif abs >= 1e9 then
		suffix, div = "B", 1e9
	elseif abs >= 1e6 then
		suffix, div = "M", 1e6
	elseif abs >= 1e3 then
		suffix, div = "K", 1e3
	end
	local v = n / div
	if div == 1 and abs < 100 then
		return Format.decimal(n)
	end
	local s = if math.abs(v) >= 100 then string.format("%d", math.round(v)) else string.format("%.3g", v)
	return s .. suffix
end

-- Liczba z kilkoma cyframi znaczącymi, bez notacji wykładniczej: 0.00123, 1.5, 12.35.
function Format.decimal(n: number): string
	if n == 0 then
		return "0"
	end
	local abs = math.abs(n)
	if abs >= 1000 then
		return Format.compact(n)
	end
	local digits = math.max(0, 3 - math.floor(math.log10(abs)))
	local s = string.format("%." .. math.min(digits, 10) .. "f", n)
	if string.find(s, "%.") then
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
	end
	return s
end

-- Liczba bez notacji wykładniczej z `digits` cyframi znaczącymi; do pól tekstowych i małych cen.
function Format.plain(n: number, digits: number): string
	if n == 0 then
		return "0"
	end
	local decimals = math.clamp(digits - 1 - math.floor(math.log10(math.abs(n))), 0, 16)
	local s = string.format("%." .. decimals .. "f", n)
	if string.find(s, "%.") then
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
	end
	return s
end

function Format.usd(n: number): string
	if n < 0 then
		return "-$" .. Format.compact(-n)
	end
	return "$" .. Format.compact(n)
end

function Format.rx(n: number): string
	return Format.decimal(n) .. " " .. Config.Currency
end

-- Część całkowita z przecinkami co trzy cyfry: "1234567" -> "1,234,567".
local function group(digits: string): string
	local s = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	return (string.gsub(s, "^,", ""))
end

-- Liczba całkowita z separatorami tysięcy: 1168777 -> "1,168,777".
function Format.int(n: number): string
	return (if n < 0 then "-" else "") .. group(string.format("%d", math.round(math.abs(n))))
end

-- Cena (perpetuals) z separatorami i liczbą miejsc po przecinku zależną od wielkości:
-- 63,919 / 1,790.5 / 74.11 / 0.1234.
function Format.price(n: number): string
	local abs = math.abs(n)
	local decimals = if abs >= 10000 then 0 elseif abs >= 1000 then 1 elseif abs >= 10 then 2 elseif abs >= 1 then 3 else 4
	local s = string.format(`%.{decimals}f`, abs)
	local whole, rest = string.match(s, "^(%d+)(.*)$")
	return (if n < 0 then "-" else "") .. group(whole or s) .. (rest or "")
end

function Format.percent(n: number): string
	return string.format("%s%.2f%%", if n > 0 then "+" else "", n)
end

-- Wiek w skrócie: 45s, 38m, 5h, 22d, 3mo, 2y.
function Format.age(seconds: number): string
	local s = math.max(0, seconds)
	if s < 60 then
		return math.floor(s) .. "s"
	elseif s < 3600 then
		return math.floor(s / 60) .. "m"
	elseif s < 86400 then
		return math.floor(s / 3600) .. "h"
	elseif s < 30 * 86400 then
		return math.floor(s / 86400) .. "d"
	elseif s < 365 * 86400 then
		return math.floor(s / (30 * 86400)) .. "mo"
	end
	return math.floor(s / (365 * 86400)) .. "y"
end

return table.freeze(Format)
