--!strict
-- Karta Trader Career na stronie Discover: wybór ścieżki, postęp, bieżący rozdział i przycisk akcji.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Career = require(ReplicatedStorage.Shared.Career)
local Coins = require(ReplicatedStorage.Shared.Coins)

local State = script.Parent.Parent.Parent.State
local Favorites = require(State.Favorites)
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Util = require(UI.Util)
local TopBar = require(script.Parent.TopBar)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local ROW_HEIGHT = 36

export type CareerCard = {
	Frame: Frame,
}

local CareerCard = {}

local function firstHeld(): string?
	local held: { string } = {}
	for ticker, position in Portfolio.State.Positions do
		if position.Tokens > 0 then
			table.insert(held, ticker)
		end
	end
	table.sort(held)
	return held[1]
end

local function fallbackCoin(): string?
	local def = Coins.List[1]
	return if def then def.Ticker else nil
end

local function paragraph(text: string, size: number, color: Color3, order: number, parent: Instance): TextLabel
	return create("TextLabel", {
		Name = "Paragraph",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromScale(1, 0),
		Text = text,
		TextSize = size,
		FontFace = Fonts.Medium,
		TextColor3 = color,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextWrapped = true,
		LayoutOrder = order,
		Parent = parent,
	})
end

local function primaryButton(text: string, order: number, parent: Instance): TextButton
	local button: TextButton = create("TextButton", {
		Name = "Action",
		AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = Colors.Primary,
		Text = text,
		TextSize = 14,
		FontFace = Fonts.SemiBold,
		TextColor3 = Colors.OnPrimary,
		LayoutOrder = order,
		Parent = parent,
	}, { Util.round() })
	Util.hoverBackground(button, Colors.Primary, Colors.PrimaryHover)
	return button
end

local function titlePill(title: string, order: number, parent: Instance): Frame
	local frame: Frame = create("Frame", {
		Name = "Title",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundColor3 = Colors.Elevated,
		LayoutOrder = order,
		Parent = parent,
	}, { Util.round(), Util.padding(0, 12), Util.hlist(6) })
	Util.text({ Text = title, Size = 12, Font = Fonts.SemiBold, Color = Colors.Text, Order = 1, Parent = frame })
	return frame
end

