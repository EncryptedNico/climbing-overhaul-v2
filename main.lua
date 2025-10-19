local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Modules = script.Modules

local Defaults = require(Modules.Defaults)
local CameraShaker = require(Modules.CameraShaker)
local InterfaceMod = require(Modules.Interface)
local AnimationsController = require(Modules.AnimationController)
local Keybinds = require(Modules.Keybinds)
local LedgeQueryUtils = require(Modules.LedgeQuery)
local Flags = require(Modules.Defaults.Flags)
local ParkourInstanceCache = require(Modules.Cache)

local HeightThreshold = Defaults.LedgeHeightThreshold
local DetectionDistanceXZ = Defaults.LedgeDetectionDistanceXZ
local DetectionDistanceY = Defaults.LedgeDetectionDistanceY

-- Private/internal configs
local LeapCooldownDuration = 0.25
local InitClimbCooldownDuration = 1.5

local Player = Players.LocalPlayer
local Character = script.Parent
local RootPart = Character:WaitForChild("HumanoidRootPart")
local Humanoid = Character:WaitForChild("Humanoid")

local AnimationsFolder = script:WaitForChild("Animations")
local SoundsFolder = script:WaitForChild("Sounds")

local Camera = workspace.CurrentCamera
local SmoothShiftLock = require(Player:WaitForChild("PlayerScripts"):WaitForChild("CustomShiftLock"):WaitForChild("SmoothShiftLock"))

-- Query & ray params
local RayParams = RaycastParams.new()
RayParams.FilterDescendantsInstances = {Character}
RayParams.FilterType = Enum.RaycastFilterType.Exclude

local LedgeQueryParams = OverlapParams.new()
LedgeQueryParams.FilterDescendantsInstances = {Character}
LedgeQueryParams.FilterType = Enum.RaycastFilterType.Exclude

local CamShake = CameraShaker.new(Enum.RenderPriority.Camera.Value, function(shakeCf : CFrame?)
	Camera.CFrame = Camera.CFrame * shakeCf
end)

local TempLedge : BasePart? -- Temporary ledge that we found in the climbable ledge query - NOT during climbing
local CurrentLedge : BasePart? -- The ledge we're currently grabbing

-- Flags & cache stuff
local AvailabilityFlags = {}
local GeneralCache = {}
local HumanoidInfos = {JumpHeight = Humanoid.JumpHeight}

AnimationsController:PreloadAll(AnimationsFolder)

-- Perform a basic camera shake once
function ShakeCameraOnce()
	CamShake:Start()
	CamShake:ShakeOnce(1.25, 15, 0, .5)
end

-- New CFrame location for the body mover when leaping
function GetNewMovePos(NewLedgePart : BasePart)
	return CFrame.new(NewLedgePart.Position - (-NewLedgePart.CFrame.LookVector * 1.5), NewLedgePart.Position)
end

-- Returns whether we should play a grunting audio based on the leap distance
function GetIsWithinGruntDistance(InitialPos : Vector3)
	return math.abs((GeneralCache["BodyMover"].Position - InitialPos).Magnitude) >= Defaults.GruntDistance
end

-- Returns whether the area above the character is clear enough to vault
function GetCanVault()
	local BodyMover : Instance = GeneralCache["BodyMover"]
	local VaultHeight : Vector3 = BodyMover.Position + Vector3.new(0, 6.5, 0)
	local Raycast = workspace:Raycast(VaultHeight, BodyMover.CFrame.LookVector * 5.75, RayParams)

	if not Raycast then
		return VaultHeight + BodyMover.CFrame.LookVector * 5
	end
	
	return nil
end

-- Sets the CFrame of the active body mover
function SetBodyMoverCFrame(_CFrame : CFrame)
	if not GeneralCache["BodyMover"] then
		return
	end
	
	GeneralCache["BodyMover"].CFrame = _CFrame
end

