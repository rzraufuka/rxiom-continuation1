--!strict
-- Strona Wallet Tracker: wyszukiwanie graczy (nazwa Roblox, nazwa wyświetlana albo adres portfela),
-- profil z publicznymi statystykami, ranking po zrealizowanym PnL i przełącznik prywatności.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Coins = require(ReplicatedStorage.Shared.Coins)
local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Types = require(ReplicatedStorage.Shared.Types)

local State = script.Parent.Parent.Parent.State
local Market = require(State.Market)
local Portfolio = require(State.Portfolio)
local Tracker = require(State.Tracker)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)

type WalletProfile = Types.WalletProfile
type LeaderboardEntry = Types.LeaderboardEntry

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local RIGHT_WIDTH = 380
local GAP = 20
local HEADER_HEIGHT = 76
local ROW_HEIGHT = 66
local BOARD_REFRESH_SECONDS = 30
local MUTED = Colors.TextMuted:ToHex()

export type TrackerPage = {
	Frame: Frame,
	Refresh: () -> (),
}

local TrackerPage = {}

-- Karta jak na Discover: obrys do środka, bo przewijane listy w środku przycinają obrys zewnętrzny.
local function card(name: string): Frame
	return create("Frame", {
		Name = name,
		BackgroundColor3 = Colors.Surface,
	}, {
		Util.corner(16),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
	})
end

local function scroller(name: string): ScrollingFrame
	return create("ScrollingFrame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = Colors.Border,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	})
end

local avatarCache: { [number]: string } = {}

-- Okrągły awatar gracza (headshot), wczytywany w tle.
local function avatar(userId: number, size: number): ImageLabel
	local image: ImageLabel = create("ImageLabel", {
		Name = "Avatar",
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Colors.Elevated,
		Image = avatarCache[userId] or "",
	}, { Util.round() })
	if not avatarCache[userId] then
		task.spawn(function()
			local ok, content = pcall(
				Players.GetUserThumbnailAsync,
				Players,
				userId,
				Enum.ThumbnailType.HeadShot,
				Enum.ThumbnailSize.Size100x100
			)
			if ok then
				avatarCache[userId] = content
				image.Image = content
			end
		end)
	end
	return image
end

local function shortWallet(wallet: string): string
	return string.sub(wallet, 1, 4) .. "..." .. string.sub(wallet, -4)
end

local function signedRx(n: number): string
	return (if n > 0 then "+" else "") .. Format.rx(n)
end

local function pill(text: string, order: number, color: Color3?): Frame
	local frame: Frame = create("Frame", {
		Name = "Pill",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 26),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = order,
	}, { Util.round(), Util.padding(0, 12), Util.hlist(6) })
	Util.text({ Text = text, Size = 13, Font = Fonts.SemiBold, Color = color or Colors.Text, Order = 1, Parent = frame })
	return frame
end

