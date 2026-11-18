--!strict
-- Coiny na rynku: stała lista (Discover) oraz coiny tworzone przez graczy (Pulse).
-- MarketCap i Liquidity (w $) wyznaczają startową pulę płynności; Activity to średnia liczba
-- transakcji botów na sekundę. Coiny z Pulse mają ustawione Creator.

local Config = require(script.Parent.Config)

export type CoinDef = {
	Ticker: string,
	Name: string,
	Color: Color3,
	Age: number,
	MarketCap: number,
	Liquidity: number,
	Holders: number,
	Activity: number,
	-- Tylko coiny z Pulse: nazwa gracza, który go stworzył.
	Creator: string?,
	-- Tylko stała lista: krótki opis na stronie coina.
	Description: string?,
}

local MINUTE, DAY = 60, 86400

local function coin(
	ticker: string,
	name: string,
	hex: string,
	age: number,
	marketCap: number,
	liquidity: number,
	holders: number,
	activity: number,
	description: string
): CoinDef
	return table.freeze({
		Ticker = ticker,
		Name = name,
		Color = Color3.fromHex(hex),
		Age = age,
		MarketCap = marketCap,
		Liquidity = liquidity,
		Holders = holders,
		Activity = activity,
		Description = description,
	})
end

-- Kolejność jak na liście (Discover, dolny pasek). Coiny z dawnymi zaślepkami COIN1-COIN8 mają ich
-- parametry, więc zapisane pozycje przenoszą się bez zmiany wartości (zob. Coins.rename).
local List: { CoinDef } = {
	coin("ROXI", "Roxi", "A855F7", 22 * DAY, 14_500_000, 213_000, 31281, 0.8, "Maskotka ekosystemu RXIOM"),
	coin("BLOKI", "Blocki", "F7931A", 2 * DAY, 480_000, 41_000, 2940, 1.0, "Coin inspirowany blokowym światem Roblox"),
	coin("NOOB", "Noobium", "F5C542", 38 * MINUTE, 117_000, 14_200, 1082, 1.4, "Memecoin z motywem klasycznego Nooba"),
	coin("RUGB", "Rugby", "EF4444", 10 * MINUTE, 30_300, 7_030, 200, 1.1, "Żart z rug pullów, ale jako sympatyczna maskotka"),
	coin("BLOX", "Bloxor", "38BDF8", 7 * DAY, 2_100_000, 96_000, 9850, 0.9, "Futurystyczny coin z blokowym motywem"),
	coin("RIXI", "Rixie", "EC4899", 2 * MINUTE, 9_600, 2_550, 226, 1.2, "Mały, stylowy coin powiązany z RXI"),
	coin("STUD", "Studz", "94A3B8", 3 * MINUTE, 11_900, 3_100, 150, 1.0, "Inspiracja charakterystycznymi studami Roblox"),
	coin("MBLOX", "Moonblox", "526FFF", 15 * MINUTE, 64_000, 9_800, 512, 1.5, "Coin z motywem kosmosu i moonshotów"),
	coin("RXT", "RXT", "2FE3AC", 90 * DAY, 12_400_000, 241_000, 80492, 0.6, "Token wyglądający jak poważny coin tradingowy"),
	coin("NBC", "NoobCash", "84CC16", 4 * MINUTE, 26_800, 5_790, 386, 1.8, "Humorystyczny coin z motywem noobów"),
	coin("PXR", "PixelR", "D946EF", 1 * MINUTE, 14_000, 3_540, 237, 1.6, "Pixel-artowy coin inspirowany Robloxem"),
	coin("RPRIME", "Roxi Prime", "C4B5FD", 45 * DAY, 6_200_000, 158_000, 6120, 0.5, "Ekskluzywny, premium coin w ekosystemie RXIOM"),
}

-- Dawne tickery -> obecne. Stosowane przy wczytywaniu zapisanych profili.
local RENAMED: { [string]: string } = {
	COIN1 = "NOOB",
	COIN2 = "RUGB",
	COIN3 = "ROXI",
	COIN4 = "PXR",
	COIN5 = "RXT",
	COIN6 = "NBC",
	COIN7 = "RIXI",
	COIN8 = "STUD",
}

local ByTicker: { [string]: CoinDef } = {}
for _, def in List do
	ByTicker[def.Ticker] = def
end

local Coins = {}

-- Stała lista coinów (Discover, dolny pasek).
Coins.List = table.freeze(List)
Coins.ByTicker = table.freeze(ByTicker)

local launched: { [string]: CoinDef } = {}

-- Dowolny znany coin: ze stałej listy albo z Pulse.
function Coins.get(ticker: string): CoinDef?
	return ByTicker[ticker] or launched[ticker]
end

function Coins.register(def: CoinDef)
	launched[def.Ticker] = def
end

function Coins.unregister(ticker: string)
	launched[ticker] = nil
end

-- Obecny ticker dla tickera z zapisu (dawne zaślepki COIN1-COIN8 zmieniły nazwy).
function Coins.rename(ticker: string): string
	return RENAMED[ticker] or ticker
end

-- Wszystkie znane coiny: najpierw stała lista, potem coiny z Pulse alfabetycznie.
function Coins.all(): { CoinDef }
	local result = table.clone(List)
	local extra = {}
	for _, def in launched do
		table.insert(extra, def)
	end
	table.sort(extra, function(a, b)
		return a.Ticker < b.Ticker
	end)
	table.move(extra, 1, #extra, #result + 1, result)
	return result
end

-- Ticker: 2-8 znaków A-Z i 0-9, co najmniej jedna litera.
function Coins.validTicker(ticker: any): boolean
	return typeof(ticker) == "string"
		and #ticker >= 2
		and #ticker <= 8
		and string.find(ticker, "^[A-Z0-9]+$") ~= nil
		and string.find(ticker, "%u") ~= nil
end

-- Nazwa coina z Pulse: 2-24 znaki, litery, cyfry, spacje i . - ! ? ' (bez znaków RichText).
function Coins.validName(name: any): boolean
	return typeof(name) == "string"
		and #name >= 2
		and #name <= 24
		and string.find(name, "^[%w %.%-!%?']+$") ~= nil
		and string.find(name, "%w") ~= nil
end

-- Definicja coina z Pulse; pula startowa wynika z Config.Launch.
function Coins.launch(ticker: string, name: string, color: Color3, creator: string): CoinDef
	return table.freeze({
		Ticker = ticker,
		Name = name,
		Color = color,
		Age = 0,
		MarketCap = Config.Launch.StartMarketCap,
		Liquidity = Config.Launch.PoolRx * 2 * Config.UsdPerRx,
		Holders = 0,
		Activity = Config.Launch.Activity,
		Creator = creator,
	})
end

return Coins
