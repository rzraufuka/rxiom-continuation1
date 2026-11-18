--!strict
-- Struktury danych przesyłane między serwerem a klientem.

export type Side = "Buy" | "Sell"

export type TimeframeStats = {
	Volume: number, -- $
	Buys: number,
	Sells: number,
	Change: number, -- %
}

-- Świeca: ceny w RX za token; T to początek okresu (czas serwera).
export type Candle = { T: number, O: number, H: number, L: number, C: number }

-- Poziom księgi zleceń graczy: cena (RX za token), suma pozostałych tokenów i liczba zleceń.
export type BookLevel = { Price: number, Tokens: number, Orders: number }

-- Bids malejąco, Asks rosnąco po cenie.
export type BookDepth = { Bids: { BookLevel }, Asks: { BookLevel } }

-- Coin z Pulse (stworzony przez gracza). Name i Color pozwalają klientowi poznać nowy coin.
export type LaunchInfo = {
	Name: string,
	Color: Color3,
	Creator: string,
	-- Postęp bonding curve w % (0-100).
	Progress: number,
	Migrated: boolean,
	MigratedAt: number?,
}

export type CoinSnapshot = {
	Ticker: string,
	Book: BookDepth,
	Launch: LaunchInfo?,
	Price: number,
	PoolRx: number,
	PoolTokens: number,
	MarketCap: number,
	Liquidity: number,
	Holders: number,
	LaunchedAt: number,
	Stats: { [string]: TimeframeStats },
	Candle: Candle,
	Spark: { number },
}

export type TradeEvent = {
	Ticker: string,
	Side: Side,
	Rx: number,
	Tokens: number,
	MarketCap: number,
	Trader: string,
	IsPlayer: boolean,
	Time: number,
}

export type MarketSnapshot = {
	Time: number,
	Coins: { [string]: CoinSnapshot },
	Trades: { TradeEvent },
}

-- Wykonana transakcja gracza; Price to średnia cena wykonania (RX za token) bez prowizji.
export type Fill = {
	T: number,
	Side: Side,
	Price: number,
	Tokens: number,
}

-- BuyTokens/BuyValue liczą średnią cenę wejścia (BuyValue / BuyTokens) dla bieżącej pozycji.
export type Position = {
	Tokens: number,
	BoughtRx: number,
	SoldRx: number,
	BuyTokens: number,
	BuyValue: number,
	Fills: { Fill },
}

-- TP/SL po kupnie: sprzedaj Tokens, gdy MC ($) >= Above albo MC <= Below. Tokeny są zablokowane.
export type TriggerOrder = {
	Id: number,
	Ticker: string,
	Tokens: number,
	Fees: number,
	Above: number,
	Below: number,
	CreatedAt: number,
}

-- Zlecenie z limitem ceny w księdze. Price w RX za token, Tokens to pozostała ilość.
-- Kupno rezerwuje RX (Reserved), sprzedaż blokuje tokeny. Zlecenie jest zapisywane w profilu
-- i wisi w księdze, dopóki nie zostanie wykonane albo anulowane.
export type BookOrder = {
	Id: string,
	Ticker: string,
	Side: Side,
	Price: number,
	Tokens: number,
	Filled: number,
	Reserved: number,
	CreatedAt: number,
}

export type PortfolioState = {
	Balance: number,
	Positions: { [string]: Position },
	Orders: { BookOrder },
	Triggers: { TriggerOrder },
	FaucetReadyAt: number,
	Wallet: string?,
	-- Czy profil jest publiczny w Wallet Trackerze.
	Public: boolean,
	-- Anonimowy adres, pod którym prywatny gracz widnieje w listach transakcji (w tej sesji).
	Alias: string,
	Perps: PerpAccount,
	TutorialDone: boolean,
	Alerts: { PriceAlert },
	Upgrades: { [string]: number },
}

-- Statystyki handlu gracza (zapisywane w profilu). Basis: tokeny i ich koszt w RX do liczenia
-- zrealizowanego PnL metodą średniego kosztu.
export type TradeStats = {
	Volume: number,
	Trades: number,
	Realized: number,
	TokenVolume: { [string]: number },
	Basis: { [string]: { Tokens: number, Cost: number } },
}

export type FavoriteToken = { Ticker: string, Name: string?, Volume: number }

-- Profil w Wallet Trackerze. Liczby i adres portfela są tylko w profilach publicznych (albo we
-- własnym profilu gracza); prywatny profil to sama nazwa.
export type WalletProfile = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Public: boolean,
	Online: boolean,
	Wallet: string?,
	Value: number?,
	Realized: number?,
	Volume: number?,
	Trades: number?,
	Favorites: { FavoriteToken }?,
	Rank: number?,
	-- Czas serwera, z którego pochodzą dane gracza offline.
	UpdatedAt: number?,
}

export type WalletSearch = { Ok: boolean, Error: string?, Results: { WalletProfile } }

export type LeaderboardEntry = {
	Rank: number,
	UserId: number,
	Name: string,
	DisplayName: string,
	Realized: number,
}

export type LoginResult = {
	Ok: boolean,
	Error: string?,
	Wallet: string?,
	-- true, gdy portfel został właśnie utworzony (pierwsze logowanie).
	New: boolean?,
}

