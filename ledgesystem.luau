--made by yaxinn in roblox, yaxin on discord

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AnimationFolder = ReplicatedStorage:WaitForChild("Animations") -- grab the folder that holds all our animation objects

local Player = Players.LocalPlayer -- get the local player
local Character = Player.Character or Player.CharacterAdded:Wait() -- get the character, waiting for it to spawn if it isnt loaded yet so the WaitForChilds below dont error on nil
local Humanoid = Character:WaitForChild("Humanoid") -- get the characters humanoid
local RootPart = Character:WaitForChild("HumanoidRootPart") -- get the characters root part
local Head = Character:WaitForChild("Head") -- get the characters head
local Animator = Humanoid:WaitForChild("Animator") -- get the humanoids animator to load animations through

local IdleGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabIdle")) -- load and cache the idle hang animation
local LeftGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabLeft")) -- load and cache the left grab animation
local RightGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabRight")) -- load and cache the right grab animation
local JumpGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabJump")) -- load and cache the climb animation

local LEDGE_TAG = "Ledge" -- any part tagged with this in CollectionService counts as something grabbable, so map designers can just tag parts and it works

-- all our tunable numbers live up here so were not hunting through the script to tweak them later
local DetectDistance = 5        -- how far in front of us we check for a ledge
local GrabReachDistance = 4      -- how close we need to be to actually grab it
local SideMoveReachDistance = 3  -- how close a side-ledge needs to be to move onto it
local JumpUpForce = 30           -- how much upward push we give when climbing up
local JumpForwardForce = 10      -- how much forward push we give when climbing up
local BoostDuration = 0.15       -- how long that climb-up push force lasts before its removed
local GrabCooldown = 0.2         -- how long after climbing up before were allowed to grab again
local SideMoveDistance = 10      -- how far sideways we cast a ray to look for side ledges
local SideMoveDelay = 0.3        -- cooldown between sideways moves so it cant be spammed

local Signal = {}
Signal.__index = Signal -- set the metatable index so signal instances can find the methods below

local Connection = {}
Connection.__index = Connection -- set the metatable index so connection instances can find the methods below

function Connection.new(SignalRef, Fn)
	return setmetatable({
		Connected = true, -- start connected, switches to false once disconnect is called
		SignalRef = SignalRef, -- keep a reference back to the signal for debugging
		Fn = Fn, -- store the listener function to call later
	}, Connection)
end

function Connection:Disconnect() --never called
	if not self.Connected then return end -- return early if already disconnected
	self.Connected = false -- mark the connection as no longer active, fire skips it from here on instead of removing it mid loop
end

function Signal.new()
	return setmetatable({
		Listeners = {}, -- start with an empty list of listeners
	}, Signal)
end

function Signal:Connect(Fn)
	local ConnectionObject = Connection.new(self, Fn) -- wrap the listener function in a connection object
	table.insert(self.Listeners, ConnectionObject) -- add it to the list of listeners
	return ConnectionObject -- hand back the connection in case its needed to disconnect later
end

function Signal:Fire(...)
	local ListenersSnapshot = table.clone(self.Listeners) -- clone the list before looping so disconnecting mid fire cant cause index errors or skipped listeners
	for _, ConnectionObject in ListenersSnapshot do
		if ConnectionObject.Connected then
			task.spawn(ConnectionObject.Fn, ...) -- call the listener on its own thread so an error in it cant affect the others
		end
	end
end


local ClimbState = {}
ClimbState.__index = ClimbState -- set the metatable index so instances can find the methods below

function ClimbState.new()
	return setmetatable({
		Hanging = false, -- true when actively hanging on a ledge
		CanGrab = true, -- false right after grabbing or climbing
		CanSideMove = true, -- false while on cooldown from a recent side move
	}, ClimbState) -- create a new state table with the starting values
end

function ClimbState:BeginHang()
	self.Hanging = true -- mark the state as hanging
	self.CanGrab = false -- disallow grabbing again while already hanging
end

function ClimbState:EndHang()
	self.Hanging = false -- mark the state as no longer hanging
end

function ClimbState:LockSideMove(Duration)
	self.CanSideMove = false -- disallow side moving immediately
	task.delay(Duration, function() -- wait out the duration before allowing it again
		self.CanSideMove = true -- allow side moving again
	end)
end

function ClimbState:AllowGrabAfter(Duration)
	task.delay(Duration, function() -- wait out the duration before allowing grabbing again
		self.CanGrab = true -- allow grabbing again
	end)
end

-- our one and only instance of the state machine
local State = ClimbState.new()