local function clear(parent: Instance)
	for _, child in parent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function TrackerPage.new(openCoin: (string) -> ()): TrackerPage
	local localUserId = Players.LocalPlayer.UserId

	local frame: Frame = create("Frame", {
		Name = "Trackers",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
	})

	------------------------------------------------------------------
	-- Lewa karta: wyszukiwarka, wyniki i profil

	local main = card("Tracker")
	main.Size = UDim2.new(1, -(RIGHT_WIDTH + GAP), 1, 0)
	main.Parent = frame
	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		Parent = main,
	}, { Util.padding(0, 24) })
	Util.label({
		Name = "Title",
		Text = "Wallet Tracker",
		Size = 22,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.new(0, 220, 1, 0),
		Parent = header,
	})
	local searchBox = create("Frame", {
		Name = "Search",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(380, 38),
		BackgroundColor3 = Colors.Background,
		Parent = header,
	}, { Util.round(), Util.stroke(Colors.Border), Util.padding(0, 6, 0, 14) })
	local searchIcon = Icons.search(15, Colors.TextMuted)
	searchIcon.AnchorPoint = Vector2.new(0, 0.5)
	searchIcon.Position = UDim2.fromScale(0, 0.5)
	searchIcon.Parent = searchBox
	local input: TextBox = create("TextBox", {
		Name = "Input",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.new(1, -110, 1, 0),
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = "Username, display name or wallet",
		PlaceholderColor3 = Colors.TextMuted,
		TextColor3 = Colors.Text,
		TextSize = 15,
		FontFace = Fonts.Regular,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = searchBox,
	})
	local searchButton: TextButton = create("TextButton", {
		Name = "Go",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(78, 28),
		BackgroundColor3 = Colors.Primary,
		Text = "Search",
		TextSize = 14,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.OnPrimary,
		Parent = searchBox,
	}, { Util.round() })
	Util.hoverBackground(searchButton, Colors.Primary, Colors.PrimaryHover)

	local headerDivider = Util.divider(false, Colors.Divider)
	headerDivider.Position = UDim2.fromOffset(24, HEADER_HEIGHT)
	headerDivider.Size = UDim2.new(1, -48, 0, 1)
	headerDivider.Parent = main

	local results = scroller("Results")
	results.Position = UDim2.fromOffset(0, HEADER_HEIGHT + 1)
	results.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + 1))
	results.Parent = main
	Util.padding(8, 16, 12, 16).Parent = results
	Util.vlist(0, nil, Enum.VerticalAlignment.Top).Parent = results

	local status = Util.label({
		Name = "Status",
		Text = "",
		Size = 15,
		Color = Colors.TextMuted,
		AlignX = Enum.TextXAlignment.Center,
		Position = UDim2.fromOffset(40, HEADER_HEIGHT + 40),
		FrameSize = UDim2.new(1, -80, 0, 60),
		Parent = main,
	})
	status.TextWrapped = true

	local profileView = scroller("Profile")
	profileView.Position = UDim2.fromOffset(0, HEADER_HEIGHT + 1)
	profileView.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + 1))
	profileView.Visible = false
	profileView.Parent = main
	Util.padding(20, 24, 24, 24).Parent = profileView
	Util.vlist(18, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = profileView

	------------------------------------------------------------------
	-- Prawa kolumna: własny profil i ranking

	local side = scroller("Side")
	side.AnchorPoint = Vector2.new(1, 0)
	side.Position = UDim2.fromScale(1, 0)
	side.Size = UDim2.new(0, RIGHT_WIDTH, 1, 0)
	side.ScrollBarThickness = 0
	side.Parent = frame
	Util.vlist(GAP, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = side

	local mine = card("YourProfile")
	mine.Size = UDim2.fromScale(1, 0)
	mine.AutomaticSize = Enum.AutomaticSize.Y
	mine.LayoutOrder = 1
	mine.Parent = side
	Util.padding(20).Parent = mine
	Util.vlist(12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = mine
	local mineHeader = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 30),
		LayoutOrder = 1,
		Parent = mine,
	})
	Util.label({
		Text = "Your profile",
		Size = 20,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.new(1, -70, 1, 0),
		Parent = mineHeader,
	})
	-- Przełącznik publiczny / prywatny
	local toggle: TextButton = create("TextButton", {
		Name = "PublicToggle",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(50, 28),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		Parent = mineHeader,
	}, { Util.round(), Util.stroke(Colors.Border) })
	local knob: Frame = create("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 4, 0.5, 0),
		Size = UDim2.fromOffset(20, 20),
		BackgroundColor3 = Colors.TextMuted,
		Parent = toggle,
	}, { Util.round() })
	local privacyTitle =
		Util.text({ Text = "", Size = 15, Font = Fonts.SemiBold, Order = 2, Parent = mine })
	local privacyText = Util.label({
		Name = "Explanation",
		Text = "",
		Size = 14,
		Color = Colors.TextMuted,
		FrameSize = UDim2.fromScale(1, 0),
		Order = 3,
		Parent = mine,
	})
	privacyText.AutomaticSize = Enum.AutomaticSize.Y
	privacyText.TextWrapped = true
	privacyText.TextTruncate = Enum.TextTruncate.None
	local viewMine: TextButton = create("TextButton", {
		Name = "ViewMine",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = Colors.Elevated,
		Text = "View my stats",
		TextSize = 15,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.Text,
		LayoutOrder = 4,
		Parent = mine,
	}, { Util.round() })
	Util.hoverBackground(viewMine, Colors.Elevated, Colors.Border)

	local board = card("Leaderboard")
	board.Size = UDim2.fromScale(1, 0)
	board.AutomaticSize = Enum.AutomaticSize.Y
	board.LayoutOrder = 2
	board.Parent = side
	Util.padding(20, 20, 14, 20).Parent = board
	Util.vlist(8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top).Parent = board
	local boardTitle = Util.label({
		Name = "Title",
		Text = `Leaderboard <font color="#{MUTED}">· Realized PnL</font>`,
		Size = 20,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.new(1, 0, 0, 30),
		Order = 1,
		Parent = board,
	})
	boardTitle.RichText = true
	local boardList: Frame = create("Frame", {
		Name = "List",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = board,
	}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
	local boardEmpty = Util.label({
		Name = "Empty",
		Text = "No public traders with profit yet",
		Size = 14,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(1, 0, 0, 40),
		Order = 3,
		Parent = board,
	})

	------------------------------------------------------------------

	local request = 0
	local lastResults: { WalletProfile } = {}
	local openProfile: (userId: number, fromResults: boolean) -> ()

	local function showStatus(text: string)
		status.Text = text
		status.Visible = text ~= ""
	end

	local function resultRow(profile: WalletProfile, order: number): TextButton
		local row: TextButton = create("TextButton", {
			Name = "Result" .. profile.UserId,
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundColor3 = Colors.SurfaceHover,
			BackgroundTransparency = 1,
			Text = "",
			LayoutOrder = order,
		}, { Util.corner(12), Util.padding(0, 10) })
		local divider = Util.divider(false, Colors.Divider)
		divider.AnchorPoint = Vector2.new(0, 1)
		divider.Position = UDim2.fromScale(0, 1)
		divider.Parent = row
		local image = avatar(profile.UserId, 40)
		image.AnchorPoint = Vector2.new(0, 0.5)
		image.Position = UDim2.fromScale(0, 0.5)
		image.Parent = row
		Util.label({
			Text = profile.DisplayName .. (if profile.UserId == localUserId then "  (you)" else ""),
			Size = 16,
			Font = Fonts.SemiBold,
			Position = UDim2.fromOffset(54, 13),
			FrameSize = UDim2.new(0.5, -54, 0, 20),
			Parent = row,
		})
		local sub = `@{profile.Name}`
		if profile.Wallet then
			sub ..= "  ·  " .. shortWallet(profile.Wallet)
		end
		if profile.Online then
			sub ..= "  ·  online"
		end
		Util.label({
			Text = sub,
			Size = 13,
			Color = Colors.TextMuted,
			Position = UDim2.fromOffset(54, 35),
			FrameSize = UDim2.new(0.5, -54, 0, 16),
			Parent = row,
		})
		if profile.Value and profile.Realized then
			Util.label({
				Text = Format.rx(profile.Value),
				Size = 16,
				Font = Fonts.Medium,
				AlignX = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 13),
				FrameSize = UDim2.new(0.45, 0, 0, 20),
				Parent = row,
			})
			Util.label({
				Text = `PnL {signedRx(profile.Realized)}`,
				Size = 13,
				Color = Util.changeColor(profile.Realized),
				AlignX = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, 0, 0, 35),
				FrameSize = UDim2.new(0.45, 0, 0, 16),
				Parent = row,
			})
		else
			local lock = pill("Private", 0, Colors.TextMuted)
			lock.AnchorPoint = Vector2.new(1, 0.5)
			lock.Position = UDim2.fromScale(1, 0.5)
			lock.Parent = row
		end
		Util.hoverBackground(row, Colors.SurfaceHover, Colors.SurfaceHover, 1)
		row.Activated:Connect(function()
			openProfile(profile.UserId, true)
		end)
		return row
	end

	local function showResults()
		profileView.Visible = false
		results.Visible = true
		clear(results)
		for i, profile in lastResults do
			resultRow(profile, i).Parent = results
		end
	end

	local function statCell(parent: Instance, order: number, title: string, value: string, sub: string, color: Color3?)
		local cell: Frame = create("Frame", {
			Name = title,
			BackgroundColor3 = Colors.Elevated,
			LayoutOrder = order,
			Parent = parent,
		}, { Util.corner(12), Util.padding(14, 16), Util.vlist(4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
		Util.text({ Text = title, Size = 13, Color = Colors.TextMuted, Order = 1, Parent = cell })
		Util.text({ Text = value, Size = 22, Font = Fonts.Bold, Color = color, Order = 2, Parent = cell })
		Util.text({ Text = sub, Size = 13, Color = Colors.TextMuted, Order = 3, Parent = cell })
	end

	local function favoriteRow(parent: Instance, order: number, favorite: Types.FavoriteToken, total: number)
		local def = Coins.get(favorite.Ticker)
		local row: TextButton = create("TextButton", {
			Name = favorite.Ticker,
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 58),
			BackgroundColor3 = Colors.SurfaceHover,
			BackgroundTransparency = 1,
			Text = "",
			LayoutOrder = order,
			Parent = parent,
		}, { Util.corner(10), Util.padding(0, 10) })
		local icon = Icons.token(if def then def.Color else Colors.TextMuted, favorite.Ticker, 36, nil, true)
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.fromScale(0, 0.5)
		icon.Parent = row
		local name = favorite.Name or (if def then def.Name else nil)
		local title = Util.label({
			Text = `<b>{favorite.Ticker}</b>` .. (if name then `  <font color="#{MUTED}">{name}</font>` else ""),
			Size = 15,
			Font = Fonts.Medium,
			Position = UDim2.fromOffset(50, 10),
			FrameSize = UDim2.new(0.6, -50, 0, 20),
			Parent = row,
		})
		title.RichText = true
		local share = if total > 0 then favorite.Volume / total else 0
		local track: Frame = create("Frame", {
			Name = "Share",
			Position = UDim2.fromOffset(50, 38),
			Size = UDim2.new(0.6, -50, 0, 5),
			BackgroundColor3 = Colors.Elevated,
			BorderSizePixel = 0,
			Parent = row,
		}, { Util.round() })
		create("Frame", {
			Name = "Fill",
			Size = UDim2.fromScale(share, 1),
			BackgroundColor3 = if def then def.Color else Colors.Text,
			BorderSizePixel = 0,
			Parent = track,
		}, { Util.round() })
		Util.label({
			Text = Format.rx(favorite.Volume),
			Size = 15,
			Font = Fonts.Medium,
			AlignX = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 10),
			FrameSize = UDim2.new(0.4, 0, 0, 20),
			Parent = row,
		})
		Util.label({
			Text = string.format("%d%% of volume", math.round(share * 100)),
			Size = 13,
			Color = Colors.TextMuted,
			AlignX = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 32),
			FrameSize = UDim2.new(0.4, 0, 0, 16),
			Parent = row,
		})
		Util.hoverBackground(row, Colors.SurfaceHover, Colors.SurfaceHover, 1)
		row.Activated:Connect(function()
			if Market.coin(favorite.Ticker) then
				openCoin(favorite.Ticker)
			end
		end)
	end

	local function renderProfile(profile: WalletProfile, fromResults: boolean)
		clear(profileView)
		results.Visible = false
		profileView.Visible = true
		showStatus("")
		local isMe = profile.UserId == localUserId

		if fromResults then
			local back: TextButton = create("TextButton", {
				Name = "Back",
				AutoButtonColor = false,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, 32),
				BackgroundColor3 = Colors.Elevated,
				Text = "",
				LayoutOrder = 0,
				Parent = profileView,
			}, { Util.round(), Util.padding(0, 14, 0, 10), Util.hlist(6) })
			Icons.chevron(14, Colors.Text, "Left", 1).Parent = back
			Util.text({ Text = "Results", Size = 14, Font = Fonts.SemiBold, Order = 2, Parent = back })
			Util.hoverBackground(back, Colors.Elevated, Colors.Border)
			back.Activated:Connect(showResults)
		end

		-- Nagłówek: awatar, nazwy, portfel i odznaki
		local top = Util.group("Identity", 1, Util.hlist(18))
		top.Parent = profileView
		local image = avatar(profile.UserId, 76)
		image.LayoutOrder = 1
		image.Parent = top
		local identity = Util.group("Names", 2, Util.vlist(6))
		identity.Parent = top
		Util.text({
			Text = profile.DisplayName .. (if isMe then "  (you)" else ""),
			Size = 26,
			Font = Fonts.Bold,
			Order = 1,
			Parent = identity,
		})
		local walletText = `@{profile.Name}`
		if profile.Wallet then
			walletText ..= "  ·  " .. profile.Wallet
		end
		local walletLabel = Util.text({ Text = walletText, Size = 14, Color = Colors.TextMuted, Order = 2, Parent = identity })
		walletLabel.FontFace = Fonts.Mono
		local badges = Util.group("Badges", 3, Util.hlist(8))
		badges.Parent = identity
		if profile.Public or isMe then
			pill(if profile.Rank then `#{profile.Rank} on leaderboard` else "Unranked", 1, Colors.Text).Parent = badges
		end
		if profile.Online then
			pill("Online", 2, Colors.Green).Parent = badges
		elseif profile.UpdatedAt then
			pill(`Updated {Format.age(Market.now() - profile.UpdatedAt)} ago`, 2, Colors.TextMuted).Parent = badges
		end
		if isMe then
			pill(if profile.Public then "Public" else "Private · only you see this", 3, Colors.TextMuted).Parent = badges
		end

		local value, realized = profile.Value, profile.Realized
		if not value or not realized then
			local box: Frame = create("Frame", {
				Name = "Private",
				Size = UDim2.new(1, 0, 0, 160),
				BackgroundColor3 = Colors.Elevated,
				LayoutOrder = 2,
				Parent = profileView,
			}, { Util.corner(12), Util.vlist(10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center) })
			Icons.lock(24, Colors.TextMuted, 1).Parent = box
			Util.text({ Text = "This profile is private", Size = 18, Font = Fonts.SemiBold, Order = 2, Parent = box })
			Util.text({
				Text = `{profile.DisplayName} keeps their RXIOM stats to themselves.`,
				Size = 14,
				Color = Colors.TextMuted,
				Order = 3,
				Parent = box,
			})
			return
		end

		local grid: Frame = create("Frame", {
			Name = "Stats",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 96),
			LayoutOrder = 2,
			Parent = profileView,
		}, {
			create("UIGridLayout", {
				CellSize = UDim2.new(0.25, -9, 1, 0),
				CellPadding = UDim2.fromOffset(12, 0),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		})
		local volume, trades = profile.Volume or 0, profile.Trades or 0
		statCell(grid, 1, "Portfolio value", Format.rx(value), Format.usd(value * Config.UsdPerRx))
		statCell(
			grid,
			2,
			"Realized PnL",
			signedRx(realized),
			Format.usd(realized * Config.UsdPerRx),
			if math.abs(realized) < 1e-9 then nil else Util.changeColor(realized)
		)
		statCell(grid, 3, "Trading volume", Format.rx(volume), Format.usd(volume * Config.UsdPerRx))
		statCell(grid, 4, "Transactions", Format.compact(trades), if trades == 1 then "trade" else "trades")

		Util.text({ Text = "Favorite tokens", Size = 18, Font = Fonts.SemiBold, Order = 3, Parent = profileView })
		local favorites: { Types.FavoriteToken } = profile.Favorites or {}
		local list: Frame = create("Frame", {
			Name = "Favorites",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 4,
			Parent = profileView,
		}, { Util.vlist(0, nil, Enum.VerticalAlignment.Top) })
		if #favorites == 0 then
			Util.text({ Text = "No trades yet", Size = 14, Color = Colors.TextMuted, Order = 1, Parent = list })
		end
		for i, favorite in favorites do
			favoriteRow(list, i, favorite, volume)
		end
	end

	openProfile = function(userId: number, fromResults: boolean)
		request += 1
		local mine = request
		results.Visible = false
		profileView.Visible = false
		showStatus("Loading profile...")
		task.spawn(function()
			local profile = Tracker.profile(userId)
			if mine ~= request then
				return
			end
			if not profile then
				showStatus("Couldn't load this profile, try again")
				if fromResults then
					task.delay(1.5, function()
						if mine == request then
							showStatus("")
							showResults()
						end
					end)
				end
				return
			end
			renderProfile(profile, fromResults)
		end)
	end

	local function runSearch()
		local query = input.Text
		request += 1
		local mine = request
		profileView.Visible = false
		results.Visible = true
		clear(results)
		showStatus("Searching...")
		task.spawn(function()
			local found = Tracker.search(query)
			if mine ~= request then
				return
			end
			if not found.Ok then
				showStatus(found.Error or "Search failed")
				return
			end
			lastResults = found.Results
			showResults()
			showStatus(if #lastResults == 0 then "No public traders found" else "")
		end)
	end

	local function boardRow(entry: LeaderboardEntry): TextButton
		local row: TextButton = create("TextButton", {
			Name = "Rank" .. entry.Rank,
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 48),
			BackgroundColor3 = Colors.SurfaceHover,
			BackgroundTransparency = 1,
			Text = "",
			LayoutOrder = entry.Rank,
		}, { Util.corner(10), Util.padding(0, 6) })
		Util.label({
			Text = tostring(entry.Rank),
			Size = 15,
			Font = Fonts.SemiBold,
			Color = if entry.Rank <= 3 then Colors.Text else Colors.TextMuted,
			AlignX = Enum.TextXAlignment.Center,
			FrameSize = UDim2.new(0, 26, 1, 0),
			Parent = row,
		})
		local image = avatar(entry.UserId, 30)
		image.AnchorPoint = Vector2.new(0, 0.5)
		image.Position = UDim2.new(0, 32, 0.5, 0)
		image.Parent = row
		Util.label({
			Text = entry.DisplayName .. (if entry.UserId == localUserId then " (you)" else ""),
			Size = 15,
			Font = Fonts.Medium,
			Position = UDim2.fromOffset(72, 0),
			FrameSize = UDim2.new(1, -190, 1, 0),
			Parent = row,
		})
		Util.label({
			Text = signedRx(entry.Realized),
			Size = 15,
			Font = Fonts.SemiBold,
			Color = Colors.Green,
			AlignX = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			FrameSize = UDim2.new(0, 116, 1, 0),
			Parent = row,
		})
		Util.hoverBackground(row, Colors.SurfaceHover, Colors.SurfaceHover, 1)
		row.Activated:Connect(function()
			openProfile(entry.UserId, false)
		end)
		return row
	end

	local loadingBoard = false
	local function refreshBoard()
		if loadingBoard then
			return
		end
		loadingBoard = true
		task.spawn(function()
			local entries = Tracker.leaderboard()
			loadingBoard = false
			if not entries then
				return
			end
			clear(boardList)
			for _, entry in entries do
				boardRow(entry).Parent = boardList
			end
			boardEmpty.Visible = #entries == 0
		end)
	end

	local function refreshPrivacy()
		local public = Portfolio.State.Public
		toggle.BackgroundColor3 = if public then Colors.Green else Colors.Elevated
		knob.Position = if public then UDim2.new(1, -24, 0.5, 0) else UDim2.new(0, 4, 0.5, 0)
		knob.BackgroundColor3 = if public then Colors.OnPrimary else Colors.TextMuted
		privacyTitle.Text = if public then "Public profile" else "Private profile"
		privacyText.Text = if public
			then "Anyone can see your portfolio value, realized PnL, volume, trades, favorite tokens and wallet address, and you can appear on the leaderboard. Your balance and positions stay hidden."
			else "Nobody else can see your stats or wallet, you're not on the leaderboard, and you trade under an anonymous address. Turn this on to share your stats."
	end

	local switching = false
	toggle.Activated:Connect(function()
		if switching then
			return
		end
		switching = true
		Tracker.setPublic(not Portfolio.State.Public)
		switching = false
		refreshBoard()
	end)
	viewMine.Activated:Connect(function()
		openProfile(localUserId, false)
	end)
	searchButton.Activated:Connect(runSearch)
	input.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			runSearch()
		end
	end)
	Portfolio.Changed:Connect(refreshPrivacy)

	showStatus(
		"Search for a trader by Roblox username, display name or Ghostbox wallet address. Only public profiles show their stats."
	)
	refreshPrivacy()

	task.spawn(function()
		while true do
			task.wait(BOARD_REFRESH_SECONDS)
			if frame.Visible then
				refreshBoard()
			end
		end
	end)

	return {
		Frame = frame,
		Refresh = function()
			refreshPrivacy()
			refreshBoard()
		end,
	}
end

return TrackerPage
