-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPMapPlayersGE API.
--- Other players on the maps. The minimap gets a dot in their role color on their vehicle, so you can tell players
--- from traffic, and on the big map they're in their own Players list with their name, role and distance, and you
--- can set a route to them.
--- @module MPMapPlayersGE

local M = {}

local REFRESH_INTERVAL = 3 -- seconds between big map refreshes while it's open, so the player markers follow them
local USER_COLOR = { r = 79, g = 195, b = 247 } -- normal players, USER role is white on black

local refreshTimer = 0
local dotColors = {} -- [role color key] = ColorI, so we don't make new ones every frame
local outlineColor


-- ============= HELPERS =============

local function inSession()
	return MPCoreNetwork and MPCoreNetwork.isMPSession()
end

local function roleColor(owner, v)
	local roleInfo = (v and v.customRole) or owner.customRole or owner.role
	local c = roleInfo and roleInfo.forecolor
	if not c or (c.r == 255 and c.g == 255 and c.b == 255) then c = USER_COLOR end
	local key = c.r * 65536 + c.g * 256 + c.b
	local col = dotColors[key]
	if not col then
		col = color(c.r, c.g, c.b, 255)
		dotColors[key] = col
	end
	return col
end

local function distanceText(d)
	if settings.getValue("uiUnitLength") == "imperial" then
		local ft = d * 3.28084
		if ft >= 5280 then return string.format("%.1f mi", ft / 5280) end
		return string.format("%d ft", math.floor(ft / 10 + 0.5) * 10)
	end
	if d >= 1000 then return string.format("%.1f km", d / 1000) end
	return string.format("%d m", math.floor(d / 10 + 0.5) * 10)
end

local vehPos = vec3()

-- remote vehicles that are spawned, calls fn(serverVehicleID, v, owner, pos). Not blocked players, and a culled
-- (deactivated) vehicle doesn't move, so its position comes from the network like its nametag
local function forEachRemote(fn)
	local anyBlocked = UI and UI.hasBlocked()
	for serverVehicleID, v in pairs(MPVehicleGE.getVehicles()) do
		if not v.isLocal and v.isSpawned and v.gameVehicleID then
			local owner = v:getOwner()
			local veh = owner and getObjectByID(v.gameVehicleID)
			if veh and not (anyBlocked and UI.isBlocked(owner.name)) then
				if veh:getActive() then vehPos:set(veh:getPositionXYZ()) else vehPos:set(v.position) end
				fn(serverVehicleID, v, owner, vehPos)
			end
		end
	end
end


-- ============= MINIMAP =============

local DOT_LAYER = 95 -- above the other vehicle arrows (70 - 90) and under our own (100), see ui/apps/minimap/layers
local DOT_RADIUS = 4
local DOT_OUTLINE = 1.5

local drawTd
local dotPos = vec3()

local function drawDot(serverVehicleID, v, owner, pos)
	local dpi = ui_apps_minimap_utils.dpi
	local col = roleColor(owner, v)
	dotPos:set(pos)
	ui_apps_minimap_utils.worldToMapXYZ(dotPos, dotPos)
	drawTd:circle(dotPos.x, dotPos.y, DOT_RADIUS * dpi, DOT_OUTLINE * dpi, col, col, outlineColor, outlineColor, 0, DOT_LAYER)
end

--- Draws a role color dot on every other player's minimap marker. Called by the minimap every frame.
-- @tparam userdata td the minimap's texture draw
local function onDrawOnMinimap(td)
	if not inSession() or not ui_apps_minimap_utils then return end
	outlineColor = outlineColor or color(16, 20, 28, 220)
	drawTd = td
	forEachRemote(drawDot)
	drawTd = nil
end


-- ============= BIG MAP =============

local GROUP_KEY = "beammpPlayers"

--- Adds other players to the big map, called by the game when it builds the big map POI list.
-- @tparam string levelIdentifier
-- @tparam table elements the POI list to add to
local function onGetRawPoiListForLevel(levelIdentifier, elements)
	if not inSession() then return end
	local me = getPlayerVehicle(0)
	local from = me and me:getPosition() or core_camera.getPosition()
	forEachRemote(function(serverVehicleID, v, owner, vehPos)
		local pos = vec3(vehPos) -- kept by the POI
		local role = v.nameTagRole or ""
		local dist = distanceText(pos:distance(from))
		local id = "beammpPlayer" .. serverVehicleID
		table.insert(elements, {
			id = id,
			data = { type = "playerVehicle", id = id, customGroupTags = { GROUP_KEY } },
			markerInfo = {
				bigmapMarker = {
					pos = pos,
					icon = "vehicle_marker_outlined",
					name = v.nameTagName or owner.name,
					description = role ~= "" and (role .. "  ·  " .. dist) or dist,
					cluster = false,
				}
			}
		})
	end)
end

--- Adds the Players group to the big map list.
-- @tparam table groupData
local function onBigmapBuildGroupData(groupData)
	if not inSession() then return end
	groupData[GROUP_KEY] = { label = "Players", icon = "carStarred" }
end

--- Adds the Players section to the big map filters, the game only shows player vehicles in career otherwise.
-- @tparam table groupStructures
local function onBigmapBuildCustomGroupStructures(groupStructures)
	if not inSession() then return end
	table.insert(groupStructures, { key = GROUP_KEY, icon = "carStarred", title = "Players", groupIds = { GROUP_KEY } })
end

--- Rebuilds the big map players now if it's open, eg after someone was blocked.
local function refresh()
	if freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() then refreshTimer = REFRESH_INTERVAL end
end

local function onUpdate(dtReal)
	if not (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) or not inSession() then
		refreshTimer = 0
		return
	end
	-- players move, so every few seconds get new POI positions while the big map is open. The markers keep their
	-- first position, so they're rebuilt too, at full alpha so nothing fades
	refreshTimer = refreshTimer + dtReal
	if refreshTimer >= REFRESH_INTERVAL then
		refreshTimer = 0
		if gameplay_rawPois and freeroam_bigMapMarkers then
			gameplay_rawPois.clear()
			freeroam_bigMapMarkers.clearMarkers()
			freeroam_bigMapMarkers.setNextMarkersFullAlphaInstant()
		end
	end
end


M.refresh                            = refresh
M.onDrawOnMinimap                    = onDrawOnMinimap
M.onGetRawPoiListForLevel            = onGetRawPoiListForLevel
M.onBigmapBuildGroupData             = onBigmapBuildGroupData
M.onBigmapBuildCustomGroupStructures = onBigmapBuildCustomGroupStructures
M.onUpdate                           = onUpdate
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
