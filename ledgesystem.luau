--made by yaxinn in roblox, yaxin on discord

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- this is where all our animation objects live, we just grab the folder once up front
local AnimationFolder = ReplicatedStorage:WaitForChild("Animations")

-- grabbing the local players Character stuff well need everywhere in this script.
-- we use "Player.Character or Player.CharacterAdded:Wait()" instead of just
-- Player.Character on its own because Character can be nil for a bit when the script runs or when we spawn in if we just read
-- Player.Character directly and it happened to be nil, every WaitForChild below
-- would error out immediately.
local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local RootPart = Character:WaitForChild("HumanoidRootPart")
local Head = Character:WaitForChild("Head")
local Animator = Humanoid:WaitForChild("Animator")

-- LoadAnimation caches the animation onto the Animator once
local IdleGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabIdle"))
local LeftGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabLeft"))
local RightGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabRight"))
local JumpGrabAnimation = Animator:LoadAnimation(AnimationFolder:WaitForChild("GrabJump"))

-- any part tagged with this in CollectionService counts as something you can grab onto so even map designers just add the tag and the script would work fine
local LEDGE_TAG = "Ledge"

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


--roblox already gives us BindableEvent for this kind of thing, but i built this small custom
--class instead which was mainly inspired by goodsignal
--i went with my own version over just using a BindableEvent because:
-- 1) a BindableEvent is a real Instance, so it has to be parented somewhere, shows up in the
--    Explorer, and carries the weight of being a full game object just to pass a signal around.
--    this is just a plain lua table, costs basically nothing and never needs to be parented or destroyed
-- 2) a BindableEvent only gives you :Fire(), :Connect(), :Wait(), theres no way to see whats
--    actually listening to it. with my own table i can just look at Listeners directly if i ever need to debug it

--the signal class here is just:
--a table (Listeners) = {} which holds a list of things to call
--a :Connect(fn) method that adds a function that list and hands back a Connection object
--a :Fire(...) method that calls all the functions in the list
local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

-- a Connection is just a little wrapper that remembers one listener function
-- and whether its still hooked up or not
function Connection.new(SignalRef, Fn)
	return setmetatable({
		Connected = true, -- starts off connected, this switches to false once :Disconnect() is called
		SignalRef = SignalRef,
		Fn = Fn,
	}, Connection)
end

-- switches Connected to false, doesnt actually remove it from the list,
-- Signal:Fire just skips over it next time because it checks this 
-- we do it this way instead of doing table.remove immediately
-- because removing an item from a table while something else might still be
-- looping over that same table causes errors and bugs
function Connection:Disconnect()
	self.Connected = false
end

-- makes a fresh signal with an empty list of listeners
function Signal.new() --
	return setmetatable({
		Listeners = {},
	}, Signal)
end

-- hooks up a new function to be called whenever this signal fires,
-- hands back a Connection object in case you ever want to disconnect it later
function Signal:Connect(Fn)
	local ConnectionObject = Connection.new(self, Fn)
	table.insert(self.Listeners, ConnectionObject)
	return ConnectionObject
end

-- calls every connected listener, passing along whatever arguments were given to Fire
function Signal:Fire(...) --
	local ListenersSnapshot = table.clone(self.Listeners) --the reason why do this relates back to my Connected = true, Connected = false,
	--because if i were to simply remove an item from a list while actively looping over that same list i would get index errors or skipped elements.
	--so we clone this array before looping, so if a listener disconnects itself
	for _, ConnectionObject in ListenersSnapshot do
		if ConnectionObject.Connected then
			--each listener gets called through task.spawn instead of directly so it gets its own thread so errors would only ever affect that listener
			task.spawn(ConnectionObject.Fn, ...)
		end
	end
end


-- LedgeGrabbed/LedgeReleased as signals rather thanjust calling GrabSound:Play() directly inside the grabbing code means the
-- code that detects and performs a grab doesnt need to know or care that a sound even exists

--the ClimbState class is like a tiny state machine but obviously falls short under most FSMs, i could have just used three booleans like Hanging, CanGrab, CanSideMove, etc instead
--of wrapping them in a class, but this gives us more control over it, and it is a lot easier to work with. mainly because the transitions between states have rules
--that belong together 
local ClimbState = {}
ClimbState.__index = ClimbState

