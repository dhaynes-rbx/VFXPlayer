--[[
	VFXTextureBrowser

	A floating picker for ParticleEmitter textures already used in the open
	place. Roblox does not expose Studio's asset picker to plugins, so the useful
	local library for VFX authoring is built by scanning every ParticleEmitter
	and showing its Texture as an image.
]]

local VFXTextureBrowser = {}

local PADDING = 8
local HEADER_HEIGHT = 24
local CARD_WIDTH = 112
local CARD_HEIGHT = 126
local PREVIEW_INSET = 5
local LABEL_HEIGHT = 24

local widget = nil
local ui = nil
local state = nil
local connections = {}

local function color(guideColor: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return settings().Studio.Theme:GetColor(guideColor, modifier)
end

-- Asset URLs have accumulated several spellings over time. Use the numeric id
-- as the identity when one is present so the same image does not get two cards,
-- while retaining the original ContentId when the card is chosen.
local function textureKey(texture: string): string
	local id = string.match(texture, "^rbxassetid://(%d+)")
		or string.match(texture, "[?&]id=(%d+)")
		or string.match(texture, "^https?://www%.roblox%.com/asset/%?id=(%d+)")

	return if id ~= nil then "id:" .. id else string.lower(texture)
end

local function textureLabel(texture: string): string
	local id = string.match(texture, "^rbxassetid://(%d+)")
		or string.match(texture, "[?&]id=(%d+)")
		or string.match(texture, "^https?://www%.roblox%.com/asset/%?id=(%d+)")

	return id or texture
end

local function collectTextures(current: string): { string }
	local byKey = {}

	for _, descendant in game:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			local texture = descendant.Texture
			if texture ~= "" then
				byKey[textureKey(texture)] = texture
			end
		end
	end

	-- The current value normally comes from one of the emitters above. Keeping it
	-- explicitly also makes the picker stable if that emitter is removed between
	-- opening the row and opening this window.
	if current ~= "" then
		byKey[textureKey(current)] = current
	end

	local textures = {}
	for _, texture in byKey do
		table.insert(textures, texture)
	end

	table.sort(textures, function(a, b)
		return textureLabel(a) < textureLabel(b)
	end)

	return textures
end

local function makeLabel(text: string): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.SourceSans
	label.TextSize = 14
	label.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Text = text
	return label
end

local function build()
	if ui ~= nil and ui.root ~= nil then
		ui.root:Destroy()
	end
	ui = {}

	local root = Instance.new("Frame")
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
	root.BorderSizePixel = 0
	root.Parent = widget
	ui.root = root

	local textures = collectTextures(state.current)

	local summary = makeLabel(
		if #textures == 1 then "1 particle texture in this place" else string.format("%d particle textures in this place", #textures)
	)
	summary.Position = UDim2.fromOffset(PADDING, PADDING)
	summary.Size = UDim2.new(1, -PADDING * 2, 0, HEADER_HEIGHT)
	summary.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
	summary.Parent = root

	if #textures == 0 then
		local empty = makeLabel("No ParticleEmitter in this place has a texture assigned.")
		empty.Position = UDim2.fromOffset(PADDING, PADDING + HEADER_HEIGHT)
		empty.Size = UDim2.new(1, -PADDING * 2, 0, HEADER_HEIGHT)
		empty.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
		empty.Parent = root
		return
	end

	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(PADDING, PADDING + HEADER_HEIGHT)
	list.Size = UDim2.new(1, -PADDING * 2, 1, -(PADDING * 2 + HEADER_HEIGHT))
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 6
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = root

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	layout.CellPadding = UDim2.fromOffset(PADDING, PADDING)
	layout.FillDirectionMaxCells = 8
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	for index, texture in textures do
		local card = Instance.new("TextButton")
		card.Name = "Texture"
		card.LayoutOrder = index
		card.BackgroundColor3 = color(
			Enum.StudioStyleGuideColor.Item,
			if textureKey(texture) == textureKey(state.current) then Enum.StudioStyleGuideModifier.Selected else nil
		)
		card.BorderColor3 = color(Enum.StudioStyleGuideColor.Border)
		card.AutoButtonColor = true
		card.Text = ""
		card.Parent = list

		local preview = Instance.new("ImageLabel")
		preview.Position = UDim2.fromOffset(PREVIEW_INSET, PREVIEW_INSET)
		preview.Size = UDim2.new(1, -PREVIEW_INSET * 2, 1, -(LABEL_HEIGHT + PREVIEW_INSET * 2))
		preview.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
		preview.BorderSizePixel = 0
		preview.Image = texture
		preview.ScaleType = Enum.ScaleType.Fit
		preview.Parent = card

		local label = makeLabel(textureLabel(texture))
		label.Position = UDim2.new(0, PREVIEW_INSET, 1, -(LABEL_HEIGHT + PREVIEW_INSET))
		label.Size = UDim2.new(1, -PREVIEW_INSET * 2, 0, LABEL_HEIGHT)
		label.TextXAlignment = Enum.TextXAlignment.Center
		label.Parent = card

		card.Activated:Connect(function()
			state.commit(texture)
			widget.Enabled = false
		end)
	end
end

function VFXTextureBrowser.Open(pluginRef: Plugin, title: string, current: string, onCommit: (string) -> ())
	if widget == nil then
		local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Float, false, true, 520, 420, 300, 240)
		widget = pluginRef:CreateDockWidgetPluginGui("VFXTextureBrowser", info)
		widget.Name = "VFXTextureBrowser"
		widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

		table.insert(
			connections,
			settings().Studio.ThemeChanged:Connect(function()
				if state ~= nil and widget.Enabled then
					build()
				end
			end)
		)
	end

	widget.Title = title
	state = {
		current = current,
		commit = onCommit,
	}

	build()
	widget.Enabled = true
end

function VFXTextureBrowser.Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)

	state = nil
	ui = nil

	if widget ~= nil then
		widget:Destroy()
		widget = nil
	end
end

return VFXTextureBrowser
