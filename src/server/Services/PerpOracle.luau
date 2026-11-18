--!strict
-- Ceny rynków perpetual: deterministyczna funkcja czasu serwera (UTC). Każdy serwer liczy tę samą
-- cenę w tej samej chwili, więc przeskakiwanie między serwerami nic nie daje, a pozycje graczy
-- offline da się rozliczyć wstecz. Moduł jest tylko na serwerze, żeby klient nie mógł przewidzieć cen.
--
-- log(cena) = log(cena bazowa) + suma "value noise" w kilku skalach czasu (15 s ... 16 dni), z
-- amplitudą rosnącą jak pierwiastek z okresu (jak błądzenie losowe), plus drobny szum co sekundę.

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)

type Params = { Seed: number, Price: number, DailyVol: number, Volume: number, OpenInterest: number }

local PARAMS: { [string]: Params } = {
	GHST = { Seed = 1103, Price = 64_000, DailyVol = 0.025, Volume = 3.6e9, OpenInterest = 2.5e9 },
	OBBY = { Seed = 2207, Price = 1_800, DailyVol = 0.032, Volume = 1.4e9, OpenInterest = 9.1e8 },
	BACON = { Seed = 3301, Price = 74, DailyVol = 0.042, Volume = 3.2e8, OpenInterest = 2.1e8 },
}

local OCTAVES = { 15, 60, 300, 1800, 7200, 28_800, 86_400, 345_600, 1_382_400 }
local DAY = 86_400
local CANDLE_SAMPLES = 24

local Oracle = {}

local function mul32(a: number, b: number): number
	local aLo, aHi = a % 65536, a // 65536
	local bLo, bHi = b % 65536, b // 65536
	return ((aHi * bLo + aLo * bHi) % 65536 * 65536 + aLo * bLo) % 4294967296
end

-- Liczba z [-1, 1] wyznaczona przez (seed, i).
local function hash(seed: number, i: number): number
	local h = bit32.bxor(i % 4294967296, mul32(seed, 0x9E3779B1))
	h = mul32(bit32.bxor(h, bit32.rshift(h, 16)), 0x45D9F3B)
	h = mul32(bit32.bxor(h, bit32.rshift(h, 16)), 0x45D9F3B)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 2147483647.5 - 1
end

-- Gładki szum: wartości losowe w punktach całkowitych, wygładzona interpolacja pomiędzy.
local function noise(seed: number, x: number): number
	local i = math.floor(x)
	local f = x - i
	local a, b = hash(seed, i), hash(seed, i + 1)
	return a + (b - a) * f * f * (3 - 2 * f)
end

type Curve = { Base: number, Seed: number, Amps: { number }, Jitter: number }
local curves: { [string]: Curve } = {}
for symbol, p in PARAMS do
	local amps = {}
	for k, period in OCTAVES do
		amps[k] = p.DailyVol * math.sqrt(period / DAY) * 1.4
	end
	curves[symbol] = { Base = math.log(p.Price), Seed = p.Seed, Amps = amps, Jitter = p.DailyVol * 0.004 }
end

function Oracle.has(symbol: string): boolean
	return curves[symbol] ~= nil
end

-- Cena wyroczni (oracle) w $ w chwili `t` (sekundy UTC).
function Oracle.oracle(symbol: string, t: number): number
	local c = curves[symbol]
	local x = c.Base
	for k, period in OCTAVES do
		x += c.Amps[k] * noise(c.Seed * 31 + k, t / period)
	end
	x += c.Jitter * hash(c.Seed * 31 + 99, math.floor(t))
	return math.exp(x)
end

-- Cena mark: oracle z drobną premią. Według niej liczone są PnL, likwidacje i wykonania.
function Oracle.mark(symbol: string, t: number): number
	local c = curves[symbol]
	return Oracle.oracle(symbol, t) * (1 + 0.00015 * noise(c.Seed * 31 + 200, t / 90))
end

-- Stawka fundingu za godzinę `hour` (numer godziny od epoki). Dodatnia: longi płacą shortom.
function Oracle.funding(symbol: string, hour: number): number
	return 0.0000125 + 0.00003 * hash(curves[symbol].Seed * 31 + 300, hour)
end

function Oracle.volume(symbol: string, t: number): number
	local p = PARAMS[symbol]
	return p.Volume * (1 + 0.25 * noise(p.Seed * 31 + 400, t / 21_600))
end

function Oracle.openInterest(symbol: string, t: number): number
	local p = PARAMS[symbol]
	return p.OpenInterest * (1 + 0.15 * noise(p.Seed * 31 + 500, t / 43_200))
end

-- `count` świec po `seconds` sekund kończących się świecą zawierającą `now`. Szczyty i dołki z
-- próbek co seconds/24, więc przy dłuższych świecach pomijają najkrótsze wahania.
function Oracle.candles(symbol: string, seconds: number, count: number, now: number): { { T: number, O: number, H: number, L: number, C: number } }
	local result = {}
	local last = math.floor(now / seconds)
	for b = last - count + 1, last do
		local start = b * seconds
		local finish = math.min(start + seconds, now)
		local open = Oracle.mark(symbol, start)
		local high, low = open, open
		local close = open
		for j = 1, CANDLE_SAMPLES do
			local t = start + (finish - start) * j / CANDLE_SAMPLES
			close = Oracle.mark(symbol, t)
			high = math.max(high, close)
			low = math.min(low, close)
		end
		table.insert(result, { T = start, O = open, H = high, L = low, C = close })
	end
	return result
end

function Oracle.market(symbol: string, now: number): any
	local mark = Oracle.mark(symbol, now)
	local dayAgo = Oracle.mark(symbol, now - DAY)
	local hour = math.floor(now / Config.Perps.FundingSeconds)
	return {
		Symbol = symbol,
		Mark = mark,
		Oracle = Oracle.oracle(symbol, now),
		Change = (mark / dayAgo - 1) * 100,
		Volume = Oracle.volume(symbol, now),
		OpenInterest = Oracle.openInterest(symbol, now),
		Funding = Oracle.funding(symbol, hour + 1),
		NextFunding = (hour + 1) * Config.Perps.FundingSeconds,
	}
end

return Oracle