local LedgeGrabbed = Signal.new() -- fires the moment we successfully grab a ledge
local LedgeReleased = Signal.new() -- fires the moment we let go / climb up off a ledge

--these are all set to nil until we actually create a ledge/grab onto a ledge
local LedgeAnchor = nil
local RootAttachment = nil
local AnchorAttachment = nil
local PositionAlign = nil
local OrientationAlign = nil



local RaycastFilter = RaycastParams.new() -- create the raycast params well reuse for every ledge detection cast
RaycastFilter.FilterType = Enum.RaycastFilterType.Exclude -- exclude instead of include so we can just list what to ignore
RaycastFilter.FilterDescendantsInstances = {Character} -- ignore the characters own body so it doesnt detect itself as a wall


local GrabSound = Instance.new("Sound")
GrabSound.SoundId = "rbxassetid://9116634613" -- sound that plays whenever we grab onto a ledge
GrabSound.Volume = 0.6 -- 0.6 volume so its not too loud
GrabSound.Parent = RootPart --parent to RootPart of the player

local ClimbSound = Instance.new("Sound")
ClimbSound.SoundId = "rbxassetid://79480035097773"
ClimbSound.Volume = 0.6
ClimbSound.Parent = RootPart


LedgeGrabbed:Connect(function()
	GrabSound:Play() --play grab sound whenever ledgegrabbed
end)

LedgeReleased:Connect(function()
	ClimbSound:Play() --play climb sound whenever ledgereleased
end)

local function GetLedgeTop(RaycastResult) -- function that lets us the top surface of a part
	local Instance = RaycastResult.Instance -- get the actual part the ray hit
	local PartCFrame = Instance.CFrame -- grab the parts cframe so we know which way its rotated
	local Size = Instance.Size --  get the parts size so we know how far each face is from its center

	local Axes = {
		{Direction = PartCFrame.RightVector,  Size = Size.X}, -- checks the right face for how upward it points
		{Direction = -PartCFrame.RightVector, Size = Size.X}, -- checks the left face for how upward it points
		{Direction = PartCFrame.UpVector,      Size = Size.Y}, -- checks the top face for how upward it points
		{Direction = -PartCFrame.UpVector,     Size = Size.Y}, -- checks the bottom face for how upward it points
		{Direction = PartCFrame.LookVector,    Size = Size.Z}, -- checks the front face for how upward it points
		{Direction = -PartCFrame.LookVector,   Size = Size.Z}, -- checks the back face for how upward it points
	} -- build all 6 face directions since we dont know ahead of time which one is actually facing up

	local BestDirection, BestSize, BestDot = Axes[1].Direction, Axes[1].Size, -math.huge -- start with face 1 as a placeholder guess before the loop runs

	for _, Axis in Axes do -- loop through all 6 faces one at a time
		local Dot = Axis.Direction:Dot(Vector3.new(0, 1, 0)) -- get how much this face points upward, closer to 1 means more upward

		if Dot > BestDot then -- check if this face points more upward than whatever we found so far
			BestDot = Dot -- store the new best upward score
			BestDirection = Axis.Direction -- store the direction of the new best face
			BestSize = Axis.Size -- store the size along the new best faces axis
		end
	end

	local WorldTop = Instance.Position + BestDirection * (BestSize / 2) -- step outward from the parts center to the actual top surface using half the parts size along that axis

	return Vector3.new(RaycastResult.Position.X, WorldTop.Y, RaycastResult.Position.Z) -- keep the x and z from where the ray hit but use the real height of the top face we found
end

local function IsClimbableLedge(RaycastResult)
	return RaycastResult ~= nil and CollectionService:HasTag(RaycastResult.Instance, LEDGE_TAG) -- check the raycast actually hit something and that its tagged as a ledge
end

local function StopAllGrabAnimations()
	IdleGrabAnimation:Stop() -- stop the idle hang animation
	LeftGrabAnimation:Stop() -- stop the left grab animation
	RightGrabAnimation:Stop() -- stop the right grab animation
	JumpGrabAnimation:Stop() -- stop the climb animation
end

