-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPDecalsGE API.
--- Syncs liveries made in the game's livery editor. The owner sends the livery's layers (the same json the editor saves
--- in settings/dynamicDecals) with the vehicle data, and everyone else bakes them onto their copy of the vehicle with
--- their own decal projection. Nothing changes on the server, it stores and replays the vehicle data as it is.
---
--- A decal projection uses a lot of video memory (measured about 45 MB at 1024x512, 140 MB at 2048x1024 and 440 MB at
--- 4096x2048) and doesn't give it back when it's freed, so there's a fixed pool of them that gets reused, and the
--- nearest vehicles get them. The others show their normal paint until one is free.
--- @module MPDecalsGE

local M = {}

local SAVE_DIR = "/settings/dynamicDecals/"
local MAX_LIVERY_SIZE = 256 * 1024 -- bytes of layer json, bigger liveries aren't sent
local MAX_LIVERIES = 5 -- remote liveries shown at once, the size of the pool
local SETTLE_FRAMES = 3 -- frames of project / combine after a bake, the textures stay after that
local PRIORITY_INTERVAL = 2 -- seconds between choosing which vehicles get a livery, nearest first
local PAINT_LAYERS = { { type = 1, name = "Paint", blendMode = 0, color = { 1, 1, 1, 1 }, colorPaletteMapId = 1, enabled = true, uid = "BMP-PAINT" } }

local pool = {} -- { projection, textureSet, owner }, created up to MAX_LIVERIES and then reused
local paint -- { projection, textureSet } shared by liveried vehicles without a projection, shows their own paint
local liveries = {} -- [gameVehicleID] = { dcl, slot, settle }
local bakeQueue = {} -- gameVehicleIDs waiting for a bake, one per frame
local loggedMissing = {} -- [path] = true, missing livery files are only logged once
local priorityTimer = 0


-- ============= HELPERS =============

local function isEnabled()
	return settings.getValue("showLiveries") ~= false
end

-- read once, when the first projection is made. Changing the size of a projection doesn't give the old textures back,
-- so a change applies after restarting the game
local poolSize = nil
local function textureSize()
	poolSize = poolSize or (settings.getValue("highQualityLiveries") and Point2I(2048, 1024) or Point2I(1024, 512))
	return poolSize
end

local function findPaintDesign(node)
	if not node then return end
	if node.id == "paint_design" then return node end
	for _, child in pairs(node.children or {}) do
		local found = findPaintDesign(child)
		if found then return found end
	end
end

local function paintDesignPart(gameVehicleID)
	local vehicleData = core_vehicle_manager.getVehicleData(gameVehicleID)
	local node = vehicleData and findPaintDesign(vehicleData.config.partsTree)
	return node and node.chosenPartName, vehicleData
end

-- the texture and font files a layer uses, a layer with a file we don't have is left out
local function missingFile(layer)
	for key, value in pairs(layer) do
		if type(value) == "string" and (key:find("TexturePath$") or key:find("FontPath$")) and value ~= "" and value ~= "/" and not FS:fileExists(value) then
			return value
		end
	end
end

local function withoutMissingFiles(layers)
	local result = {}
	for _, layer in ipairs(layers) do
		local missing = missingFile(layer)
		if missing then
			if not loggedMissing[missing] then
				loggedMissing[missing] = true
				log('W', 'MPDecalsGE', "A livery layer uses '" .. missing .. "' which isn't installed, the layer is left out")
			end
		else
			if type(layer.children) == "table" then layer.children = withoutMissingFiles(layer.children) end
			table.insert(result, layer)
		end
	end
	return result
end