-- Sets the Position of the active body mover - NOT used for leaping
function SetBodyMoverPosition(Position : Vector3)
	if not GeneralCache["BodyMover"] then
		return
	end

	GeneralCache["BodyMover"].Position = Position
end

-- Garbage collection - clean up objects used during climbing
function ClearGeneralCache()
	for _, inst : Instance? in pairs(GeneralCache) do
		if typeof(inst) ~= "Instance" then
			continue
		end
		
		inst:Destroy()
	end
	
	GeneralCache = {}
end

-- Performs a climbable ledge query and returns whether a ledge is available nearby - this is NOT used during climbing
function FindClimbableLedge()
	local LedgesFound = {}
	
	local QuerySize = Vector3.new(
		Defaults.LedgeDetectionDistanceXZ, 
		Defaults.LedgeDetectionDistanceY, 
		Defaults.LedgeDetectionDistanceXZ
	)
	
	local LedgeQuery : {} = workspace:GetPartBoundsInBox(
		CFrame.new(RootPart.Position),
		QuerySize,
		LedgeQueryParams
	)
	
	if Defaults.EnableRegionVisualizing then
		LedgeQueryUtils:Visualize({Size = QuerySize, CFrame = CFrame.new(RootPart.Position)}, 1)
	end

	for _, part : BasePart? in ipairs(LedgeQuery) do
		local LedgeDist : number = (part.Position.Y - RootPart.Position.Y)

		if LedgeDist < 5 or LedgeDist > 12 then
			continue
		end

		if (part:HasTag(Defaults.LedgeTagName)) and (part ~= CurrentLedge) then
			table.insert(LedgesFound, part)
		end
	end

	return LedgesFound[1] -- Only 1 nearby ledge is cached at a time
end

-- Performs a leap query in a given direction and returns the closest ledge found in that direction
function GetLedgesWhileClimbing(MaxParts : number, Direction : string)
	if AvailabilityFlags[Flags.__FREE_ACTION_FLAG] then
		return
	end
	
	local LedgeQuery : {}
	local ConfirmedLedges = {}
	
	local DirectionOffsets = {
		Up = {RootPart.CFrame.UpVector, 2, Vector3.new(1, 2, 1)},
		Down = {-RootPart.CFrame.UpVector, 2, Vector3.new(1, 2, 1)},
		Left = {-RootPart.CFrame.RightVector, 2},
		Right = {RootPart.CFrame.RightVector, 2},
		Back = {-RootPart.CFrame.LookVector, 2}
	}

	if not AvailabilityFlags[Direction] then
		local OffsetData : {} = DirectionOffsets[Direction]
		
		local QuerySize = Vector3.new(
			Defaults.ClimbingLedgeDetectionDistanceXZ, 
			Defaults.ClimbingLedgeDetectionDistanceY, 
			Defaults.ClimbingLedgeDetectionDistanceXZ
		)
		
		local Offset = OffsetData[1] * (QuerySize.X / 1.5)
		local Center = RootPart.Position + Offset
		local __QuerySize = QuerySize
		
		if OffsetData[3] then
			__QuerySize *= OffsetData[3]
		end
	
		LedgeQuery = workspace:GetPartBoundsInBox(
			CFrame.new(Center),
			__QuerySize,
			LedgeQueryParams
		)
		
		if Defaults.EnableRegionVisualizing then
			LedgeQueryUtils:Visualize({Size = __QuerySize, CFrame = CFrame.new(Center)}, 1)
		end
	end

	for _, part : BasePart? in pairs(LedgeQuery) do
		if (part:HasTag(Defaults.LedgeTagName) and part ~= CurrentLedge) then
			if #ConfirmedLedges >= MaxParts then
				break
			end

			if Direction ~= "Down" then
				if (part.Position.Y - RootPart.Position.Y) <= 0 then
					continue
				end
			end

			table.insert(ConfirmedLedges, part)
		end 
	end

	table.sort(ConfirmedLedges, function(a, b)
		return (a.Position - RootPart.Position).Magnitude < (b.Position - RootPart.Position).Magnitude
	end)

	return ConfirmedLedges[1] -- Return the closest confirmed ledge in the query - 1 is cached at a time
