-- TODO CHAMP-959: Review rapid iteration VFX.

-- Missile-style VFXPlayer assets stand, hold briefly, then decay within a second or two. A held template loops its
-- Hold stage for far longer than anything plays it, so copies played from it burn steadily until destroyed.

-- Long enough that a held copy never plays out on its own
local HELD_SECONDS = 1e5

-- Returns whether the instance loops a Hold stage.
local function holdTiming(instance: Instance): boolean
	if typeof(instance:GetAttribute("Duration")) == "number" then
		instance:SetAttribute("Duration", HELD_SECONDS)
	end

	local holdDuration = instance:GetAttribute("HoldDuration")
	if typeof(holdDuration) == "number" and holdDuration > 0 then
		instance:SetAttribute("HoldLoopCount", math.ceil(HELD_SECONDS / holdDuration))
		return true
	end

	return false
end

local function createHeldTemplate(template: Model): Model
	local heldTemplate = template:Clone()
	local hasHold = holdTiming(heldTemplate)
	for _, descendant in heldTemplate:GetDescendants() do
		hasHold = holdTiming(descendant) or hasHold
	end

	if not hasHold then
		-- With no Hold stage to loop, a copy plays out its timeline, goes dark, and is never retired
		warn(`Held VFX template {template.Name} has no Hold stage, so its copies go dark but are never destroyed`)
	end

	return heldTemplate
end

return createHeldTemplate