-- the editor api only deserializes into its own layer stack, so the layers are added and taken back out again and the
-- stack is left as it was (it's also the stack of your own livery editor)
local function deserializeLayers(layerStackData)
	local api = extensions.editor_api_dynamicDecals
	if not api then
		extensions.load("editor_api_dynamicDecals")
		api = extensions.editor_api_dynamicDecals
		if not api then return end
	end
	local stack = api.getLayerStack()
	local count = #stack
	api.onDeserialized({ layerStackData = layerStackData })
	local layers = {}
	for i = count + 1, #stack do table.insert(layers, stack[i]) end
	for i = #stack, count + 1, -1 do table.remove(stack, i) end
	return layers
end

-- the same materials the editor uses: the paint design part's dynDecalMaterials, else the material named after the
-- vehicle, else one ending in main or body
local function setMaterials(projection, gameVehicleID, jbeam)
	local partName, vehicleData = paintDesignPart(gameVehicleID)
	local part = partName and vehicleData.vdata.activePartsData[partName]
	local wanted = {}
	for _, name in ipairs(part and part.dynDecalMaterials or {}) do wanted[name] = true end

	projection:clearMaterialIdx()
	local found, named, main, body = false, nil, nil, nil
	for idx, name in pairs(projection:getShapeMaterialNames()) do
		if wanted[name] then
			projection:addMaterialIdx(idx)
			found = true
		end
		if name == jbeam then named = idx end
		if not main and string.endswith(name, "main") then main = idx end
		if not body and string.endswith(name, "body") then body = idx end
	end
	if found then return true end
	local idx = named or main or body
	if idx then projection:addMaterialIdx(idx) end
	return idx ~= nil
end

local function placeProjection(projection, veh)
	local refNode = veh:getRefNodeMatrix()
	projection:setShape(veh:getDecalProjectionShape())
	projection:setWorldTransform(refNode)
	projection:setTransform(refNode:copy():setPosition(vec3(0, 0, 0)):inverse())
	projection:setMirrorOffset(veh:getSpawnLocalAABB():getCenter().x)
end

local function projectAndCombine(projection, textureSet, veh)
	placeProjection(projection, veh)
	projection:projectDynamicDecals(veh:getRefNodeMatrix():fullInverse():mul(getCameraTransform()), getCameraProjMatrix())
	projection:combineTextures(textureSet)
end

local function bakeOnto(projection, veh, gameVehicleID, layerStackData)
	local jbeam = veh:getJBeamFilename()
	placeProjection(projection, veh)
	if not setMaterials(projection, gameVehicleID, jbeam) then
		log('W', 'MPDecalsGE', "No livery material found on " .. jbeam .. ", the livery isn't shown")
		return false
	end
	local layers = deserializeLayers(layerStackData)
	if not layers then return false end
	projection:clearBakedTextures()
	local result = projection:bakeLayers(layers, jbeam)
	if result and result.status and result.status.code ~= 0 then
		log('W', 'MPDecalsGE', "Livery baked with status " .. tostring(result.status.code))
	end
	return true
end

-- vehicles on the dynamic textures skin without a projection of their own show this, a plain fill of their paint
local function getPaint(veh, gameVehicleID)
	if not paint then
		local projection = DecalProjection("", Point2I(16, 8), 1, 0)
		paint = { projection = projection, textureSet = projection:getTextureSet() }
		if not bakeOnto(projection, veh, gameVehicleID, PAINT_LAYERS) then
			paint = nil
			return
		end
		for _ = 1, SETTLE_FRAMES do projectAndCombine(projection, paint.textureSet, veh) end
	end
	return paint
end

local function showPaint(gameVehicleID)
	local veh = getObjectByID(gameVehicleID)
	local p = veh and getPaint(veh, gameVehicleID)
	if p then veh:setTextureSet("@DynamicTexture", p.textureSet) end
end

local function acquireSlot(gameVehicleID)
	for _, slot in ipairs(pool) do
		if not slot.owner then
			slot.owner = gameVehicleID
			return slot
		end
	end
	if #pool < MAX_LIVERIES then
		local projection = DecalProjection("", textureSize(), 1, 0)
		local slot = { projection = projection, textureSet = projection:getTextureSet(), owner = gameVehicleID }
		table.insert(pool, slot)
		return slot
	end
end

local function releaseSlot(livery)
	if livery and livery.slot then
		livery.slot.owner = nil
		livery.slot = nil
	end
	if livery then livery.settle = 0 end
end

local function queueBake(gameVehicleID)
	for _, id in ipairs(bakeQueue) do
		if id == gameVehicleID then return end
	end
	table.insert(bakeQueue, gameVehicleID)
end


-- ============= SENDING =============

--- Returns the livery to send with one of our vehicles, nil if it doesn't have a saved livery on.
-- @tparam number gameVehicleID
-- @treturn table|nil { v, name, hash, layers }
local function getOwnLivery(gameVehicleID)
	local veh = getObjectByID(gameVehicleID)
	local partName = veh and paintDesignPart(gameVehicleID)
	if not partName then return end

	local prefix = veh:getJBeamFilename() .. "_skin_"
	if partName:sub(1, #prefix) ~= prefix then return end
	local name = partName:sub(#prefix + 1)
	if name == "dynamicTextures" then return end -- still in the livery editor, only saved liveries are sent

	local data = jsonReadFile(SAVE_DIR .. name .. ".dynDecals.json")
	if type(data) ~= "table" or type(data.layerStackData) ~= "table" then return end

	local layersJson = jsonEncode(data.layerStackData)
	if #layersJson > MAX_LIVERY_SIZE then
		log('W', 'getOwnLivery', string.format("Livery '%s' is too big to send (%d KB)", name, #layersJson / 1024))
		return
	end
	return { v = 1, name = name, hash = hashStringSHA1(layersJson), layers = data.layerStackData }
end


-- ============= RECEIVING =============

--- Puts a remote vehicle's config on the editor's dynamic textures skin so the livery can be baked onto it. The
--- owner's own skin part only exists on their computer.
-- @tparam string vehicleName
-- @tparam table vehicleConfig the received config (flat parts)
-- @tparam table dcl the received livery
-- @treturn boolean true if the livery can be shown on this vehicle
local function prepareConfig(vehicleName, vehicleConfig, dcl)
	if type(dcl) ~= "table" or type(dcl.layers) ~= "table" or not isEnabled() then return false end
	if type(vehicleConfig) ~= "table" or type(vehicleConfig.parts) ~= "table" then return false end
	-- simplified vehicles and some mods don't have the dynamic textures skin
	if not FS:fileExists("/vehicles/" .. vehicleName .. "/dynamicDecals/main.jbeam") then return false end
	vehicleConfig.parts.paint_design = vehicleName .. "_skin_dynamicTextures"
	return true
end

--- Removes a remote vehicle's livery, its projection goes back to the pool.
-- @tparam number gameVehicleID
local function removeLivery(gameVehicleID)
	local livery = liveries[gameVehicleID]
	liveries[gameVehicleID] = nil
	if livery and livery.slot then
		releaseSlot(livery)
		priorityTimer = PRIORITY_INTERVAL -- give the free projection to the next nearest vehicle straight away
	end
end

--- Sets the livery of a remote vehicle, it's baked once the vehicle is ready (or straight away with rebake).
-- @tparam number gameVehicleID
-- @tparam table dcl the received livery, nil removes it
-- @tparam boolean rebake bake now, for edits that don't respawn the vehicle (paint only)
local function setLivery(gameVehicleID, dcl, rebake)
	if type(dcl) ~= "table" or type(dcl.layers) ~= "table" or not isEnabled() then
		removeLivery(gameVehicleID)
		return
	end
	local livery = liveries[gameVehicleID] or {}
	livery.dcl = dcl
	liveries[gameVehicleID] = livery
	if rebake then queueBake(gameVehicleID) end
end

--- Called by MPVehicleGE when a vehicle's Lua is ready, after a spawn or a respawn from an edit.
-- @tparam number gameVehicleID
local function onVehicleReady(gameVehicleID)
	if liveries[gameVehicleID] then queueBake(gameVehicleID) end
end

local function bake(gameVehicleID)
	local livery = liveries[gameVehicleID]
	local veh = getObjectByID(gameVehicleID)
	if not livery or not veh then return end
	if not isEnabled() then
		showPaint(gameVehicleID)
		return
	end

	livery.slot = livery.slot or acquireSlot(gameVehicleID)
	if not livery.slot then -- all projections are in use by nearer vehicles
		showPaint(gameVehicleID)
		return
	end

	local slot = livery.slot
	if not bakeOnto(slot.projection, veh, gameVehicleID, withoutMissingFiles(deepcopy(livery.dcl.layers))) then
		releaseSlot(livery)
		showPaint(gameVehicleID)
		return
	end
	veh:setTextureSet("@DynamicTexture", slot.textureSet)
	livery.settle = SETTLE_FRAMES
end

-- the nearest vehicles get the projections, a vehicle further away than all of them gives its one up
local function updatePriority()
	if not isEnabled() then return end
	local camPos = core_camera.getPosition()
	local list = {}
	for gameVehicleID in pairs(liveries) do
		local veh = getObjectByID(gameVehicleID)
		if veh then table.insert(list, { id = gameVehicleID, dist = camPos:squaredDistance(veh:getPosition()) }) end
	end
	table.sort(list, function(a, b) return a.dist < b.dist end)

	for i, entry in ipairs(list) do
		local livery = liveries[entry.id]
		if i > MAX_LIVERIES and livery.slot then
			releaseSlot(livery)
			showPaint(entry.id)
		end
	end
	for i = 1, math.min(#list, MAX_LIVERIES) do
		if not liveries[list[i].id].slot then queueBake(list[i].id) end
	end
end


-- ============= EVENTS =============

local function onUpdate(dtReal)
	priorityTimer = priorityTimer + dtReal
	if priorityTimer >= PRIORITY_INTERVAL then
		priorityTimer = 0
		updatePriority()
	end

	local id = table.remove(bakeQueue, 1)
	if id then bake(id) end

	for gameVehicleID, livery in pairs(liveries) do
		if livery.slot and livery.settle and livery.settle > 0 then
			local veh = getObjectByID(gameVehicleID)
			if veh then
				veh:setTextureSet("@DynamicTexture", livery.slot.textureSet)
				projectAndCombine(livery.slot.projection, livery.slot.textureSet, veh)
			end
			livery.settle = veh and livery.settle - 1 or 0
		end
	end
end

-- turned off they show their paint, the liveries are kept so turning it back on shows them again
local function onSettingsChanged()
	if not isEnabled() then
		for gameVehicleID, livery in pairs(liveries) do
			releaseSlot(livery)
			showPaint(gameVehicleID)
		end
	else
		priorityTimer = PRIORITY_INTERVAL
	end
end

local function onVehicleDestroyed(gameVehicleID)
	removeLivery(gameVehicleID)
end

-- the pool is kept, the projections don't give their memory back when they're freed
local function onBeamMPServerLeave()
	for _, livery in pairs(liveries) do releaseSlot(livery) end
	liveries, bakeQueue = {}, {}
end


M.getOwnLivery    = getOwnLivery
M.prepareConfig   = prepareConfig
M.setLivery       = setLivery
M.removeLivery    = removeLivery
M.onVehicleReady  = onVehicleReady

M.onUpdate            = onUpdate
M.onSettingsChanged   = onSettingsChanged
M.onVehicleDestroyed  = onVehicleDestroyed
M.onBeamMPServerLeave = onBeamMPServerLeave
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
