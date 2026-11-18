--!strict
-- Okno wyboru ścieżki Trader Career: trzy karty obok siebie (Analyst / Trader / Founder)
-- z rozdziałami, tytułami do zdobycia i przyciskiem wyboru.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Career = require(ReplicatedStorage.Shared.Career)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local State = script.Parent.Parent.Parent.State
local Portfolio = require(State.Portfolio)

local UI = script.Parent.Parent
local Icons = require(UI.Icons)
local Theme = require(UI.Theme)
local Toast = require(UI.Toast)
local Util = require(UI.Util)

local create = Util.create
local Colors = Theme.Colors
local Fonts = Theme.Fonts

local CARD_WIDTH = 232
local CARD_GAP = 14
local DIALOG_PADDING = 24
local WIDTH = CARD_WIDTH * 3 + CARD_GAP * 2 + DIALOG_PADDING * 2
local CHAPTER_HEIGHT = 44

export type CareerDialog = {
	Open: () -> (),
	Close: () -> (),
}

type ChapterRow = { Marker: Frame, Index: TextLabel, Check: Frame, Name: TextLabel }

type CardView = {
	Frame: Frame,
	Stroke: UIStroke,
	Progress: TextLabel,
	Button: TextButton,
	Rows: { ChapterRow },
}

local CareerDialog = {}

local function tween(instance: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?)
	TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props):Play()
end

