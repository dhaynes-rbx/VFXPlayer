-- TODO CHAMP-959: Review rapid iteration VFX.

local VFXPlayerClient = {}

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Sequence = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Sequence)
local Utility = require(ReplicatedStorage.Client.Systems.VFXPlayerClient.Utility)

local TINT_CURVE_SUFFIX = "TintOverDuration"
local MESH_EMITTER_TAG = "MeshEmitter"

-- Playing sequences are advanced by a single shared Heartbeat loop that only
-- runs while something is playing.
local activeSequences = {}
local activeSequenceRootParentRefs: { [Model]: number } = {}
local heartbeatConnection = nil

local function releaseRootParent(rootParent: Model?)
	if rootParent == nil then
		return
	end
	activeSequenceRootParentRefs[rootParent] -= 1
	if activeSequenceRootParentRefs[rootParent] <= 0 then
		activeSequenceRootParentRefs[rootParent] = nil
		rootParent:Destroy()
	end
end

local function pruneActiveSequences()
	for i = #activeSequences, 1, -1 do
		if activeSequences[i] == nil then
			table.remove(activeSequences, i)
		end
	end
end

--Advance every playing sequence; looping sequences restart, one-shots are
--retired and any instance spawned by PlayVFX is destroyed with them.
--
--Progress is added up frame by frame rather than read off the game clock, which
--stands still while a place is only being edited. Reading a clock there would leave
--every sequence sitting at nought for ever: frozen on its first frame, never
--reaching its end, and so never cleaned up.
local function stepSequences(deltaTime: number)
	pruneActiveSequences()

	local i = 1
	while i <= #activeSequences do
		local s = activeSequences[i]

		--An effect played inside something else -- a mesh particle carrying a
		--sequence of its own -- ends when whatever carried it is destroyed. A
		--looping one has nothing else to retire it, so without this copies would
		--gather for as long as particles kept spawning. Whatever destroyed the model
		--owns it, so there is nothing to destroy here.
		if s.model == nil or not s.model:IsDescendantOf(game) then
			table.remove(activeSequences, i)
			releaseRootParent(s.rootParent)
			continue
		end

		s.elapsed += deltaTime * s.speed

		if s.elapsed > s.duration then
			if s.looping then
				s.elapsed = 0
				s:Init()
				i += 1
			else
				--same as the editor: duration may end on the last stage, and
				--Rate would otherwise keep emitting after this driver is gone
				s:Finish()
				table.remove(activeSequences, i)
				if s.destroyModelOnComplete and s.model ~= nil then
					s.model:Destroy()
				end
				releaseRootParent(s.rootParent)
			end
		else
			-- TODO CHAMP-947: Apply a held projectile copy's Hold stage once and skip VFXPlayer driver Update while it loops (G09X-001)
			s:Update(s.elapsed)
			i += 1
		end
	end

	if #activeSequences == 0 and heartbeatConnection ~= nil then
		heartbeatConnection:Disconnect()
		heartbeatConnection = nil
	end
end

local function ensurePlaybackRunning()
	if heartbeatConnection == nil then
		heartbeatConnection = RunService.Heartbeat:Connect(stepSequences)
	end
end

local function startSequence(
	model,
	rootParent: Model?,
	destroyModelOnComplete,
	scale: number?,
	tint: Color3?,
	speed: number?
)
	local newSeq = Sequence:new()
	newSeq.model = model
	newSeq.elapsed = 0
	newSeq.duration = model:GetAttribute("Duration")
	newSeq.looping = model:GetAttribute("Looping")
	--playback bookkeeping: only instances spawned by PlayVFX are ours to destroy
	newSeq.destroyModelOnComplete = destroyModelOnComplete
	newSeq.scale = scale or 1
	newSeq.scaleRoot = rootParent or model
	newSeq.tint = tint
	newSeq.speed = speed or 1

	newSeq:Init()

	table.insert(activeSequences, newSeq)
	if rootParent ~= nil then
		newSeq.rootParent = rootParent
		activeSequenceRootParentRefs[rootParent] = (activeSequenceRootParentRefs[rootParent] or 0) + 1
	end
	ensurePlaybackRunning()

	return newSeq
end

--play a VFXSequence model that is already placed in the world. The model is
--left in place when playback completes.
function VFXPlayerClient.PlaySequence(model)
	return startSequence(model, nil, false)
end

--put a copy of `template` into the world at `cframe`, ready to be played.
--note: we should consider unification with other copy spawning methods
local function spawnCopy(template: Model, cframe: CFrame)
	local instance = template:Clone()
	-- Copies are only visuals, so no ray, roll or touch on this client should ever hit one
	for _, part in instance:QueryDescendants("BasePart") do
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
	end
	-- position before parenting so the copy never renders at the template's spot
	instance:PivotTo(cframe)
	--A copy exists only while it is playing, so it is nothing the place should ever
	--hold: unarchivable keeps whichever copies happen to be in flight when a place
	--is saved from being written into the file, which in the editor is the
	--difference between an effect and a mess left behind in the Explorer.
	instance.Archivable = false
	instance.Parent = Workspace
	return instance
