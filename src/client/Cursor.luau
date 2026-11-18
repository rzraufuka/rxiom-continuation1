--!strict
-- Gra to sam interfejs, więc kamera stoi w miejscu, a kursor jest zawsze wolny. Bez tego domyślna
-- kamera Robloxa łapie mysz na środku ekranu (pierwsza osoba po kółku myszy, shift lock,
-- obracanie prawym przyciskiem).

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Cursor = {}

local CAMERA_CFRAME = CFrame.lookAt(Vector3.new(0, 50, 0), Vector3.new(0, 50, -1))

local function pinCamera(camera: Camera?)
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	if camera.CFrame ~= CAMERA_CFRAME then
		camera.CFrame = CAMERA_CFRAME
	end
end

function Cursor.start()
	-- Priorytet za kamerą Robloxa, żeby nasze ustawienie wygrywało w każdej klatce.
	RunService:BindToRenderStep("RXIOMCursor", Enum.RenderPriority.Camera.Value + 1, function()
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
		pinCamera(workspace.CurrentCamera)
	end)
end

return Cursor