end

-- Moves the active body mover to a new ledge in a given direction - if available
function MoveToLedge(Direction : string)
	if (not AvailabilityFlags[Flags.__IS_CLIMBING_FLAG]) or AvailabilityFlags[Flags.__FREE_ACTION_FLAG] then
		return
	end
	
	if not AvailabilityFlags[Direction] then
		local NewLedgeInstance : BasePart? = GetLedgesWhileClimbing(10, Direction)
		
		if NewLedgeInstance then -- A new ledge has been found in this direction, now we try to move to it
			AvailabilityFlags[Direction] = true
			AvailabilityFlags[Flags.__FREE_ACTION_FLAG] = true

			local LeapAnimationClass : {} = AnimationsController:LoadAnimationByDirection(Direction, Humanoid:FindFirstChildWhichIsA("Animator"))
			LeapAnimationClass.Play()

			task.wait(.3)
			
			local function Switch()
				local InitialLedgePos = GeneralCache["BodyMover"].Position

				SetBodyMoverCFrame(GetNewMovePos(NewLedgeInstance))
				CurrentLedge = NewLedgeInstance

				SoundsFolder.Switch:Play()

				if GetIsWithinGruntDistance(InitialLedgePos) then
					SoundsFolder.Grunt.PlaybackSpeed = Random.new():NextNumber(0.9, 1.2)
					SoundsFolder.Grunt:Play()
				end

				ShakeCameraOnce()
			end
			
			task.delay(LeapCooldownDuration, function()
				AvailabilityFlags[Direction] = false
				AvailabilityFlags[Flags.__FREE_ACTION_FLAG] = false
			end)
			
			if not AvailabilityFlags[Flags.__IS_CLIMBING_FLAG] then
				return
			end
			
			Switch()
		end
	end
end