local function PlayGrabAnimation(Direction)
	if Direction > 0.3 then
		if RightGrabAnimation.IsPlaying then return end -- return early so MoveDirection updates firing multiple times a frame dont keep calling play (used in mainloop)

		IdleGrabAnimation:Stop() -- stop the idle animation before switching
		LeftGrabAnimation:Stop() -- stop the left animation before switching
		RightGrabAnimation.Priority = Enum.AnimationPriority.Action4 -- set the right grab animations priority to 4 to override any other animation
		RightGrabAnimation.Looped = true -- make the right animation loop
		RightGrabAnimation:Play() -- play the right grab animation
	elseif Direction < -0.3 then
		if LeftGrabAnimation.IsPlaying then return end -- return early for the same reason as the right side check

		IdleGrabAnimation:Stop() -- stop the idle animation before switching
		RightGrabAnimation:Stop() -- stop the right animation before switching
		LeftGrabAnimation.Priority = Enum.AnimationPriority.Action4 -- set the left grab animations priority to 4 to override any other animation
		LeftGrabAnimation.Looped = true -- make the left animation loop
		LeftGrabAnimation:Play() -- play the left grab animation
	else
		if IdleGrabAnimation.IsPlaying then return end -- return early if the idle animation is already playing

		LeftGrabAnimation:Stop() -- stop the left animation before switching
		RightGrabAnimation:Stop() -- stop the right animation before switching
		IdleGrabAnimation.Priority = Enum.AnimationPriority.Action4 -- set the idle grab/hang animations priority to 4 to override any other animation
		IdleGrabAnimation.Looped = true -- make the idle animation loop
		IdleGrabAnimation:Play() -- play the idle hang animation
	end
end

local function ClearLedgeConstraints()
	if PositionAlign then PositionAlign:Destroy() PositionAlign = nil end -- destroy the position constraint if it exists
	if OrientationAlign then OrientationAlign:Destroy() OrientationAlign = nil end -- destroy the orientation constraint if it exists
	if RootAttachment then RootAttachment:Destroy() RootAttachment = nil end -- destroy the root attachment if it exists
	if AnchorAttachment then AnchorAttachment:Destroy() AnchorAttachment = nil end -- destroy the anchor attachment if it exists
	if LedgeAnchor then LedgeAnchor:Destroy() LedgeAnchor = nil end -- destroy the anchor part if it exists
end

local function CreateLedgeConstraints()
	ClearLedgeConstraints() -- clean up any leftovers from a previous grab first and we can always start clean/prevent memory leaks

	LedgeAnchor = Instance.new("Part") -- create the invisible anchor part that acts as our target
	LedgeAnchor.Size = Vector3.one -- keep the anchor tiny since its never actually seen
	LedgeAnchor.Anchored = true -- stop the anchor from being affected by physics
	LedgeAnchor.CanCollide = false -- stop the anchor from physically colliding with anything
	LedgeAnchor.CanTouch = false -- stop Touched events from firing on the anchor
	LedgeAnchor.CanQuery = false -- exclude the anchor from raycasts and spatial queries
	LedgeAnchor.Transparency = 1 -- make the anchor invisible
	LedgeAnchor.Parent = workspace -- parent to workspace since the engine only simulates whats inside it

	RootAttachment = Instance.new("Attachment") -- create the attachment the constraints pull from
	RootAttachment.Parent = RootPart -- parent it to the characters root part
	AnchorAttachment = Instance.new("Attachment") -- create the attachment the constraints pull toward
	AnchorAttachment.Parent = LedgeAnchor -- parent it to the anchor part

	PositionAlign = Instance.new("AlignPosition") -- create the constraint that pulls the character to the anchors position
	PositionAlign.Attachment0 = RootAttachment -- set the attachment on the character
	PositionAlign.Attachment1 = AnchorAttachment -- set the attachment on the anchor
	PositionAlign.MaxForce = 50000 -- cap how much force the constraint can apply
	PositionAlign.MaxVelocity = 20 -- cap how fast the attachments can converge
	PositionAlign.Responsiveness = 25 -- control how quickly the constraint reaches its goal
	PositionAlign.RigidityEnabled = false -- let the physics solver ease into the alignment instead of snapping instantly
	PositionAlign.Parent = RootPart -- parent the constraint to the root part

	OrientationAlign = Instance.new("AlignOrientation") -- create the constraint that pulls the characters rotation to match the anchor
	OrientationAlign.Attachment0 = RootAttachment -- set the attachment on the character
	OrientationAlign.Attachment1 = AnchorAttachment -- set the attachment on the anchor
	OrientationAlign.MaxTorque = 50000 -- cap how much torque the constraint can apply
	OrientationAlign.MaxAngularVelocity = 20 -- cap how fast the rotation can converge
	OrientationAlign.Responsiveness = 25 -- control how quickly the constraint reaches its goal
	OrientationAlign.RigidityEnabled = false -- let the physics solver ease into the rotation instead of snapping instantly
	OrientationAlign.Parent = RootPart -- parent the constraint to the root part

	return LedgeAnchor
