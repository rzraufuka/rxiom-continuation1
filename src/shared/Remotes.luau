--!strict
-- Remote'y są zdefiniowane w default.project.json (ReplicatedStorage.Remotes).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("Remotes")

local function event(name: string): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

local function func(name: string): RemoteFunction
	return folder:WaitForChild(name) :: RemoteFunction
end

return table.freeze({
	-- serwer -> klient
	MarketSnapshot = event("MarketSnapshot"), -- (MarketSnapshot)
	PortfolioChanged = event("PortfolioChanged"), -- (PortfolioState)
	Notify = event("Notify"), -- (Notice)
	TransferReceived = event("TransferReceived"), -- (TransferNotice)
	PerpsSnapshot = event("PerpsSnapshot"), -- (PerpsSnapshot)
	CompleteTutorial = event("CompleteTutorial"), -- klient -> serwer: samouczek obejrzany
	AlertTriggered = event("AlertTriggered"), -- (AlertNotice)
	PulseRadar = event("PulseRadar"), -- (RadarNotice): nowy coin na Pulse dla graczy z Pulse Radar

	-- klient -> serwer
	GetInitialState = func("GetInitialState"), -- () -> InitialState
	Login = func("Login"), -- () -> LoginResult
	GetCandles = func("GetCandles"), -- (ticker) -> { Candle }
	SubmitTrade = func("SubmitTrade"), -- (TradeRequest) -> ActionResult
	PlaceLimitOrder = func("PlaceLimitOrder"), -- (LimitRequest) -> ActionResult
	-- id: string dla zlecenia z księgi, number dla TP/SL
	CancelLimitOrder = func("CancelLimitOrder"), -- (id) -> ActionResult
	ClaimFaucet = func("ClaimFaucet"), -- () -> ActionResult
	CreateCoin = func("CreateCoin"), -- (CreateCoinRequest) -> ActionResult (z Ticker)
	SearchWallets = func("SearchWallets"), -- (query) -> WalletSearch
	GetWalletProfile = func("GetWalletProfile"), -- (userId) -> WalletProfile?
	GetLeaderboard = func("GetLeaderboard"), -- () -> { LeaderboardEntry }
	SetProfilePublic = func("SetProfilePublic"), -- (boolean) -> ActionResult
	FindRecipient = func("FindRecipient"), -- (query) -> RecipientInfo
	SendRxi = func("SendRxi"), -- (TransferRequest) -> ActionResult (z To)
	PerpOrder = func("PerpOrder"), -- (PerpOrderRequest) -> ActionResult
	PerpClose = func("PerpClose"), -- (symbol) -> ActionResult
	PerpCancel = func("PerpCancel"), -- (orderId) -> ActionResult
	GetPerpCandles = func("GetPerpCandles"), -- (symbol, seconds) -> { Candle }?
	CreateAlert = func("CreateAlert"), -- (AlertRequest) -> ActionResult
	DeleteAlert = func("DeleteAlert"), -- (id) -> ActionResult
	BuyUpgrade = func("BuyUpgrade"), -- (id) -> ActionResult
})
