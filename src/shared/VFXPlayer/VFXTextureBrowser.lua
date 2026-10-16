--[[
	VFXTextureBrowser

	A floating picker for ParticleEmitter textures already used in the open
	place. Roblox does not expose Studio's asset picker to plugins, so the useful
	local library for VFX authoring is built by scanning every ParticleEmitter
	and showing its Texture as an image. Uploaded assets also show the name from
	the marketplace underneath the image, with the numeric id beneath that.
]]

local VFXTextureBrowser = {}

local MarketplaceService = game:GetService("MarketplaceService")

local PADDING = 8
local HEADER_HEIGHT = 24
local CARD_WIDTH = 112
local CARD_HEIGHT = 132
local PREVIEW_INSET = 5
local NAME_HEIGHT = 16
local ID_HEIGHT = 14
local LABEL_HEIGHT = NAME_HEIGHT + ID_HEIGHT

local widget = nil
local ui = nil
local state = nil
local connections = {}

-- Uploaded asset names, keyed by numeric id. Lookups yield and can fail, so a
-- hit here lets a rebuilt picker (theme change, reopen) show the name immediately.
local assetNames: { [string]: string } = {}

local function color(guideColor: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return settings().Studio.Theme:GetColor(guideColor, modifier)
end

-- Asset URLs have accumulated several spellings over time. The numeric id is the
-- identity when one is present so the same image does not get two cards, while
-- the original ContentId is what a chosen card writes back.
local function textureAssetId(texture: string): string?
	return string.match(texture, "^rbxassetid://(%d+)")
		or string.match(texture, "[?&]id=(%d+)")
		or string.match(texture, "^https?://www%.roblox%.com/asset/%?id=(%d+)")
end

local function textureKey(texture: string): string
	local id = textureAssetId(texture)
	return if id ~= nil then "id:" .. id else string.lower(texture)
end

local function textureLabel(texture: string): string
	return textureAssetId(texture) or texture
end

-- The name the asset was uploaded with lives on the marketplace, not in the
-- ContentId. `apply` runs immediately on a cache hit, later once the lookup
-- returns, or never: a missing or private asset errors, and callers keep
-- showing the numeric id. A caller whose labels may be destroyed in the
-- meantime has to check for that itself.
local function resolveAssetName(assetId: string, apply: (string) -> ())
	local cached = assetNames[assetId]
	if cached ~= nil then
		apply(cached)
		return
	end

	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfoAsync(tonumber(assetId), Enum.InfoType.Asset)
		end)
		if not ok or type(info) ~= "table" then
			return
		end
		local name = info.Name
		if type(name) ~= "string" or name == "" then
			return
		end
		assetNames[assetId] = name
		apply(name)
	end)
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

		local captionTop = -(LABEL_HEIGHT + PREVIEW_INSET)
		local assetId = textureAssetId(texture)
		if assetId == nil then
			local label = makeLabel(texture)
			label.Position = UDim2.new(0, PREVIEW_INSET, 1, captionTop)
			label.Size = UDim2.new(1, -PREVIEW_INSET * 2, 0, LABEL_HEIGHT)
			label.TextXAlignment = Enum.TextXAlignment.Center
			label.Parent = card
		else
			local nameLabel = makeLabel(assetNames[assetId] or assetId)
			nameLabel.Position = UDim2.new(0, PREVIEW_INSET, 1, captionTop)
			nameLabel.Size = UDim2.new(1, -PREVIEW_INSET * 2, 0, NAME_HEIGHT)
			nameLabel.TextXAlignment = Enum.TextXAlignment.Center
			nameLabel.Parent = card

			local idLabel = makeLabel(assetId)
			idLabel.Position = UDim2.new(0, PREVIEW_INSET, 1, captionTop + NAME_HEIGHT)
			idLabel.Size = UDim2.new(1, -PREVIEW_INSET * 2, 0, ID_HEIGHT)
			idLabel.TextSize = 12
			idLabel.TextXAlignment = Enum.TextXAlignment.Center
			idLabel.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
			idLabel.Visible = assetNames[assetId] ~= nil
			idLabel.Parent = card

			resolveAssetName(assetId, function(name)
				if nameLabel.Parent == nil then
					return
				end
				nameLabel.Text = name
				idLabel.Visible = true
			end)
		end

		card.Activated:Connect(function()
			state.commit(texture)
			widget.Enabled = false
		end)
	end
end

VFXTextureBrowser.AssetId = textureAssetId
VFXTextureBrowser.ResolveAssetName = resolveAssetName

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