end

local function HasClearHeadroom(LedgeCFrame)
	local TopCheck = workspace:Raycast(
		LedgeCFrame.Position + Vector3.new(0, -1, 0) + LedgeCFrame.LookVector, -- cast from slightly below and forward of the ledges position since a parts size alone cant tell us whats above it
		LedgeCFrame.UpVector * 3, -- aim 3 studs upward to check for headroom
		RaycastFilter
	)
	return TopCheck == nil -- nil means the ray hit nothing so the space above is clear
end

local function MoveToLedge(RaycastResult, DirectionName)
	local WorldPosition = GetLedgeTop(RaycastResult) -- get the top surface position of the new ledge with GetLedgeTop
	local LedgeCFrame = CFrame.lookAt(WorldPosition, WorldPosition - RaycastResult.Normal) -- build a cframe at the ledge facing away from the wall

	if not HasClearHeadroom(LedgeCFrame) then return end -- return if theres no room to stand there
	if (WorldPosition - Head.Position).Magnitude >= SideMoveReachDistance then return end -- return if the new spot is too far to reach

	local Target = LedgeCFrame + Vector3.new(0, -2, 0) + LedgeCFrame.LookVector * -1 -- offset the target slightly below and behind the ledge edge
	TweenService:Create(
		LedgeAnchor, -- tween the anchor 
		TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), -- 0.3 ease in and out
		{CFrame = Target} -- tween the anchors cframe to the new ledge
	):Play()

	State:LockSideMove(SideMoveDelay) -- put side moving on a brief cooldown so it cant be spammed every frame

	if DirectionName == "Right" then
		RightGrabAnimation:Play() -- play the right side move animation
	elseif DirectionName == "Left" then
		LeftGrabAnimation:Play() -- play the left side move animation
	end
end

local function AttemptSideMove(Direction, AnimationName)
	if not State.CanSideMove then return end -- return if were still on cooldown from the last side move

	local SideHit = workspace:Raycast(
		Head.Position, -- cast from the head
		Head.CFrame.RightVector * Direction + Head.CFrame.LookVector * 8, -- aim sideways plus forward to look for a ledge in that direction
		RaycastFilter
	)
	if IsClimbableLedge(SideHit) then
		MoveToLedge(SideHit, AnimationName) -- move onto the ledge we found
		return
	end

	local CornerHit = workspace:Raycast(
		Head.Position + Vector3.new(0, -1, 0) + Head.CFrame.RightVector * Direction, -- cast from slightly below and off to the side
		Head.CFrame.RightVector * -Direction + Head.CFrame.LookVector * 2, -- aim back toward the ledge to check for a corner
		RaycastFilter
	)
	if IsClimbableLedge(CornerHit) then
		MoveToLedge(CornerHit, AnimationName) -- move onto the corner ledge we found
	end
end

local function ClimbUp()
	if not State.Hanging then return end -- return early if were not even hanging

	State:EndHang() -- exit the hanging state
	Humanoid.AutoRotate = true -- turning autorotation back on so the player can look and move with shiftlock again
	ClearLedgeConstraints() -- getting rid of the anchor and constraints after we enter endhangstate to prevent memory leaks
	StopAllGrabAnimations() -- stopping whatever grab animations are still playing
	LedgeReleased:Fire() -- firing the LedgeReleased event

	JumpGrabAnimation.Priority = Enum.AnimationPriority.Action4 -- setting the climb animation priority to 4 to override any other animation
	JumpGrabAnimation.Looped = false -- the climb animation only plays once
	JumpGrabAnimation:Play() -- play the climb animation

	local BoostAttachment = Instance.new("Attachment") -- creating an attachment to hold the boost
	BoostAttachment.Parent = RootPart -- parenting the attachment to the root part

	local Boost = Instance.new("LinearVelocity") -- creating the linear velocity thatll push the character up and over the ledge
	Boost.Attachment0 = BoostAttachment -- setting the attachment the velocity applies force through
	Boost.MaxForce = 67 -- capping how much force the boost can apply to 67 hahaha 67
	Boost.RelativeTo = Enum.ActuatorRelativeTo.World -- keep the boost direction fixed in world space instead of relative to the players rotation
	Boost.VectorVelocity = RootPart.CFrame.LookVector * JumpForwardForce + Vector3.new(0, JumpUpForce, 0) -- setting the boost direction to up and forward
	Boost.Parent = RootPart -- parenting the boost to the root part so it actually applies

	Debris:AddItem(BoostAttachment, BoostDuration) -- letting Debris clean up the attachment after BoostDuration seconds instead of doing it manually
	Humanoid:ChangeState(Enum.HumanoidStateType.Jumping) -- forcing the Humanoids state into Jumping

	task.delay(GrabCooldown, function() -- wait for the cooldown before allowing another grab
		JumpGrabAnimation:Stop() -- stop climb animation once the cooldown is up
		State:AllowGrabAfter(0) -- let the player grab the ledge again
	end)