function CareerDialog.new(parent: GuiObject): CareerDialog
	local open = false
	local busy = false

	local overlay: TextButton = create("TextButton", {
		Name = "CareerDialog",
		AutoButtonColor = false,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 40,
		Parent = parent,
	})
	local dialog: CanvasGroup = create("CanvasGroup", {
		Name = "Dialog",
		Active = true,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Colors.Surface,
		GroupTransparency = 1,
		Parent = overlay,
	}, {
		Util.corner(18),
		create("UIStroke", {
			Color = Colors.Border,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		}),
		Util.padding(22, DIALOG_PADDING, DIALOG_PADDING, DIALOG_PADDING),
		Util.vlist(16, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})
	local dialogScale: UIScale = create("UIScale", { Scale = 0.94, Parent = dialog })

	local header = create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		LayoutOrder = 1,
		Parent = dialog,
	})
	local heading = Util.text({ Text = "Choose your Trader Career", Size = 22, Font = Fonts.Bold, Parent = header })
	heading.AnchorPoint = Vector2.new(0, 0.5)
	heading.Position = UDim2.fromScale(0, 0.5)
	local close: TextButton = create("TextButton", {
		Name = "Close",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = Colors.Elevated,
		Text = "",
		Parent = header,
	}, { Util.round() })
	local closeIcon = Icons.close(12, Colors.TextMuted)
	closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
	closeIcon.Position = UDim2.fromScale(0.5, 0.5)
	closeIcon.Parent = close
	Util.hoverBackground(close, Colors.Elevated, Colors.Border)

	local subtitle = Util.label({
		Name = "Subtitle",
		Text = "A goal for the next few sessions. Chapters award titles shown in the Wallet Tracker, never extra earnings.",
		Size = 14,
		Color = Colors.TextMuted,
		FrameSize = UDim2.new(1, 0, 0, 36),
		Order = 2,
		Parent = dialog,
	})
	subtitle.TextWrapped = true
	subtitle.TextTruncate = Enum.TextTruncate.None
	subtitle.TextYAlignment = Enum.TextYAlignment.Top

	local cardsRow = Util.group("Cards", 3, Util.hlist(CARD_GAP, Enum.VerticalAlignment.Top))
	cardsRow.Parent = dialog

	local views: { [string]: CardView } = {}

	local function buildCard(path: Career.Path, order: number): CardView
		local frame: Frame = create("Frame", {
			Name = path.Id,
			Size = UDim2.fromOffset(CARD_WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Colors.Elevated,
			LayoutOrder = order,
			Parent = cardsRow,
		}, {
			Util.corner(14),
			Util.padding(18),
			Util.vlist(10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
		})
		local stroke: UIStroke = create("UIStroke", {
			Color = Colors.Text,
			Thickness = 1,
			Transparency = 1,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			BorderStrokePosition = Enum.BorderStrokePosition.Inner,
			Parent = frame,
		})

		local top = create("Frame", {
			Name = "Top",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 26),
			LayoutOrder = 1,
			Parent = frame,
		})
		Util.label({
			Name = "Name",
			Text = path.Name,
			Size = 20,
			Font = Fonts.Bold,
			FrameSize = UDim2.new(1, -48, 1, 0),
			Parent = top,
		})
		local progress = Util.label({
			Name = "Progress",
			Text = "",
			Size = 13,
			Font = Fonts.SemiBold,
			Color = Colors.TextMuted,
			AlignX = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			FrameSize = UDim2.new(0, 48, 1, 0),
			Parent = top,
		})
		local tagline = Util.label({
			Name = "Tagline",
			Text = path.Tagline,
			Size = 13,
			Color = Colors.TextMuted,
			FrameSize = UDim2.new(1, 0, 0, 56),
			Order = 2,
			Parent = frame,
		})
		tagline.TextWrapped = true
		tagline.TextTruncate = Enum.TextTruncate.None
		tagline.TextYAlignment = Enum.TextYAlignment.Top
		local divider = Util.divider(false, Colors.Border)
		divider.LayoutOrder = 3
		divider.Parent = frame

		local chapters = create("Frame", {
			Name = "Chapters",
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, CHAPTER_HEIGHT * #path.Chapters),
			LayoutOrder = 4,
			Parent = frame,
		}, { Util.vlist(0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })
		local rows: { ChapterRow } = {}
		for i, chapter in path.Chapters do
			local row = create("Frame", {
				Name = chapter.Id,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, CHAPTER_HEIGHT),
				LayoutOrder = i,
				Parent = chapters,
			})
			local marker: Frame = create("Frame", {
				Name = "Marker",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.fromOffset(22, 22),
				BackgroundColor3 = Colors.Surface,
				Parent = row,
			}, { Util.round() })
			local index = Util.label({
				Name = "Index",
				Text = tostring(i),
				Size = 12,
				Font = Fonts.SemiBold,
				Color = Colors.TextMuted,
				AlignX = Enum.TextXAlignment.Center,
				Parent = marker,
			})
			local check = Icons.check(14, Colors.OnPrimary)
			check.AnchorPoint = Vector2.new(0.5, 0.5)
			check.Position = UDim2.fromScale(0.5, 0.5)
			check.Visible = false
			check.Parent = marker
			local name = Util.label({
				Name = "Name",
				Text = chapter.Name,
				Size = 14,
				Font = Fonts.SemiBold,
				Position = UDim2.fromOffset(32, 5),
				FrameSize = UDim2.new(1, -32, 0, 18),
				Parent = row,
			})
			Util.label({
				Name = "Title",
				Text = `Title: {chapter.Title}`,
				Size = 12,
				Color = Colors.TextMuted,
				Position = UDim2.fromOffset(32, 23),
				FrameSize = UDim2.new(1, -32, 0, 16),
				Parent = row,
			})
			table.insert(rows, { Marker = marker, Index = index, Check = check, Name = name })
		end

		local button: TextButton = create("TextButton", {
			Name = "Choose",
			AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 40),
			BackgroundColor3 = Colors.Primary,
			Text = `Choose {path.Name}`,
			TextSize = 14,
			FontFace = Fonts.SemiBold,
			TextColor3 = Colors.OnPrimary,
			LayoutOrder = 5,
			Parent = frame,
		}, { Util.round() })

		return { Frame = frame, Stroke = stroke, Progress = progress, Button = button, Rows = rows }
	end

	for i, path in Career.Paths do
		views[path.Id] = buildCard(path, i)
	end

	local function refresh()
		local career = Career.sanitize(Portfolio.State.Career)
		for _, path in Career.Paths do
			local view = views[path.Id]
			local done = Career.doneCount(career, path.Id)
			local selected = career.Path == path.Id
			view.Progress.Text = if done > 0 or selected then `{done}/{#path.Chapters}` else ""
			view.Stroke.Transparency = if selected then 0.55 else 1
			view.Button.Text = if selected then "Current path" else `Choose {path.Name}`
			view.Button.BackgroundColor3 = if selected then Colors.Surface else Colors.Primary
			view.Button.TextColor3 = if selected then Colors.TextMuted else Colors.OnPrimary
			view.Button.Active = not selected
			for i, chapter in path.Chapters do
				local row = view.Rows[i]
				local finished = career.Done[chapter.Id] ~= nil
				row.Check.Visible = finished
				row.Index.Visible = not finished
				row.Marker.BackgroundColor3 = if finished then Colors.Primary else Colors.Surface
				row.Name.TextColor3 = if finished then Colors.TextMuted else Colors.Text
			end
		end
	end

	local function hide()
		if not open then
			return
		end
		open = false
		tween(dialog, 0.2, { GroupTransparency = 1 }, Enum.EasingStyle.Quad)
		tween(dialogScale, 0.2, { Scale = 0.96 }, Enum.EasingStyle.Quad)
		tween(overlay, 0.2, { BackgroundTransparency = 1 }, Enum.EasingStyle.Quad)
		task.delay(0.2, function()
			if not open then
				overlay.Visible = false
			end
		end)
	end

	local function choose(path: Career.Path)
		if busy then
			return
		end
		local selected = Career.sanitize(Portfolio.State.Career).Path == path.Id
		if selected then
			return
		end
		busy = true
		task.spawn(function()
			local ok, result = pcall(Remotes.ChooseCareer.InvokeServer, Remotes.ChooseCareer, path.Id)
			busy = false
			if ok and typeof(result) == "table" and result.Ok then
				Toast.show(`You're on the {path.Name} path`, "Success")
				hide()
			else
				Toast.show(
					if ok and typeof(result) == "table" then result.Error or "Couldn't choose that path" else "Connection problem, try again",
					"Error"
				)
			end
		end)
	end

	for _, path in Career.Paths do
		local button = views[path.Id].Button
		button.Activated:Connect(function()
			choose(path)
		end)
		button.MouseEnter:Connect(function()
			if button.Active then
				Util.tween(button, { BackgroundColor3 = Colors.PrimaryHover })
			end
		end)
		button.MouseLeave:Connect(function()
			if button.Active then
				Util.tween(button, { BackgroundColor3 = Colors.Primary })
			end
		end)
	end

	close.Activated:Connect(hide)
	overlay.Activated:Connect(hide)
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if open and input.KeyCode == Enum.KeyCode.Escape then
			hide()
		end
	end)
	Portfolio.Changed:Connect(function()
		if open then
			refresh()
		end
	end)

	return {
		Open = function()
			refresh()
			open = true
			overlay.Visible = true
			dialog.GroupTransparency = 1
			dialogScale.Scale = 0.94
			tween(overlay, 0.25, { BackgroundTransparency = 0.35 }, Enum.EasingStyle.Quad)
			tween(dialog, 0.3, { GroupTransparency = 0 })
			tween(dialogScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		end,
		Close = hide,
	}
end

return CareerDialog