end

--ScaleTo may leave emitter speed and acceleration alone; scaling both keeps each particle's path in shape
local function scaleCopy(instance: Model, scale: number)
	local emitterMotions: { [ParticleEmitter]: { speed: NumberRange, acceleration: Vector3 } } = {}
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			emitterMotions[descendant] = { speed = descendant.Speed, acceleration = descendant.Acceleration }
		end
	end

	instance:ScaleTo(instance:GetScale() * scale)

	for emitter, motion in emitterMotions do
		if emitter.Speed == motion.speed then
			emitter.Speed = NumberRange.new(motion.speed.Min * scale, motion.speed.Max * scale)
		end
		if emitter.Acceleration == motion.acceleration then
			emitter.Acceleration = motion.acceleration * scale
		end
	end
end

--Tint curves multiply the base colour, so they keep only their brightness or they would pull the hue back
local function recolorAttributes(instance: Instance, tint: Color3)
	for name, value in instance:GetAttributes() do
		local isTintCurve = string.sub(name, -#TINT_CURVE_SUFFIX) == TINT_CURVE_SUFFIX
		if typeof(value) == "ColorSequence" then
			instance:SetAttribute(
				name,
				if isTintCurve
					then Utility.DesaturateColorSequence(value)
					else Utility.RecolorColorSequence(value, tint)
			)
		elseif typeof(value) == "Color3" and not isTintCurve then
			instance:SetAttribute(name, Utility.RecolorColor(value, tint))
		end
	end
end

--recolour before any sequence starts, since its drivers capture base colours on Init
local function recolorCopy(instance: Model, tint: Color3)
	for _, descendant in instance:GetDescendants() do
		recolorAttributes(descendant, tint)

		-- These classes share no base class with Color, so the write goes through any
		if descendant:IsA("ParticleEmitter") or descendant:IsA("Beam") or descendant:IsA("Trail") then
			local colored: any = descendant
			colored.Color = Utility.RecolorColorSequence(colored.Color, tint)
		elseif descendant:IsA("Light") or descendant:IsA("BasePart") then
			local colored: any = descendant
			colored.Color = Utility.RecolorColor(colored.Color, tint)
		end
	end
end

--spawn a copy of a VFX template at `cframe` and play it, returning the spawned
--instance. A one-shot template's copy is destroyed once playback completes; a
--template with Looping set plays continuously, so destroy the returned instance
--when you want it to stop. `scale` multiplies the template's authored size,
--`tint` moves every colour in it onto the tint's hue, `skipMeshEmitters`
--plays it without its mesh particles (such as Blizzard's falling shards), and
--`speed` is the playback rate, so 0.5 stretches the effect to twice its length.
function VFXPlayerClient.PlayVFXFromTemplate(
	template: Model,
	cframe: CFrame,
	scale: number?,
	tint: Color3?,
	skipMeshEmitters: boolean?,
	speed: number?
)
	local instance = spawnCopy(template, cframe)

	--scale before any sequence starts, since its drivers capture base sizes on Init
	if scale ~= nil then
		scaleCopy(instance, scale)
	end

	if tint ~= nil then
		recolorCopy(instance, tint)
	end

	if skipMeshEmitters then
		for _, descendant in instance:GetDescendants() do
			if descendant:IsA("Attachment") and CollectionService:HasTag(descendant, MESH_EMITTER_TAG) then
				descendant:Destroy()
			end
		end
	end

	local hadAnySequence: boolean = false
	-- Is the Instance itself the sequence?
	if CollectionService:HasTag(instance, "VFXSequence") then
		local looping = instance:GetAttribute("Looping") == true
		startSequence(instance, nil, not looping, scale, tint, speed)
		hadAnySequence = true
	else
		-- If not, assume it is a container for direct sequence children
		for _, child in ipairs(instance:GetChildren()) do
			if CollectionService:HasTag(child, "VFXSequence") then
				local looping = child:GetAttribute("Looping") == true
				startSequence(child, instance, looping, scale, tint, speed)
				hadAnySequence = true
			end
		end
	end

	if not hadAnySequence then
		warn(`No VFXSequence tag found in instance {instance:GetFullName()}, nothing to play!`)
	end

	return instance
end

--Spawn a copy of a VFX template at `cframe` and play it through once, whatever the
--template does when it is played in its own right, destroying the copy at the end.
--
--For an effect nobody is left holding: an impact happens once, and a copy set
--looping would have nothing to stop it and no one to notice it was still there, so
--one would be left behind at every strike.
function VFXPlayerClient.PlayVFXOnce(template: Model, cframe: CFrame)
	local instance = spawnCopy(template, cframe)
	--the copy really is a one-shot, and says so, so that anything reading it later
	--sees what it is being played as
	instance:SetAttribute("Looping", false)
	startSequence(instance, nil, true)

	return instance
end

--assumed to be already placed in the world / workspace (environment vfx)
function VFXPlayerClient.PlayVFX(instance: Model)
	local looping = instance:GetAttribute("Looping") == true
	startSequence(instance, nil, not looping)
end

function VFXPlayerClient.start() end

return VFXPlayerClient