function CareerCard.new(navigation: TopBar.Navigation, openCoin: (string) -> (), openChooser: () -> ()): CareerCard
	local frame: Frame = create("Frame", {
		Name = "CareerCard",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Surface,
		LayoutOrder = 0,
	}, {
		Util.corner(16),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
		Util.padding(20),
		Util.vlist(12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})

	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 28),
		LayoutOrder = 1,
		Parent = frame,
	})
	Util.label({
		Name = "Title",
		Text = "Trader Career",
		Size = 20,
		Font = Fonts.SemiBold,
		FrameSize = UDim2.new(1, -96, 1, 0),
		Parent = header,
	})
	local change: TextButton = create("TextButton", {
		Name = "ChangePath",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(88, 24),
		BackgroundTransparency = 1,
		Text = "Change path",
		TextSize = 13,
		FontFace = Fonts.Medium,
		TextColor3 = Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = header,
	})
	change.MouseEnter:Connect(function()
		Util.tween(change, { TextColor3 = Colors.Text })
	end)
	change.MouseLeave:Connect(function()
		Util.tween(change, { TextColor3 = Colors.TextMuted })
	end)
	change.Activated:Connect(openChooser)

	local body: Frame = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = frame,
	}, { Util.vlist(12, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })

	local function actionFor(chapter: Career.Chapter): (string, () -> ())
		local id = chapter.Id
		if id == "Watchlist" then
			return "Browse coins", navigation.Discover
		elseif id == "Alert" then
			return "Open a coin", function()
				local ticker = Favorites.list()[1] or fallbackCoin()
				if ticker then
					openCoin(ticker)
				end
			end
		elseif id == "AlertTriggered" then
			return "View favorites", navigation.Favorites
		elseif id == "LimitPlaced" or id == "LimitBuyFilled" or id == "LimitProfit" then
			return "Open a coin", function()
				local ticker = firstHeld() or Favorites.list()[1] or fallbackCoin()
				if ticker then
					openCoin(ticker)
				end
			end
		end
		return "Open Pulse", navigation.Pulse
	end

	local function chapterRow(chapter: Career.Chapter, status: "Done" | "Current" | "Upcoming", order: number, parent: Instance)
		local row: Frame = create("Frame", {
			Name = chapter.Id,
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
			BackgroundColor3 = Colors.Elevated,
			BackgroundTransparency = if status == "Current" then 0 else 1,
			LayoutOrder = order,
			Parent = parent,
		}, { Util.corner(10), Util.padding(0, 10), Util.hlist(10) })
		local marker: Frame = create("Frame", {
			Name = "Marker",
			Size = UDim2.fromOffset(20, 20),
			BackgroundColor3 = if status == "Done" then Colors.Primary elseif status == "Current" then Colors.Surface else Colors.Elevated,
			LayoutOrder = 1,
			Parent = row,
		}, { Util.round() })
		if status == "Current" then
			Util.stroke(Colors.Text, 1).Parent = marker
		end
		if status == "Done" then
			local check = Icons.check(12, Colors.OnPrimary)
			check.AnchorPoint = Vector2.new(0.5, 0.5)
			check.Position = UDim2.fromScale(0.5, 0.5)
			check.Parent = marker
		else
			Util.label({
				Text = tostring(chapter.Index),
				Size = 11,
				Font = Fonts.SemiBold,
				Color = if status == "Current" then Colors.Text else Colors.TextDim,
				AlignX = Enum.TextXAlignment.Center,
				Parent = marker,
			})
		end
		Util.label({
			Name = "Name",
			Text = chapter.Name,
			Size = 14,
			Font = if status == "Current" then Fonts.SemiBold else Fonts.Medium,
			Color = if status == "Current" then Colors.Text elseif status == "Done" then Colors.TextMuted else Colors.TextDim,
			FrameSize = UDim2.new(1, -30, 1, 0),
			Order = 2,
			Parent = row,
		})
	end

	local function clear()
		for _, child in body:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	end

	local function renderNoPath()
		change.Visible = false
		paragraph(
			"Pick a path and learn the market one short chapter at a time. Chapters award titles shown in the Wallet Tracker.",
			14,
			Colors.TextMuted,
			1,
			body
		)
		primaryButton("Choose a path", 2, body).Activated:Connect(openChooser)
	end

	local function renderPath(career: Career.State, path: Career.Path)
		change.Visible = true
		local done = Career.doneCount(career, path.Id)
		local total = #path.Chapters
		local current = Career.current(career, path.Id)

		local summary = create("Frame", {
			Name = "Summary",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 24),
			LayoutOrder = 1,
			Parent = body,
		}, { Util.hlist(10) })
		local name = Util.text({ Text = `{path.Name} path`, Size = 16, Font = Fonts.SemiBold, Order = 1, Parent = summary })
		name.Name = "PathName"
		Util.text({
			Text = `{done}/{total}`,
			Size = 14,
			Font = Fonts.SemiBold,
			Color = Colors.TextMuted,
			Order = 2,
			Parent = summary,
		}).Name = "Progress"
		if career.Title then
			titlePill(career.Title, 3, summary)
		end

		local rows = create("Frame", {
			Name = "Chapters",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			Parent = body,
		}, { Util.vlist(2, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
		for i, chapter in path.Chapters do
			local status: "Done" | "Current" | "Upcoming" = if career.Done[chapter.Id] then "Done" elseif current and current.Id == chapter.Id then "Current" else "Upcoming"
			chapterRow(chapter, status, i, rows)
		end

		if current then
			local details = create("Frame", {
				Name = "Details",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 3,
				Parent = body,
			}, { Util.vlist(4, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
			paragraph(current.Goal, 14, Colors.Text, 1, details).FontFace = Fonts.SemiBold
			paragraph(current.Hint, 13, Colors.TextMuted, 2, details)
			local label, action = actionFor(current)
			primaryButton(label, 4, body).Activated:Connect(action)
		else
			paragraph(`You finished the {path.Name} path. Nice work!`, 14, Colors.Text, 3, body).FontFace = Fonts.SemiBold
			primaryButton("Try another path", 4, body).Activated:Connect(openChooser)
		end
	end

	local lastSignature = ""
	local function refresh()
		local career = Career.sanitize(Portfolio.State.Career)
		local done: { string } = {}
		for id in career.Done do
			table.insert(done, id)
		end
		table.sort(done)
		local signature = `{career.Path or "-"}|{career.Title or "-"}|{table.concat(done, ",")}`
		if signature == lastSignature then
			return
		end
		lastSignature = signature

		clear()
		local path = if career.Path then Career.path(career.Path) else nil
		if path then
			renderPath(career, path)
		else
			renderNoPath()
		end
	end

	refresh()
	Portfolio.Changed:Connect(refresh)

	return { Frame = frame }
end

return CareerCard