end

local CLIMB_ACTION_NAME = "ClimbUpLedge"

local function HandleClimbAction(_ActionName, InputState)
	if InputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass -- pass if this isnt the first press so repeats and releases dont trigger it
	end
	if not State.Hanging then
		return Enum.ContextActionResult.Pass -- pass if were not even hanging
	end
	ClimbUp() -- call ClimbUp since both checks passed
	return Enum.ContextActionResult.Sink -- sink so nothing else reacts to this input
end

ContextActionService:BindAction(
	CLIMB_ACTION_NAME, -- name for this action
	HandleClimbAction, -- function that handles the input
	true, -- create a touch button for mobile
	Enum.KeyCode.Space, -- bind to spacebar
	Enum.KeyCode.ButtonA -- bind to controller button a
)
ContextActionService:SetTitle(CLIMB_ACTION_NAME, "Climb") -- set the label shown on the touch button


RunService.Heartbeat:Connect(function()
	if State.Hanging then
		local Amount = Humanoid.MoveDirection:Dot(RootPart.CFrame.RightVector) -- get how far left or right the input is compared to which way were facing
		if Amount > 0.7 then
			PlayGrabAnimation(1) -- play the right grab animation
			AttemptSideMove(SideMoveDistance, "Right") -- attempt to side move to the right of the ledge
		elseif Amount < -0.7 then
			PlayGrabAnimation(-1) -- play the left grab animation
			AttemptSideMove(-SideMoveDistance, "Left") -- attempt to side move to the left of the ledge
		else
			PlayGrabAnimation(0) -- play the idle hang animation since theres no side input
		end
		return -- return early so ledge detection below doesnt run while were already hanging
	end
	if not State.CanGrab then return end -- return early if grabbing isnt allowed right now
	local Hit = workspace:Raycast(RootPart.Position, RootPart.CFrame.LookVector * DetectDistance, RaycastFilter) -- cast a ray forward from the root part to check for a ledge
	if not IsClimbableLedge(Hit) then return end -- return early if whatever we hit wasnt a ledge
	local WorldPosition = GetLedgeTop(Hit) -- get the actual top surface position of the ledge with GetLedgeTop
	local LedgeCFrame = CFrame.lookAt(WorldPosition, WorldPosition - Hit.Normal) -- build a cframe at the ledge facing away from the wall
	if (WorldPosition - Head.Position).Magnitude >= GrabReachDistance then return end -- return early if the ledge is too far to reach
	if not HasClearHeadroom(LedgeCFrame) then return end -- return early if theres no room to stand there
	local IsAirborne = Humanoid.FloorMaterial == Enum.Material.Air -- check if were not touching the ground
	local IsFalling = Humanoid:GetState() == Enum.HumanoidStateType.Freefall
		or Humanoid:GetState() == Enum.HumanoidStateType.Jumping -- check if were currently falling or jumping
	if not (IsAirborne and IsFalling) then return end -- return early if were not airborne and falling
	local Anchor = CreateLedgeConstraints() -- call CreateLedgeConstraints to set up the invisible anchor and physics constraints for the hang
	Anchor.CFrame = LedgeCFrame + Vector3.new(0, -2, 0) + LedgeCFrame.LookVector * -1 -- place the anchor slightly below and behind the ledge edge
	Humanoid.AutoRotate = false -- turn off autorotation
	State:BeginHang() -- enter the ledge hang state
	StopAllGrabAnimations() -- stop whatever grab animations are still playing
	LedgeGrabbed:Fire() -- fire the LedgeGrabbed event
	IdleGrabAnimation.Priority = Enum.AnimationPriority.Action4 -- set the idle hang animations priority to 4 to override any other animation
	IdleGrabAnimation.Looped = true -- make the idle hang animation loop
	IdleGrabAnimation:Play() -- play the idle hang animation
end)


Player.CharacterRemoving:Connect(function()
	ContextActionService:UnbindAction(CLIMB_ACTION_NAME) -- unbind the ledge grab action
	ClearLedgeConstraints() -- remove the ledge constraints 
end) 
