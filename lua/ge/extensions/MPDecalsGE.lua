-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPDecalsGE API.
--- Syncs liveries made in the game's livery editor. The owner sends the livery's layers (the same json the editor saves
--- in settings/dynamicDecals) with the vehicle data, and everyone else bakes them onto their copy of the vehicle with
--- their own decal projection. Nothing changes on the server, it stores and replays the vehicle data as it is.
--- @module MPDecalsGE

local M = {}

local SAVE_DIR = "/settings/dynamicDecals/"
local MAX_LIVERY_SIZE = 256 * 1024 -- bytes of layer json, bigger liveries aren't sent
local MAX_LIVERIES = 10 -- remote liveries shown at once, each one keeps its own textures
local TEXTURE_SIZE = Point2I(2048, 1024) -- the editor uses 4096x2048, a quarter of the memory looks the same on other players' vehicles
local SETTLE_FRAMES = 3 -- frames of project / combine after a bake, the textures stay after that

local liveries = {} -- [gameVehicleID] = { dcl, projection, textureSet, settle, waiting }
local bakeQueue = {} -- gameVehicleIDs waiting for a bake, one per frame
local loggedMissing = {} -- [path] = true, missing livery files are only logged once


-- ============= HELPERS =============

local function isEnabled()
	return settings.getValue("beammpShowLiveries") ~= false
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

local function liveryCount()
	local n = 0
	for _, livery in pairs(liveries) do
		if livery.projection then n = n + 1 end
	end
	return n
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

local function queueBake(gameVehicleID)
	for _, id in ipairs(bakeQueue) do
		if id == gameVehicleID then return end
	end
	table.insert(bakeQueue, gameVehicleID)
end

--- Removes a remote vehicle's livery and frees its textures.
-- @tparam number gameVehicleID
local function removeLivery(gameVehicleID)
	local livery = liveries[gameVehicleID]
	liveries[gameVehicleID] = nil
	if livery and livery.projection then
		-- a slot is free, the next livery that was waiting for one gets baked
		for id, other in pairs(liveries) do
			if other.waiting then
				other.waiting = false
				queueBake(id)
				break
			end
		end
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

	if not livery.projection then
		if liveryCount() >= MAX_LIVERIES then
			livery.waiting = true
			return
		end
		livery.projection = DecalProjection("", TEXTURE_SIZE, 1, 0)
		livery.textureSet = livery.projection:getTextureSet()
	end

	local projection = livery.projection
	local jbeam = veh:getJBeamFilename()
	placeProjection(projection, veh)
	if not setMaterials(projection, gameVehicleID, jbeam) then
		log('W', 'MPDecalsGE', "No livery material found on " .. jbeam .. ", the livery isn't shown")
		removeLivery(gameVehicleID)
		return
	end

	local layers = deserializeLayers(withoutMissingFiles(deepcopy(livery.dcl.layers)))
	if not layers then return end

	projection:clearBakedTextures()
	local result = projection:bakeLayers(layers, jbeam)
	if result and result.status and result.status.code ~= 0 then
		log('W', 'MPDecalsGE', "Livery '" .. tostring(livery.dcl.name) .. "' baked with status " .. tostring(result.status.code))
	end
	veh:setTextureSet("@DynamicTexture", livery.textureSet)
	livery.settle = SETTLE_FRAMES
end

-- after a bake the textures need projecting and combining for a few frames, after that they stay
local function settle(gameVehicleID, livery)
	local veh = getObjectByID(gameVehicleID)
	if not veh then
		livery.settle = 0
		return
	end
	local projection = livery.projection
	veh:setTextureSet("@DynamicTexture", livery.textureSet)
	placeProjection(projection, veh)
	projection:projectDynamicDecals(veh:getRefNodeMatrix():fullInverse():mul(getCameraTransform()), getCameraProjMatrix())
	projection:combineTextures(livery.textureSet)
	livery.settle = livery.settle - 1
end


-- ============= EVENTS =============

local function onUpdate()
	local id = table.remove(bakeQueue, 1)
	if id then bake(id) end

	for gameVehicleID, livery in pairs(liveries) do
		if livery.projection and livery.settle and livery.settle > 0 then
			settle(gameVehicleID, livery)
		end
	end
end

local function onVehicleDestroyed(gameVehicleID)
	removeLivery(gameVehicleID)
end

local function onBeamMPServerLeave()
	liveries, bakeQueue = {}, {}
end


M.getOwnLivery    = getOwnLivery
M.prepareConfig   = prepareConfig
M.setLivery       = setLivery
M.removeLivery    = removeLivery
M.onVehicleReady  = onVehicleReady

M.onUpdate            = onUpdate
M.onVehicleDestroyed  = onVehicleDestroyed
M.onBeamMPServerLeave = onBeamMPServerLeave
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
