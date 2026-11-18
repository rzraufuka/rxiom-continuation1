--!strict
-- Ustawienia ekonomii i rynku. Kwoty w RX (waluta gry, odpowiednik SOL), wartości dla graczy w $.

export type Timeframe = { Key: string, Seconds: number }
-- Rynek perpetual: Tick to krok ceny w księdze, MaxLeverage maksymalna dźwignia.
export type PerpMarketDef = { Symbol: string, Name: string, Color: string, MaxLeverage: number, Tick: number }

local Config = {
	-- Kurs RX -> $ używany tylko do wyświetlania (market cap, volume, liquidity).
	UsdPerRx = 150,
	TotalSupply = 1_000_000_000,

	-- Nazwa waluty widoczna dla graczy.
	Currency = "RXI",
	StartingBalance = 10,
	-- Prowizja od każdej transakcji (1%), pobierana w RX.
	FeeBps = 100,
	MinTradeRx = 0.001,
	-- Pozostałości tokenów poniżej tej ilości są traktowane jak zero.
	DustTokens = 1e-6,
	-- Limit TP/SL na gracza.
	MaxOpenOrders = 10,
	-- Limit alertów cenowych na gracza.
	MaxAlerts = 20,
	-- Limit zleceń w księdze (order book) na gracza.
	MaxBookOrders = 20,
	-- Cena zlecenia może odbiegać od ceny rynkowej najwyżej tyle razy w górę lub w dół.
	BookPriceBand = 100,
	-- Ile poziomów cenowych z każdej strony księgi trafia do snapshotu.
	BookDepthLevels = 40,
	-- Maksymalna liczba transakcji gracza w oknie 1 sekundy.
	TradeRateLimit = 6,

	TickSeconds = 0.25,
	SnapshotSeconds = 1,
	CandleSeconds = 10,
	CandleHistory = 360,
	SparkPoints = 24,
	-- Ile ostatnich transakcji gracza na coinie pamiętać (znaczniki na wykresie).
	MaxFills = 30,
	TradeFeedLength = 30,
	-- Ile historii rynku symulować przy starcie serwera (pełna doba dla zmian i wolumenu 24h).
	WarmupSeconds = 86400,

	Faucet = { Amount = 1, Cooldown = 300 },

	-- Pulse: coiny tworzone przez graczy, z bonding curve jak na pump.fun.
	Launch = {
		-- Koszt stworzenia coina w RXI (spalany, nie trafia do nikogo).
		Fee = 100,
		StartMarketCap = 4_000,
		-- Po osiągnięciu tego market cap coin "migruje" (trafia do kolumny Migrated na stałe).
		MigrationMarketCap = 40_000,
		-- Wirtualna płynność RXI na starcie; im mniejsza, tym mocniej ruszają cenę pojedyncze zakupy.
		PoolRx = 8,
		-- Od tylu % bonding curve coin trafia do Final Stretch.
		FinalStretch = 50,
		-- Średnia liczba transakcji botów na sekundę na coinie z Pulse.
		Activity = 1,
		-- Sekundy między kolejnymi coinami jednego gracza.
		Cooldown = 60,
		-- Ile coinów z Pulse serwer trzyma na rynku naraz (wszystkie trafiają do snapshotu co sekundę).
		MaxActive = 24,
		Colors = { "F5C542", "526FFF", "2FE3AC", "EC397A", "A855F7", "F7931A", "38BDF8", "84CC16" },
	},

	-- Boty-snajperzy: kupują nowy coin z Pulse w pierwszych sekundach i później sprzedają.
	Snipers = {
		-- Szansa, że coin w ogóle zostanie zesnajpowany, i ilu snajperów przyjdzie.
		Chance = 0.85,
		Min = 2,
		Max = 5,
		-- Pierwszy zakup po tylu sekundach od startu (dev buy zwykle zdąży pierwszy), kolejne co tyle.
		FirstDelay = { 1.5, 4 },
		Gap = { 0.2, 1.2 },
		-- Wielkość zakupu jako ułamek RXI w puli.
		Size = { 0.03, 0.08 },
	},

	SlippageOptions = { 5, 10, 20, 50 },
	PriorityFeeOptions = { 0.0001, 0.001, 0.005 },
	TipOptions = { 0, 0.001, 0.01 },
	DefaultBuyPresets = { 0.01, 0.1, 1, 10 },
	DefaultSellPresets = { 10, 25, 50, 100 },

	Timeframes = {
		{ Key = "1m", Seconds = 60 },
		{ Key = "5m", Seconds = 300 },
		{ Key = "30m", Seconds = 1800 },
		{ Key = "1h", Seconds = 3600 },
		{ Key = "24h", Seconds = 86400 },
	} :: { Timeframe },

	-- Perpetuals: kontrakty z dźwignią na symulowane ceny (w $), zabezpieczenie (margin) w RXI.
	Perps = {
		Markets = {
			{ Symbol = "GHST", Name = "Ghost", Color = "FF5C8A", MaxLeverage = 40, Tick = 1 },
			{ Symbol = "OBBY", Name = "Obby", Color = "22D3EE", MaxLeverage = 25, Tick = 0.1 },
			{ Symbol = "BACON", Name = "Bacon Hair", Color = "F97316", MaxLeverage = 20, Tick = 0.01 },
		} :: { PerpMarketDef },
		-- Prowizja od wartości pozycji: zlecenie rynkowe (taker) i limit (maker).
		TakerFee = 0.00045,
		MakerFee = 0.00015,
		-- Funding co godzinę (longi płacą shortom, gdy stawka dodatnia).
		FundingSeconds = 3600,
		MaxOrders = 10,
		HistoryLength = 40,
		CandleCount = 150,
		Timeframes = { 60, 300, 900, 3600 },
		LeveragePresets = { 1, 2, 5, 10, 20 },
	},
}

return table.freeze(Config)