-- Amount: RX przy kupnie, procent posiadanych tokenów przy sprzedaży.
export type TradeRequest = {
	Ticker: string,
	Side: Side,
	Amount: number,
	ExpectedOut: number,
	Slippage: number,
	PriorityFee: number,
	Tip: number,
	Bracket: { TakeProfit: number, StopLoss: number }?,
}

-- Zlecenie do księgi. Price w RX za token; Amount: RX przy kupnie, procent tokenów przy sprzedaży.
export type LimitRequest = {
	Ticker: string,
	Side: Side,
	Price: number,
	Amount: number,
}

-- Nowy coin na Pulse. Color to numer z Config.Launch.Colors.
export type CreateCoinRequest = {
	Name: string,
	Ticker: string,
	Color: number,
}

-- Przelew RXI: To to nazwa użytkownika Roblox albo adres portfela Ghostbox.
export type TransferRequest = { To: string, Amount: number }

-- Podgląd odbiorcy. Nazwy i UserId są tylko wtedy, gdy nie zdradzają prywatnego gracza
-- (wpisana nazwa albo publiczny profil); dla samego adresu prywatnego portfela jest tylko Wallet.
export type RecipientInfo = {
	Ok: boolean,
	Error: string?,
	UserId: number?,
	Name: string?,
	DisplayName: string?,
	Wallet: string?,
	Online: boolean?,
	-- Odbiorcą jest sam gracz (podgląd animacji, bez przesuwania RXI).
	Self: boolean?,
}

-- Powiadomienie odbiorcy o przelewie.
export type TransferNotice = { Amount: number, From: string }

export type ActionResult = {
	Ok: boolean,
	Error: string?,
	Rx: number?,
	Tokens: number?,
	Ticker: string?,
	-- Przelewy: komu wysłano (nazwa albo skrócony adres).
	To: string?,
	-- Przelew do siebie: tylko podgląd, saldo bez zmian.
	Self: boolean?,
}

export type Notice = { Kind: "Success" | "Error" | "Info", Text: string }

-- Alert cenowy: Above / Below to próg market capu w $, Rise / Drop to zmiana o Percent % od
-- market capu z chwili ustawienia (zapisana jako próg MarketCap, kierunek w Direction).
export type AlertKind = "Above" | "Below" | "Rise" | "Drop"

export type PriceAlert = {
	Id: string,
	Ticker: string,
	Kind: AlertKind,
	Direction: "Above" | "Below",
	MarketCap: number,
	Percent: number?,
	CreatedAt: number,
}

export type AlertRequest = { Ticker: string, Kind: AlertKind, Value: number }

-- Wysyłane graczowi, gdy alert zadziała.
export type AlertNotice = { Ticker: string, Kind: AlertKind, Target: number, MarketCap: number, Percent: number? }

------------------------------------------------------------------
-- Perpetuals. Ceny w $, Margin/Pnl/Fee w RXI, Size w jednostkach aktywa (np. GHST).

export type PerpSide = "Long" | "Short"

-- Pozycja z izolowanym marginem. Deposited: wpłacony margin (do zrealizowanego PnL), Funding: suma
-- zapłaconego (-) / otrzymanego (+) fundingu, FundingAt: ostatnia rozliczona godzina.
export type PerpPosition = {
	Symbol: string,
	Side: PerpSide,
	Size: number,
	Entry: number,
	Margin: number,
	Deposited: number,
	Funding: number,
	OpenedAt: number,
	FundingAt: number,
	TP: number?,
	SL: number?,
}

-- Zlecenie limit; Margin i prowizja są zarezerwowane z salda do wykonania albo anulowania.
export type PerpOrder = {
	Id: string,
	Symbol: string,
	Side: PerpSide,
	Price: number,
	Margin: number,
	Leverage: number,
	Reserved: number,
	CreatedAt: number,
	TP: number?,
	SL: number?,
}

export type PerpAction = "Open" | "Close" | "Liquidation" | "TP" | "SL"

export type PerpTrade = {
	T: number,
	Symbol: string,
	Side: PerpSide,
	Action: PerpAction,
	Price: number,
	Size: number,
	Fee: number,
	Pnl: number?,
}

export type PerpAccount = {
	Positions: { [string]: PerpPosition },
	Orders: { PerpOrder },
	History: { PerpTrade },
	-- Do kiedy rozliczono zlecenia, funding i likwidacje (także gdy gracz był offline).
	CheckedAt: number,
}

export type PerpMarket = {
	Symbol: string,
	Mark: number,
	Oracle: number,
	-- Zmiana 24h w %.
	Change: number,
	Volume: number,
	OpenInterest: number,
	-- Stawka fundingu na najbliższą godzinę (ułamek, 0.0000125 = 0.00125%).
	Funding: number,
	NextFunding: number,
}

-- Transakcja gracza widoczna dla wszystkich (Trader: nazwa albo anonimowy alias).
export type PerpPrint = { T: number, Symbol: string, Side: PerpSide, Price: number, Size: number, Trader: string }

export type PerpsSnapshot = { T: number, Markets: { [string]: PerpMarket }, Prints: { PerpPrint } }

export type PerpOrderRequest = {
	Symbol: string,
	Side: PerpSide,
	Type: "Market" | "Limit",
	Margin: number,
	Leverage: number,
	Price: number?,
	TP: number?,
	SL: number?,
}

export type InitialState = {
	Market: MarketSnapshot,
	Trades: { [string]: { TradeEvent } },
	Portfolio: PortfolioState?,
}

return {}