-- Use the current TempLedge, if available, to initiate climbing
function StartClimbing()
	if AvailabilityFlags[Flags.__IS_CLIMBING_FLAG] or (not TempLedge) then
		return
	end

	task.delay(.3, function()
		AvailabilityFlags[Flags.__IS_CLIMBING_FLAG] = true
		AvailabilityFlags[Flags.__CLIMB_DB_FLAG] = true
	end)

	for _, part in pairs(Character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = Defaults.ActiveCollisionGroup
		end
	end

	CurrentLedge = TempLedge
	
	if GeneralCache["BodyMover"] then
		SetBodyMoverCFrame(GetNewMovePos(TempLedge))
		return	
	end
	
	SmoothShiftLock:Disable()
	SmoothShiftLock:ToggleShiftLock(false)
	
	-- Load & play the idle animation via a new AnimationController class
	local IdleAnimClass : {} = AnimationsController:LoadSingular(AnimationsFolder.Idle, Humanoid.Animator)
	IdleAnimClass.Play()

	SoundsFolder.Switch:Play()
	ShakeCameraOnce()

	local BodyMover = Instance.new("Part")
	BodyMover.Name = "BodyMover"
	BodyMover.Transparency = 1
	BodyMover.CanCollide = false
	BodyMover.Anchored = true
	BodyMover.Size = TempLedge.Size
	BodyMover.Parent = ParkourInstanceCache:Get()

	GeneralCache["BodyMover"] = BodyMover
	SetBodyMoverCFrame(GetNewMovePos(TempLedge))
	
	-- Body mover constraints to control movement
	local Attch0 = Instance.new("Attachment", Character.PrimaryPart)
	local Attch1 = Instance.new("Attachment", BodyMover)

	local AlignPosition = Instance.new("AlignPosition")
	AlignPosition.Position = BodyMover.Position
	AlignPosition.Attachment0 = Attch0
	AlignPosition.Attachment1 = Attch1
	AlignPosition.Responsiveness = 40
	AlignPosition.Parent = RootPart

	local AlignOrientation = Instance.new("AlignOrientation")
	AlignOrientation.CFrame = BodyMover.CFrame
	AlignOrientation.Responsiveness = 50
	AlignOrientation.Attachment0 = Attch0
	AlignOrientation.Attachment1 = Attch1
	AlignOrientation.Parent = RootPart

	GeneralCache["AlignPosition"] = AlignPosition
	GeneralCache["AlignOrientation"] = AlignOrientation
	GeneralCache["Att0"] = Attch0 GeneralCache["Att1"] = Attch1
end

-- End the climbing session - clean up everything and return back to the non-parkour state
function EndClimbing()
	for _, part in pairs(Character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Default"
		end
	end

	AvailabilityFlags[Flags.__FREE_ACTION_FLAG] = false
	AvailabilityFlags[Flags.__IS_CLIMBING_FLAG] = false

	Humanoid.JumpHeight = HumanoidInfos.JumpHeight
	SmoothShiftLock:Enable()

	TempLedge = nil
	CurrentLedge = nil
	ClearGeneralCache()

	task.delay(InitClimbCooldownDuration, function()
		AvailabilityFlags[Flags.__CLIMB_DB_FLAG] = false
	end)

	AnimationsController:StopAll()
end

-- Input map of basic actions that DO NOT relate to leaping
local BaseInputMap = {
	Vault = function()
		if AvailabilityFlags[Flags.__FREE_ACTION_FLAG] or (not AvailabilityFlags[Flags.__IS_CLIMBING_FLAG]) then
			return
		end
		
		local VaultPos : Vector3? = GetCanVault()
		if VaultPos then
			AvailabilityFlags[Flags.__FREE_ACTION_FLAG] = true
			AnimationsController:StopAll()

			task.delay(0.35, EndClimbing)
			Humanoid:LoadAnimation(AnimationsFolder.Vault):Play()

			SoundsFolder.Grunt:Play()
			SoundsFolder.Switch:Play()

			SetBodyMoverPosition(VaultPos)
		end
	end,
	
	End = function()
		if AvailabilityFlags[Flags.__IS_CLIMBING_FLAG] and GeneralCache["BodyMover"] then
			EndClimbing()
		end
	end,
}

-- Handle the given InputObject and map it to a parkour action
function HandleInput(Input : InputObject?)
	if Input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	
	local KeybindInfo : string? = Keybinds[Input.KeyCode]
	if KeybindInfo then
		local IsLeapInput = table.find(Keybinds.LeapInputMap, KeybindInfo) -- Are we trying to leap, or something else?
		
		if IsLeapInput then
			MoveToLedge(KeybindInfo)
			return
		end
		
		if BaseInputMap[KeybindInfo] then
			BaseInputMap[KeybindInfo]()
		end
	end
end

UserInputService.InputBegan:Connect(function(Input, Processed)
	if Processed then return end
	
	HandleInput(Input)
end)

UserInputService.JumpRequest:Connect(function(...)
	if AvailabilityFlags[Flags.__CLIMB_DB_FLAG] then
		return
	end
	
	StartClimbing()
end)

-- Loop to search for nearby ledges
while task.wait(.25) do
	if AvailabilityFlags[Flags.__FREE_ACTION_FLAG] or AvailabilityFlags[Flags.__IS_CLIMBING_FLAG] then
		continue
	end

	local NewLedge : BasePart? = FindClimbableLedge()

	if not NewLedge then
		TempLedge = nil
	end
	
	-- Have we cached this ledge through the interface module already?
	if NewLedge ~= TempLedge or not NewLedge then
		InterfaceMod:ClearLedgeKeybinds()
	end

	if NewLedge and NewLedge ~= CurrentLedge then
		TempLedge = NewLedge
		Character.Humanoid.JumpHeight = 0
		InterfaceMod:AttachKeybindToLedge(TempLedge)
	else
		Humanoid.JumpHeight = HumanoidInfos.JumpHeight
	end
end