-- sets up the starting state which sets up not hanging yet, allowed to grab, allowed to side-move
function ClimbState.new()
	return setmetatable({
		Hanging = false, -- true when actively hanging on a ledge
		CanGrab = true, -- false right after grabbing/climbing
		CanSideMove = true, --has a brief cooldown so it cant be spammed
	}, ClimbState)
end

function ClimbState:BeginHang() --by wrapping it in a class with methods like BeginHang() the rule gets baked into the method itself
	--this now means there only exactly one place in the whole script where this entering hang state is define and its impossible to enter it correctly
	self.Hanging = true
	self.CanGrab = false
end

-- sets Hanging to false whenever we let go or climb up
function ClimbState:EndHang()
	self.Hanging = false
end

function ClimbState:LockSideMove(Duration) -- this is the same idea as BeginHang, well never have to write a separate task.delay everytime i call LockSideMove
	self.CanSideMove = false
	task.delay(Duration, function() --we delay this to lock out movement to spam
		self.CanSideMove = true
	end)
end

-- lets us re-enable grabbing after some delay, used after climbing up so you cant instantly re-grab the same ledge you just climbed off of
function ClimbState:AllowGrabAfter(Duration)
	task.delay(Duration, function()
		self.CanGrab = true
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

--everything about detecting a ledge in this system boils down to using Raycasting, we shoot an invisible line from a point in a direction for some length

-- quick rundown of how the raycasting in this script actually works:
--
-- workspace:Raycast(origin, direction, raycastParams) is the method that actually
-- performs a raycast. origin is a Vector3 where the ray starts, direction is a
-- Vector3 that points which way the ray goes and how far (its length/magnitude
-- is the max distance), and raycastParams is an optional RaycastParams object
-- that controls what the ray is allowed to hit
--
-- if the ray hits something, Raycast returns a RaycastResult with fields like
-- .Instance (the part that got hit), .Position (world position of the hit),
-- .Normal (the direction the hit surface is facing), and .Distance. if it hits
-- nothing, it just returns nil
--
-- RaycastParams is that config object mentioned above. the two properties we
-- use on it are FilterType (Enum.RaycastFilterType.Include or .Exclude) and
-- FilterDescendantsInstances (a list of instances to include/exclude, including
-- their children). we set FilterType to Exclude and hand it our own Character,
-- so the ray ignores our own body and only reports hits against other parts
--
-- i originally looked into how other people build these systems, and a lot of
-- ledge/vault setups (see a devforum thread on this: https://devforum.roblox.com/t/ledge-system-help/4300804/14)
-- use several raycasts stacked together every frame: one cast forward to find
-- an obstacle (whatever the raycast is hitting), then a handful of casts upward near that obstacle to feel out
-- where the clear space starts, then another cast forward from up there to
-- confirm that space is actually open
--
-- my version skips most of that because every grabbable part is already tagged
-- with LEDGE_TAG ahead of time, so i dont need to blindly search for where an
-- obstacles edge is. i only need 2 raycasts, one forward cast to detect the tagged ledge part at all (below, and
-- again in the RunService.Heartbeat loop further down), and one more upward
-- cast in HasClearHeadroom to make sure theres a space above the exact top
-- surface that GetLedgeTops dot product math already calculated for me.
-- rather than searching for the surface and the clearance blindly with a bunch
-- of raycasts, i split the work by letting the math finding the surface and then one raycast just
-- doublechecks the space above it is free
local RaycastFilter = RaycastParams.new()
--this exists so the ray doesnt detect the characters own body as a wall in front of itself
RaycastFilter.FilterType = Enum.RaycastFilterType.Exclude
RaycastFilter.FilterDescendantsInstances = {Character}
--this raycast extends back to IsClimbableLedge which filters what kind of hit counts.

-- sound that plays whenever we grab onto a ledge
local GrabSound = Instance.new("Sound")
GrabSound.SoundId = "rbxassetid://79480035097773"
GrabSound.Volume = 0.6
GrabSound.Parent = RootPart

-- sound that plays whenever we climb up and off a ledge
local ClimbSound = Instance.new("Sound")
ClimbSound.SoundId = "rbxassetid://9116634613"
ClimbSound.Volume = 0.6
ClimbSound.Parent = RootPart

-- hooking the sounds up to the signals so they play automatically
LedgeGrabbed:Connect(function()
	GrabSound:Play()
end)

LedgeReleased:Connect(function()
	ClimbSound:Play()
end)

--this is the math heavy part of this script, it is what determines the surface of a ledge to grab onto
--basically we just look at all the vectors of a part and using some math we can get the Dot product of every vector to the worlds up vector (0, 1, 0) with being closer to 1 means upwards
local function GetLedgeTop(RaycastResult)
	local Instance = RaycastResult.Instance
	local PartCFrame = Instance.CFrame --grab the parts CFrame so we know which way its rotated
	local Size = Instance.Size
	local Axes = {
		{Direction = PartCFrame.RightVector,  Size = Size.X}, --one side of the part along its X axis
		{Direction = -PartCFrame.RightVector, Size = Size.X}, --and the opposite side, same axis just flipped
		{Direction = PartCFrame.UpVector,      Size = Size.Y}, --one side along its Y axis (normally "up" if the part isnt rotated)
		{Direction = -PartCFrame.UpVector,     Size = Size.Y}, --the flipped version, matters if the part is upside down
		{Direction = PartCFrame.LookVector,    Size = Size.Z}, --one side along its Z axis
		{Direction = -PartCFrame.LookVector,   Size = Size.Z}, --and the flipped version of that too
	}
	--basically every part has 6 sides/faces and we dont know ahead of time which one is actually facing up since the part could be rotated any which way. so we just grab all 6
	--directions here and check them one by one below. if we only checked 3 we could easily miss the real top face when a part is flipped or turned weird.

	-- start with face 1 as a placeholder guess, just so these variables
	-- arent empty before the loop runs. this does not mean face 1 is
	-- actually the best one, its just filler for now
	local BestDirection, BestSize, BestDot = Axes[1].Direction, Axes[1].Size, -math.huge
	-- BestDot starts at negative math.huge on purpose, that way literally any real dot product we calculate below is guaranteed to be bigger
	-- than it, so our placeholder guess gets overwritten immediately on the first loop pass anyway

	-- this loop goes through all 6 entries in Axes one at a time
	-- (right, left, up, down, front, back)
	for _, Axis in Axes do
		local Dot = Axis.Direction:Dot(Vector3.new(0, 1, 0)) --this number tells us how much a direction points "up". closer to 1 = pointing straight up, 0 = pointing sideways, negative = pointing down

		-- if this face is more upward-facing than whatever weve found so far, replace our "best" with this one
		if Dot > BestDot then
			BestDot = Dot --best score of face thats facing upward (closer to 1 = more upward)
			BestDirection = Axis.Direction --tells what way the top face points in worldspace
			BestSize = Axis.Size --the parts thickness along the faces axis we use it later in local WorldTop to figure out the physical distance from center to that surface
		end
		-- if its not better, we just move on to the next face,
		-- BestDirection/BestSize/BestDot stay unchanged
	end
	--after that loop were left with whichever of the 6 faces points closest to straight up

	local WorldTop = Instance.Position + BestDirection * (BestSize / 2) --in order to get the surface of a part we start from using Instance.Position but the issue is that gives us only the center of the part, using
	--some simple math we can just use BestSize divided by 2 (since it already starts from the center) then we just use BestDirection to step outward to get on the top surface of our part
	return Vector3.new(RaycastResult.Position.X, WorldTop.Y, RaycastResult.Position.Z) --keep the X and Z from wherever the ray actually hit, but swap in the real height (Y) of the top face we just found
end

-- a raycast result only counts as a grabbable ledge if it actually hit something and that something is tagged with our LEDGE_TAG
local function IsClimbableLedge(RaycastResult)
	return RaycastResult ~= nil and CollectionService:HasTag(RaycastResult.Instance, LEDGE_TAG)
end

-- stops every grab animation at once, used whenever were about to switch to a different animation or leave the hanging state entirely.
local function StopAllGrabAnimations()
	IdleGrabAnimation:Stop()
	LeftGrabAnimation:Stop()
	RightGrabAnimation:Stop()
	JumpGrabAnimation:Stop()
end

-- picks which grab animation to play based on which way were pressing.
-- Direction here is basically how much are we holding left/right as a number from HandleMoveDirectionChangeds dot product below
local function PlayGrabAnimation(Direction)
	if Direction > 0.3 then
		-- without this check, every single MoveDirection update (which can fire
		-- multiple times a frame) would call :Play() again
		if RightGrabAnimation.IsPlaying then return end
		IdleGrabAnimation:Stop()
		LeftGrabAnimation:Stop()
		RightGrabAnimation.Priority = Enum.AnimationPriority.Action4 -- Action4 is the highest priority tier, guarantees this overrides any lower-priority animation still trying to play on the same body parts
		RightGrabAnimation.Looped = true
		RightGrabAnimation:Play()
	elseif Direction < -0.3 then
		-- same idea but for leaning left
		if LeftGrabAnimation.IsPlaying then return end
		IdleGrabAnimation:Stop()
		RightGrabAnimation:Stop()
		LeftGrabAnimation.Priority = Enum.AnimationPriority.Action4
		LeftGrabAnimation.Looped = true
		LeftGrabAnimation:Play()
	else
		-- not really leaning either way, so just idle-hang instead
		if IdleGrabAnimation.IsPlaying then return end
		LeftGrabAnimation:Stop()
		RightGrabAnimation:Stop()
		IdleGrabAnimation.Priority = Enum.AnimationPriority.Action4
		IdleGrabAnimation.Looped = true
		IdleGrabAnimation:Play()
	end
end

-- destroys anything we made for the current ledge grab (the invisible anchor part,
-- both attachments, and both align constraints) so we dont leak instances every
-- time we grab a new ledge. if we didnt do this, every single ledge grab would
-- create a brand new Part + 2 Attachments + 2 Constraints and just leave the old
-- ones sitting in the workspace forever, since nothing else is destroying them.
local function ClearLedgeConstraints() --a function to clear constraints to prevent memory leaks we run it at the start of CreateLedgeConstraints
	if PositionAlign then PositionAlign:Destroy() PositionAlign = nil end
	if OrientationAlign then OrientationAlign:Destroy() OrientationAlign = nil end
	if RootAttachment then RootAttachment:Destroy() RootAttachment = nil end
	if AnchorAttachment then AnchorAttachment:Destroy() AnchorAttachment = nil end
	if LedgeAnchor then LedgeAnchor:Destroy() LedgeAnchor = nil end
end

local function CreateLedgeConstraints() --when we find a ledge we dont just use CFrame = LedgeCFrame but instead use these constraints to move the character to the ledge.
	--it uses two attachments, an AlignPosition and an AlignOrientation. directly setting a characters CFrame every frame fights the Roblox physics engine. our character
	--has a Humanoid, collision, gravity, its own velocity and etc... snapping its CFrame is like teleporting it which can cause jitter, clip through walls, break other systems (network ownership, camera smoothing)
	ClearLedgeConstraints() -- clean up any leftovers from a previous grab first, see the comment above ClearLedgeConstraints for why this matters

	-- this invisible anchor part is basically a "target" floating in the world at
	-- the ledges position. instead of moving the character directly, we move this
	-- separate throwaway part, and let the constraints below pull the character
	-- towards it. the reason we need a whole extra part for this rather than just
	-- constraining the character straight to a Vector3/CFrame is because Roblox constraints
	-- (AlignPosition/AlignOrientation) require an Attachment on both ends, and an
	-- Attachment has to be parented to some Instance that physically exists in the
	-- world, it cant just float at a bare position with nothing to attach to.
	-- so we make this tiny invisible part purely to give the target attachment
	-- somewhere to live
	LedgeAnchor = Instance.new("Part") --we create a new part called LedgeAnchor
	LedgeAnchor.Size = Vector3.one
	LedgeAnchor.Anchored = true
	--determines whether a part is immovable by physics.
	LedgeAnchor.CanCollide = false
	--determines whether a part will physically interact with other parts.
	LedgeAnchor.CanTouch = false
	--this property determines if Touched and TouchEnded events fire on the part.
	LedgeAnchor.CanQuery = false
	--this property determines whether the part is considered during spatial query operations, such as GetPartBoundsInBox or Raycast
	LedgeAnchor.Transparency = 1 --just turns the part invisible lol
	LedgeAnchor.Parent = workspace
	--engine only steps things inside the workspace so if we put it inside ServerStorage or nil parent the engine skips it

	-- attachments are just connection points that constraints hook onto, one on
	-- our characters root part and one on the invisible anchor. AlignPosition and
	-- AlignOrientation both specifically require an Attachment0 and Attachment1 to
	-- know what two points theyre trying to pull together, you cant point a
	-- constraint directly at a Part, only at an Attachment
	RootAttachment = Instance.new("Attachment") --atch 0
	RootAttachment.Parent = RootPart ----local RootPart = Character:WaitForChild("HumanoidRootPart"), this was set to the top
	AnchorAttachment = Instance.new("Attachment") --atch 1
	AnchorAttachment.Parent = LedgeAnchor

	PositionAlign = Instance.new("AlignPosition")
	PositionAlign.Attachment0 = RootAttachment
	PositionAlign.Attachment1 = AnchorAttachment
	PositionAlign.MaxForce = 50000
	--maximum force magnitude the constraint can apply to achieve its goal
	PositionAlign.MaxVelocity = 20
	--maximum speed the attachments can move when converging
	PositionAlign.Responsiveness = 25
	--controls how quickly the constraint reaches its goal
	PositionAlign.RigidityEnabled = false
	--whether force is dependent on other properties, or if the physics solver reacts as quickly as possible to complete the alignment
	PositionAlign.Parent = RootPart

	-- same reasoning as AlignPosition above, but this one handles rotation instead
	-- of position, so the characters facing direction also gets pulled to match
	-- the ledges orientation, not just its position
	OrientationAlign = Instance.new("AlignOrientation")
	OrientationAlign.Attachment0 = RootAttachment
	OrientationAlign.Attachment1 = AnchorAttachment
	OrientationAlign.MaxTorque = 50000
	--maximum torque the constraint can use to reach its goal
	OrientationAlign.MaxAngularVelocity = 20
	--maximum angular velocity the constraint can use to reach its goal
	OrientationAlign.Responsiveness = 25
	--controls how quickly the constraint reaches its goal
	OrientationAlign.RigidityEnabled = false
	OrientationAlign.Parent = RootPart

	return LedgeAnchor
end

--we use a raycast to check if we have spaces above us to stand on instead of relying on the parts size cause
--a part doesnt know if a part is on top of it
local function HasClearHeadroom(LedgeCFrame)
	-- Origin is offset slightly below  and forward of the ledges position, direction is UpVector * 3 (so it casts
	-- 3 studs upward). workspace:Raycast returns a RaycastResult if it hits
	-- something in that space, or nil if the path is clear
	local TopCheck = workspace:Raycast(
		LedgeCFrame.Position + Vector3.new(0, -1, 0) + LedgeCFrame.LookVector,
		LedgeCFrame.UpVector * 3,
		RaycastFilter
	)
	return TopCheck == nil -- nil means the ray hit nothing, meaning the space above is clear
end

-- handles moving sideways onto a neighboring ledge. takes the raycast hit
-- that found the new ledge, figures out its top surface, and if were close
-- enough and theres headroom, tweens our invisible anchor over to it
local function MoveToLedge(RaycastResult, DirectionName)
	local WorldPosition = GetLedgeTop(RaycastResult)
	local LedgeCFrame = CFrame.lookAt(WorldPosition, WorldPosition - RaycastResult.Normal)

	-- return if theres no room to stand, or if the new spot is actually too far to reach
	if not HasClearHeadroom(LedgeCFrame) then return end
	if (WorldPosition - Head.Position).Magnitude >= SideMoveReachDistance then return end

	-- tween anchor so moving to the ledge doesnt look like we teleport to it
	local Target = LedgeCFrame + Vector3.new(0, -2, 0) + LedgeCFrame.LookVector * -1
	TweenService:Create(
		LedgeAnchor,
		TweenInfo.new(0.3, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{CFrame = Target}
	):Play()

	State:LockSideMove(SideMoveDelay) -- brief cooldown so this cant be spammed every frame

	if DirectionName == "Right" then
		RightGrabAnimation:Play()
	elseif DirectionName == "Left" then
		LeftGrabAnimation:Play()
	end
end

-- casts a couple rays out to the side to look for a ledge we could move onto.
-- Direction is a signed distance (positive = right, negative = left)
local function AttemptSideMove(Direction, AnimationName)
	if not State.CanSideMove then return end -- still on cooldown from the last side move, dont bother

	-- the first ray shoots from the players head angled sideways plus forward to try to find a ledge in either direction
	local SideHit = workspace:Raycast(
		Head.Position,
		Head.CFrame.RightVector * Direction + Head.CFrame.LookVector * 8,
		RaycastFilter
	)
	if IsClimbableLedge(SideHit) then
		MoveToLedge(SideHit, AnimationName)
		return
	end

	--the second ray runs if the first one misses and checks around to see if theres a corner of the ledge
	local CornerHit = workspace:Raycast(
		Head.Position + Vector3.new(0, -1, 0) + Head.CFrame.RightVector * Direction,
		Head.CFrame.RightVector * -Direction + Head.CFrame.LookVector * 2,
		RaycastFilter
	)
	if IsClimbableLedge(CornerHit) then
		MoveToLedge(CornerHit, AnimationName)
	end
end

-- handles actually climbing up and off the ledge were currently hanging on
local function ClimbUp()
	if not State.Hanging then return end -- cant climb up if were not even hanging

	-- exit the hanging state and clean everything up
	State:EndHang() --we enter EndHang state after we climb up
	Humanoid.AutoRotate = true -- reenable AutoRotate so the player can look and move around with shiftlock again too
	ClearLedgeConstraints()
	StopAllGrabAnimations()
	LedgeReleased:Fire()

	-- play the climbing animation
	JumpGrabAnimation.Priority = Enum.AnimationPriority.Action4
	JumpGrabAnimation.Looped = false
	JumpGrabAnimation:Play()
	local BoostAttachment = Instance.new("Attachment")
	BoostAttachment.Parent = RootPart

	local Boost = Instance.new("LinearVelocity")
	Boost.Attachment0 = BoostAttachment
	Boost.MaxForce = 67
	Boost.RelativeTo = Enum.ActuatorRelativeTo.World -- we want this boost direction fixed in world space (always "up and forward" in absolute terms), not relative to the characters current rotation, which could be tilted from the AlignOrientation we just turned off
	Boost.VectorVelocity = RootPart.CFrame.LookVector * JumpForwardForce + Vector3.new(0, JumpUpForce, 0)
	Boost.Parent = RootPart

	-- Debris:AddItem auto-destroys these after BoostDuration seconds. we use Debris here instead of a manual task.delay(...):Destroy() because its a temporary cleanup task
	Debris:AddItem(BoostAttachment, BoostDuration)

	Humanoid:ChangeState(Enum.HumanoidStateType.Jumping) -- forces the Humanoids internal state machine into Jumping s

	-- after the cooldown, stop the climb animation and let ourselves grab ledges again
	task.delay(GrabCooldown, function()
		JumpGrabAnimation:Stop()
		State:AllowGrabAfter(0)
	end)
end

local CLIMB_ACTION_NAME = "ClimbUpLedge"

--only fires on initial key press, if its not Begin or were not hanging we return pass
local function HandleClimbAction(_ActionName, InputState)
	if InputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass -- only react on the first press not on repeat/end states
	end
	if not State.Hanging then
		return Enum.ContextActionResult.Pass
	end
	--only when both pass we call sink on ClimbUp()
	ClimbUp()
	return Enum.ContextActionResult.Sink -- sink means that the input was handled and nothing else should pass onto it
end

--using ContextActionService lets us cover the action for both controller and spacebar. the pass/sink means we also dont
--have to manually track whether the input gets used already
ContextActionService:BindAction(
	CLIMB_ACTION_NAME,
	HandleClimbAction,
	true,
	Enum.KeyCode.Space,
	Enum.KeyCode.ButtonA
)
ContextActionService:SetTitle(CLIMB_ACTION_NAME, "Climb")


-- this is the main loop that constantly checks to grab a ledge or not
-- we use RunService.Heartbeat over a Touched event on ledge parts,
-- because Heartbeat lets us run our own conditions every frame (distance, angle,
-- airborne state, cooldowns) instead of reacting only when the touched event fires
RunService.Heartbeat:Connect(function()
	
	
	--we use movedirection because it directly tells us which way the player is holding
	--the movement input (like holding down a or d) the dot product against RightVector converts
	--how far left or right we are relative to the way were facing. If we used an event outside
	--this loop instead of running every fame it would just wait for it to change and sometimes
	--just not sidemove at all
	
	
	if State.Hanging then
		local Amount = Humanoid.MoveDirection:Dot(RootPart.CFrame.RightVector)
		if Amount > 0.7 then
			PlayGrabAnimation(1)
			AttemptSideMove(SideMoveDistance, "Right")
		elseif Amount < -0.7 then
			PlayGrabAnimation(-1)
			AttemptSideMove(-SideMoveDistance, "Left")
		else
			PlayGrabAnimation(0)
		end
		return -- no need to run ledge-detection below while already hanging
	end

	-- we return if we cant grab so we dont just run Heartbeat like a bot
	if not State.CanGrab then return end
	-- shoot a ray forward from the character to see if theres a wall/ledge in front of us. origin is RootPart.Position, direction is
	-- LookVector * DetectDistance (forward, out to DetectDistance studs). Hit will
	-- either be a RaycastResult or nil depending on whether anythings in the way
	local Hit = workspace:Raycast(RootPart.Position, RootPart.CFrame.LookVector * DetectDistance, RaycastFilter)
	if not IsClimbableLedge(Hit) then return end
	-- figure out exactly where the top surface of that ledge actually is
	local WorldPosition = GetLedgeTop(Hit)
	local LedgeCFrame = CFrame.lookAt(WorldPosition, WorldPosition - Hit.Normal)
	-- too far away to actually reach it, or no headroom to stand there so we just return and dont ledge
	if (WorldPosition - Head.Position).Magnitude >= GrabReachDistance then return end
	if not HasClearHeadroom(LedgeCFrame) then return end
	-- only allow grabbing while were actually in the air and falling/jumping.
	local IsAirborne = Humanoid.FloorMaterial == Enum.Material.Air
	local IsFalling = Humanoid:GetState() == Enum.HumanoidStateType.Freefall
		or Humanoid:GetState() == Enum.HumanoidStateType.Jumping
	if not (IsAirborne and IsFalling) then return end
	-- if everything checks out we can perform the actual grab onto a ledge
	-- set up the invisible anchor and physics constraints, then snap them
	-- into place right at the ledge (with a small offset so the character
	-- hangs slightly below/behind the edge)
	local Anchor = CreateLedgeConstraints()
	Anchor.CFrame = LedgeCFrame + Vector3.new(0, -2, 0) + LedgeCFrame.LookVector * -1
	Humanoid.AutoRotate = false --disable autorotation so camera shift lock doestn get in the way to make it look weird as shit
	State:BeginHang()
	StopAllGrabAnimations()
	LedgeGrabbed:Fire()
	IdleGrabAnimation.Priority = Enum.AnimationPriority.Action4
	IdleGrabAnimation.Looped = true
	IdleGrabAnimation:Play()
end)

-- cleanup for cas and the ledge constraints when the character dies or respawns to prevent memory leaks
Player.CharacterRemoving:Connect(function()
	ContextActionService:UnbindAction(CLIMB_ACTION_NAME)
	ClearLedgeConstraints()
end) 
