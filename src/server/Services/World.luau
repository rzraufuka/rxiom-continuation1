--!strict
-- Podłoga i spawn tworzone przy starcie serwera, jeśli nie ma ich w miejscu.
-- Rojo synchronizuje je też z default.project.json, ale Workspace bywa niezsynchronizowany
-- (np. przy otwartym starym pliku .rbxlx), a bez podłogi postać w kółko spada.

local World = {}

local function ensurePart(className: string, name: string, size: Vector3, position: Vector3, color: Color3): BasePart
	local existing = workspace:FindFirstChild(name)
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local part = Instance.new(className) :: BasePart
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = workspace
	return part
end

function World.setup()
	-- Gra to sam interfejs: gracze nie dostają postaci (nie chodzą, nie przełączają kamery).
	-- Ustawione też w default.project.json; tu na wypadek starego pliku miejsca.
	local Players = game:GetService("Players")
	Players.CharacterAutoLoads = false
	for _, player in Players:GetPlayers() do
		if player.Character then
			player.Character:Destroy()
			player.Character = nil
		end
	end

	local baseplate = ensurePart(
		"Part",
		"Baseplate",
		Vector3.new(2048, 16, 2048),
		Vector3.new(0, -8, 0),
		Color3.new(0.357, 0.365, 0.412)
	)
	baseplate.Locked = true
	if not baseplate:FindFirstChildOfClass("Texture") then
		local texture = Instance.new("Texture")
		texture.Texture = "rbxassetid://6372755229"
		texture.Face = Enum.NormalId.Top
		texture.StudsPerTileU = 8
		texture.StudsPerTileV = 8
		texture.Color3 = Color3.new(0, 0, 0)
		texture.Transparency = 0.8
		texture.Parent = baseplate
	end

	if not workspace:FindFirstChildWhichIsA("SpawnLocation", true) then
		ensurePart(
			"SpawnLocation",
			"SpawnLocation",
			Vector3.new(12, 1, 12),
			Vector3.new(0, 0.5, 0),
			Color3.new(0.639, 0.635, 0.647)
		)
	end
end

return World
