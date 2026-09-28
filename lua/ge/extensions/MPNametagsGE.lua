-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPNametagsGE API.
--- Modern nametags (opt in). Drawn with the game's world billboards + Skia templates, the same as license plates.
--- Card up close (role color, name, role and distance, spectators), pill far away, icons for typing / away / lagging.
--- MPVehicleGE still decides who gets a nametag and calls draw(), so all the nametag settings keep working.
--- Skia renders are ~1ms so they're queued one per frame, and billboards are only destroyed a second after hiding them.
--- @module MPNametagsGE

local M = {}

local FAR_DISTANCE = 150         -- meters, card below this, pill above
local HIDE_DISTANCE_BELOW = 10   -- no distance text this close, same as the classic tags
local STALE_AFTER = 5            -- seconds a tag can go undrawn before its billboards are destroyed
local DESTROY_DELAY = 60         -- frames between hiding a billboard and destroying it
local REBUILD_INTERVAL = 2       -- seconds, a tag's card / pill is rebuilt at most this often
local LAG_NO_DATA = 1.5          -- seconds without a position update before a player shows as lagging
local LAG_RECOVER = 2            -- seconds of steady data before the lag icon goes again
local LAG_PING, LAG_PING_OK = 400, 300 -- ms
local OCCLUSION_INTERVAL = 0.25  -- seconds between line of sight checks per tag
local HEIGHT_OFFSET = 0.35       -- meters between the vehicle nametag position and the bottom of the tag
local BIG_MAP_LIFT = 0.3         -- fraction of the way to the camera big map tags are moved, so they're out of the ground

-- size on screen in pixels, so tags stay the same size like the classic ones
local CARD_PX, PILL_PX, ICON_PX = 34, 22, 15
local CARD_MIN, PILL_MIN, ICON_MIN = 0.15, 0.12, 0.08 -- meters, so they don't get tiny when you're right next to someone
local STACK_GAP = 0.1 -- fraction of a tag's height between stacked tags

local CARD_W, CARD_H, CARD_SLIM_H, CARD_SPEC_H = 512, 168, 96, 220
local PILL_W, PILL_H = 640, 110
local ICON_W = 100
local BG_COLOR = "#10141ccc"
local TEXT_COLOR = "#ffffff"
local MUTED_COLOR = "#aeb8d0"
local LAG_COLOR = "#f0a940"
local USER_ACCENT = "#4fc3f7" -- normal players (USER role is white on black, which doesn't work as an accent)

local renderer
local rendererMissing = false
local warmedUp = false
local enabled = false
local hideBehindObjects = false
local tags = {}           -- [serverVehicleID] = tag
local queue, queued = {}, {} -- billboard work, one job per frame
local pendingDestroy = {} -- { id, frame } hidden billboards waiting to be destroyed
local frame = 0
local clockNow = 0
local pxToWorld = 0.0013 -- world meters per pixel per meter of distance, from the fov and resolution
local scale = 1 -- "Modern nametag size" setting
local screenTimer = 0
local bigMap = false -- big map open, tags face the screen and go under the players' markers

local camPos, camForward, camRight, camUp, up, xAxis = vec3(), vec3(), vec3(), vec3(), vec3(0, 0, 1), vec3(1, 0, 0)
local camQuat = quat()
local placed, placedCount = {}, 0 -- tags already placed this frame, in camera space, for stacking
local tagPos, iconPos, rayDir, offset = vec3(), vec3(), vec3(), vec3()


-- ============= TEMPLATES =============

local function hex(c)
	return string.format("#%02x%02x%02x", c.r, c.g, c.b)
end

local function accentFor(roleInfo)
	local c = roleInfo and roleInfo.forecolor
	if not c or (c.r == 255 and c.g == 255 and c.b == 255) then return USER_ACCENT end
	return hex(c)
end

-- name and colors are baked in (Skia can't take colors as vars), the text that changes (distance, spectators) is a var
local function cardTemplate(name, accent, hasSub, hasSpectators)
	local lines = {
		{ type = "text", text = name, fontSize = 58, color = TEXT_COLOR, fit = "shrink", textAlign = "left", style = { width = "100%", height = 66 } },
	}
	if hasSub then
		lines[#lines + 1] = { type = "text", text = "{sub}", fontSize = 46, color = accent, fit = "shrink", textAlign = "left", style = { width = "100%", height = 54 } }
	end
	if hasSpectators then
		lines[#lines + 1] = { type = "text", text = "{spec}", fontSize = 40, color = MUTED_COLOR, fit = "shrink", textAlign = "left", style = { width = "100%", height = 46 } }
	end
	local height = CARD_SLIM_H + (hasSub and (CARD_H - CARD_SLIM_H) or 0) + (hasSpectators and (CARD_SPEC_H - CARD_H) or 0)
	return {
		size = { CARD_W, height },
		vars = { sub = { type = "string", default = "" }, spec = { type = "string", default = "" } },
		root = { children = {
			{ type = "box", radius = 22, color = BG_COLOR, style = { position = "absolute", left = 0, top = 0, right = 0, bottom = 0 } },
			{ type = "group", style = { flexDirection = "row", alignItems = "center", width = "100%", height = "100%", paddingRight = 26, gap = 18 }, children = {
				{ type = "box", radius = 6, color = accent, style = { width = 12, height = "100%" } },
				{ type = "group", style = { flexDirection = "column", justifyContent = "center", flexGrow = 1, gap = 6 }, children = lines },
			} },
		} },
	}, height
end

local function pillTemplate(name, accent, hasDist)
	local row = {
		{ type = "box", radius = "50%", color = accent, style = { width = 30, height = 30 } },
		{ type = "text", text = name, fontSize = 66, color = TEXT_COLOR, fit = "shrink", style = { height = 76, flexShrink = 1 } },
	}
	if hasDist then row[#row + 1] = { type = "text", text = "{dist}", fontSize = 44, color = MUTED_COLOR, fit = "shrink", style = { height = 52 } } end
	return {
		size = { PILL_W, PILL_H },
		vars = { dist = { type = "string", default = "" } },
		root = { children = {
			{ type = "box", radius = PILL_H / 2, color = BG_COLOR, style = { position = "absolute", left = 0, top = 0, right = 0, bottom = 0 } },
			{ type = "group", style = { flexDirection = "row", alignItems = "center", justifyContent = "center", width = "100%", height = "100%", paddingLeft = 34, paddingRight = 34, gap = 20 }, children = row },
		} },
	}
end

local function iconTemplate(bg, children)
	return {
		size = { ICON_W, ICON_W },
		root = { children = {
			{ type = "box", radius = "50%", color = bg, style = { position = "absolute", left = 0, top = 0, right = 0, bottom = 0 } },
			{ type = "group", style = { flexDirection = "row", alignItems = "center", justifyContent = "center", width = "100%", height = "100%", gap = 8 }, children = children },
		} },
	}
end

local ICONS = {
	typing = iconTemplate("#ffffffee", {
		{ type = "box", radius = "50%", color = "#1b1f2a", style = { width = 16, height = 16 } },
		{ type = "box", radius = "50%", color = "#1b1f2a", style = { width = 16, height = 16 } },
		{ type = "box", radius = "50%", color = "#1b1f2a", style = { width = 16, height = 16 } },
	}),
	lag = iconTemplate(BG_COLOR, { -- signal bars, the tallest one missing
		{ type = "group", style = { flexDirection = "row", alignItems = "flex-end", gap = 6, height = 48 }, children = {
			{ type = "box", radius = 3, color = LAG_COLOR, style = { width = 12, height = 18 } },
			{ type = "box", radius = 3, color = LAG_COLOR, style = { width = 12, height = 32 } },
			{ type = "box", radius = 3, color = LAG_COLOR .. "40", style = { width = 12, height = 48 } },
		} },
	}),
	away = iconTemplate(BG_COLOR, { -- moon
		{ type = "path", path = "M12 3a9 9 0 1 0 9 9 7 7 0 1 1-9-9z", color = MUTED_COLOR, style = { width = 56, height = 56 } },
	}),
}
local ICON_ORDER = { "typing", "away", "lag" }


-- ============= BILLBOARDS =============

local function ensureRenderer()
	if renderer then return renderer end
	if rendererMissing then return nil end
	if not WorldBillboardRenderer then
		rendererMissing = true -- older game version, classic tags it is
		log('W', 'MPNametagsGE', 'WorldBillboardRenderer not available, using classic nametags')
		return nil
	end
	if not (scenetree and scenetree.MissionGroup) then return nil end -- no level loaded yet, try again later
	local r = scenetree.beammpNameTags
	if not r then
		r = WorldBillboardRenderer()
		r:registerObject("beammpNameTags")
		scenetree.MissionGroup:addObject(r)
	end
	renderer = r
	return r
end

local function hide(id)
	if id then renderer:update(id, camPos, 0, false) end
end

-- hidden now, destroyed a second later so the renderer is never handed an id it's still using this frame
local function release(id)
	if not id or not renderer then return end
	hide(id)
	pendingDestroy[#pendingDestroy + 1] = { id = id, frame = frame + DESTROY_DELAY }
end

local function destroyTag(key)
	local t = tags[key]
	if not t then return end
	t.dead = true
	release(t.card)
	release(t.pill)
	for _, name in ipairs(ICON_ORDER) do release(t.icons[name]) end
	tags[key] = nil
end

-- released, onPreRender destroys them later (it keeps doing that even when turned off)
local function destroyAll()
	for key in pairs(tags) do destroyTag(key) end
	queue, queued = {}, {}
end

-- the first Skia render loads fonts and takes a few hundred ms, do it once when the style gets turned on
local function warmUp()
	if warmedUp or not ensureRenderer() then return end
	warmedUp = true
	local id = renderer:create(jsonEncode((cardTemplate("BeamMP", USER_ACCENT, true, true))), true)
	if id and id ~= 0 then
		renderer:render(id, jsonEncode({ sub = "0 m", spec = "" }))
		release(id)
	end
end

local function schedule(t)
	if queued[t] then return end
	queued[t] = true
	queue[#queue + 1] = t
end

local function needsWork(t)
	if t.wantCardKey ~= t.cardKey or t.wantPillKey ~= t.pillKey then return true end
	if t.card and t.cardVars ~= t.wantCardVars then return true end
	if t.pill and t.pillVars ~= t.wantPillVars then return true end
	for name, want in pairs(t.wantIcons) do if want and not t.icons[name] then return true end end
	return false
end

-- does the next job for a tag (create or render one billboard) and requeues it if there is more
local function process(t)
	queued[t] = nil
	if not renderer or t.dead then return end
	local rebuildOk = clockNow - (t.lastRebuild or -math.huge) >= REBUILD_INTERVAL
	if t.wantCardKey ~= t.cardKey and (not t.card or rebuildOk) then
		release(t.card)
		t.card = renderer:create(jsonEncode(t.wantCardTemplate), true)
		t.cardKey, t.cardHeight, t.cardVars, t.screenFacing = t.wantCardKey, t.wantCardHeight, nil, nil
		if t.cardKey then t.lastRebuild = clockNow end
	elseif t.card and t.cardVars ~= t.wantCardVars then
		renderer:render(t.card, jsonEncode({ sub = t.wantSub or "", spec = t.wantSpec or "" }))
		t.cardVars = t.wantCardVars
	elseif t.wantPillKey ~= t.pillKey and (not t.pill or rebuildOk) then
		release(t.pill)
		t.pill = renderer:create(jsonEncode(t.wantPillTemplate), true)
		t.pillKey, t.pillVars, t.screenFacing = t.wantPillKey, nil, nil
		t.lastRebuild = clockNow
	elseif t.pill and t.pillVars ~= t.wantPillVars then
		renderer:render(t.pill, jsonEncode({ dist = t.wantDist or "" }))
		t.pillVars = t.wantPillVars
	else
		for _, name in ipairs(ICON_ORDER) do
			if t.wantIcons[name] and not t.icons[name] then
				local id = renderer:create(jsonEncode(ICONS[name]), false)
				if id and id ~= 0 then renderer:render(id, "{}") end
				t.icons[name] = id
				t.screenFacing = nil
				break
			end
		end
	end
	if needsWork(t) then schedule(t) end
end


-- ============= HELPERS =============

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- rounded so the text only changes (and the billboard only re-renders) every so often
local function distanceText(d)
	if d <= HIDE_DISTANCE_BELOW or not settings.getValue("nameTagShowDistance") then return "" end
	if settings.getValue("uiUnitLength") == "imperial" then
		local ft = d * 3.28084
		if ft >= 5280 then return string.format("%.1f mi", math.floor(ft / 528 + 0.5) / 10) end
		return string.format("%d ft", math.floor(ft / 50 + 0.5) * 50)
	end
	if d >= 1000 then return string.format("%.1f km", math.floor(d / 100 + 0.5) / 10) end
	return string.format("%d m", math.floor(d / 10 + 0.5) * 10)
end

-- world size for a tag that should be `px` pixels tall on screen at distance d
local function worldSize(d, px, minimum)
	return math.max(minimum * scale, d * px * scale * pxToWorld)
end

local function refreshScreen()
	local fov = core_camera.getFovRad and core_camera.getFovRad() or math.rad(65)
	local vm = GFXDevice and GFXDevice.getVideoMode and GFXDevice.getVideoMode()
	local height = (vm and vm.height and vm.height > 0) and vm.height or 1080
	pxToWorld = 2 * math.tan(fov * 0.5) / height
end


-- ============= PUBLIC =============

--- Returns if modern nametags are on and can be drawn.
-- @treturn boolean
local function isActive()
	return enabled and ensureRenderer() ~= nil
end

--- Draws the modern nametag for a vehicle this frame. Called by MPVehicleGE for every vehicle that gets a nametag.
-- @tparam string serverVehicleID
-- @tparam table v the MPVehicleGE vehicle
-- @tparam table owner the owning player
-- @tparam vec3 pos nametag position (top of the vehicle)
-- @tparam number distance distance for the text (from your vehicle, same as the classic tags)
-- @tparam number alpha nametag alpha from the fade settings
-- @tparam table roleInfo
-- @treturn boolean false if MPVehicleGE should draw the classic tag this frame (not ready yet, or out of sight)
local function draw(serverVehicleID, v, owner, pos, distance, alpha, roleInfo)
	local t = tags[serverVehicleID]
	if not t then
		t = { icons = {}, wantIcons = {}, lastPosTim = v.lastDt, lastPosAt = clockNow, dataSince = clockNow, lagging = false,
			occluded = false, occlusionTimer = math.random() * OCCLUSION_INTERVAL }
		tags[serverVehicleID] = t
	end
	t.drawnFrame, t.lastSeen = frame, clockNow

	-- faded out
	if alpha < 0.1 then return true end

	-- lagging, with a bit of hysteresis so the icon doesn't flicker when position packets come in bursts
	if v.lastDt ~= t.lastPosTim then
		if clockNow - t.lastPosAt > LAG_NO_DATA then t.dataSince = clockNow end -- data again after a gap
		t.lastPosTim, t.lastPosAt = v.lastDt, clockNow
	end
	local ping = owner.ping or 0
	if t.lagging then
		if clockNow - t.lastPosAt < LAG_NO_DATA and clockNow - t.dataSince > LAG_RECOVER and ping < LAG_PING_OK then t.lagging = false end
	elseif clockNow - t.lastPosAt > LAG_NO_DATA or ping > LAG_PING then
		t.lagging = true
	end
	local wantIcons = t.wantIcons
	wantIcons.typing = MPPlayerStatusGE and MPPlayerStatusGE.isTyping(v.ownerID) or false
	wantIcons.away = MPPlayerStatusGE and MPPlayerStatusGE.isAway(v.ownerID) or false
	wantIcons.lag = t.lagging

	-- what the tag should say
	local name = v.nameTagName or trim(v.nameTag)
	local accent = accentFor(roleInfo)
	local spec = ""
	if settings.getValue("showSpectators") and v.spectatorsTag ~= "" then spec = trim(v.spectatorsTag) end
	local distText = distanceText(distance)
	local role = v.nameTagRole or ""
	local sub = role ~= "" and distText ~= "" and (role .. "  ·  " .. distText) or (role ~= "" and role or distText)
	-- size and card / pill go by the camera distance, the orbit / spectate camera can be a long way from your vehicle
	rayDir:set(pos)
	rayDir:setSub(camPos)
	local camDistance = rayDir:length()
	local far = bigMap or camDistance > FAR_DISTANCE

	local cardKey = name .. "|" .. accent .. "|" .. tostring(sub ~= "") .. tostring(spec ~= "")
	local pillKey = name .. "|" .. accent .. "|" .. tostring(distText ~= "")
	if cardKey ~= t.wantCardKey then t.wantCardKey, t.wantCardTemplate, t.wantCardHeight = cardKey, cardTemplate(name, accent, sub ~= "", spec ~= "") end
	if pillKey ~= t.wantPillKey then t.wantPillKey, t.wantPillTemplate = pillKey, pillTemplate(name, accent, distText ~= "") end
	-- only the style on screen keeps its text up to date, the other one catches up when it's switched to
	if far then
		t.wantPillVars, t.wantDist = distText, distText
	else
		t.wantCardVars, t.wantSub, t.wantSpec = sub .. "|" .. spec, sub, spec
	end
	if needsWork(t) then schedule(t) end

	-- line of sight, only needed when nametags should show through objects
	if not hideBehindObjects and not bigMap then
		t.occlusionTimer = t.occlusionTimer - (t.dt or 0)
		if t.occlusionTimer <= 0 then
			t.occlusionTimer = OCCLUSION_INTERVAL
			t.occluded = camDistance > 2 and castRayStatic(camPos, rayDir, camDistance) < camDistance - 1
		end
	else
		t.occluded = false
	end

	local showId = far and t.pill or t.card
	if t.occluded or not showId then
		hide(t.card) hide(t.pill)
		for _, n in ipairs(ICON_ORDER) do hide(t.icons[n]) end
		return false -- classic tag this frame
	end

	-- tag
	local height, width
	if far then
		height = worldSize(camDistance, PILL_PX, PILL_MIN)
		width = height * PILL_W / PILL_H
	else
		height = worldSize(camDistance, CARD_PX, CARD_MIN) * (t.cardHeight or CARD_H) / CARD_H
		width = height * CARD_W / (t.cardHeight or CARD_H)
	end
	tagPos:set(pos)
	local sizeScale = 1
	if bigMap then
		-- the big map camera is high up and billboards hide behind the ground, so move it along the line to the camera,
		-- same place on screen but out of the terrain, and smaller by as much so it's still the same size on screen
		sizeScale = 1 - BIG_MAP_LIFT
		height, width = height * sizeScale, width * sizeScale
		offset:set(camPos)
		offset:setSub(pos)
		offset:setScaled(BIG_MAP_LIFT)
		tagPos:setAdd(offset)
		-- then just under the vehicle on screen, the big map marker is above it
		offset:set(camUp)
		offset:setScaled(-height)
		tagPos:setAdd(offset)
	else
		tagPos.z = tagPos.z + HEIGHT_OFFSET + height * 0.5
	end

	-- stacking: push this tag up above any tag it overlaps on screen that was already placed this frame
	offset:set(tagPos)
	offset:setSub(camPos)
	local depth = offset:dot(camForward)
	if depth > 0.1 then
		local sx, sy = offset:dot(camRight) / depth, offset:dot(camUp) / depth
		local hw, hh = width * 0.5 / depth, height * 0.5 / depth
		local moved = 0
		for _ = 1, 3 do -- a few passes, pushing it up can make it overlap the next one
			local bumped = false
			for i = 1, placedCount do
				local o = placed[i]
				if math.abs(sx - o.x) < hw + o.hw and math.abs(sy - o.y) < hh + o.hh then
					local newY = o.y + o.hh + hh * (1 + STACK_GAP * 2)
					if newY > sy then moved, sy, bumped = moved + (newY - sy), newY, true end
				end
			end
			if not bumped then break end
		end
		if moved > 0 then
			offset:set(camUp)
			offset:setScaled(moved * depth)
			tagPos:setAdd(offset)
		end
		placedCount = placedCount + 1
		local o = placed[placedCount]
		if not o then o = {} placed[placedCount] = o end
		o.x, o.y, o.hw, o.hh = sx, sy, hw, hh
	end
	-- upright in the world normally, facing the screen on the big map so they don't lie flat
	if t.screenFacing ~= bigMap then
		t.screenFacing = bigMap
		if t.card then renderer:setScreenFacing(t.card, bigMap) end
		if t.pill then renderer:setScreenFacing(t.pill, bigMap) end
		for _, id in pairs(t.icons) do renderer:setScreenFacing(id, bigMap) end
	end
	renderer:update(showId, tagPos, height, true)
	hide(far and t.card or t.pill)

	-- icons in a row to the right of the tag
	local iconSize = worldSize(camDistance, ICON_PX, ICON_MIN) * sizeScale
	local x = width * 0.5 + iconSize * 0.7
	for _, n in ipairs(ICON_ORDER) do
		local id = t.icons[n]
		if id then
			if wantIcons[n] then
				offset:set(camRight)
				offset:setScaled(x)
				iconPos:set(tagPos)
				iconPos:setAdd(offset)
				renderer:update(id, iconPos, iconSize, true)
				x = x + iconSize * 1.15
			else
				hide(id)
			end
		end
	end
	return true
end


-- ============= EVENTS =============

local function refreshSettings()
	local wasEnabled = enabled
	enabled = settings.getValue("useModernNametags") and true or false
	hideBehindObjects = settings.getValue("nameTagsHideBehindObjects") and true or false
	scale = math.max(0.5, math.min(2, (tonumber(settings.getValue("modernNametagScale")) or 100) / 100))
	if wasEnabled and not enabled then
		destroyAll()
	elseif enabled then
		-- names, units, shortened names etc. might have changed, rebuild what's needed
		for _, t in pairs(tags) do t.wantCardKey, t.wantPillKey = nil, nil end
	end
end

local function processDestroys()
	local i = 1
	while i <= #pendingDestroy do
		local p = pendingDestroy[i]
		if p.frame <= frame then
			pcall(function() renderer:destroy(p.id) end)
			table.remove(pendingDestroy, i)
		else
			i = i + 1
		end
	end
end

local function onPreRender(dt)
	if not enabled then
		if renderer and pendingDestroy[1] then -- switched off: still finish destroying what it had
			frame = frame + 1
			processDestroys()
		end
		return
	end
	if not renderer and not ensureRenderer() then return end
	if not warmedUp then warmUp() end
	frame = frame + 1
	clockNow = clockNow + dt
	camPos:set(core_camera.getPositionXYZ())
	-- from the camera rotation, crossing forward with world up breaks when looking straight down on the big map
	camQuat:set(core_camera.getQuatXYZW())
	camForward:set(core_camera.getForwardXYZ())
	camRight:setRotate(camQuat, xAxis)
	camUp:setRotate(camQuat, up)
	bigMap = freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive() or false
	placedCount = 0
	screenTimer = screenTimer - dt
	if screenTimer <= 0 then
		screenTimer = 1
		refreshScreen()
	end

	-- destroy billboards that were hidden a while ago
	processDestroys()

	-- tags MPVehicleGE didn't draw last frame (hidden, out of range, deleted): hide, and destroy after a while
	for key, t in pairs(tags) do
		t.dt = dt
		if t.drawnFrame and t.drawnFrame < frame - 1 then
			hide(t.card) hide(t.pill)
			for _, n in ipairs(ICON_ORDER) do hide(t.icons[n]) end
			if clockNow - t.lastSeen > STALE_AFTER then destroyTag(key) end
		end
	end

	-- one billboard job per frame
	local t = table.remove(queue, 1)
	if t then process(t) end
end

local function onSettingsChanged()
	refreshSettings()
end

local function onExtensionLoaded()
	refreshSettings()
end

local function onDisconnect()
	destroyAll()
end

local function onClientEndMission()
	-- the renderer and every billboard go with the mission, so just forget about them
	tags, queue, queued, pendingDestroy = {}, {}, {}, {}
	renderer = nil
	warmedUp = false
end

-- nothing will run the delayed destroys after this, so everything goes now
local function onExtensionUnloaded()
	destroyAll()
	if renderer then
		for _, p in ipairs(pendingDestroy) do pcall(function() renderer:destroy(p.id) end) end
	end
	pendingDestroy = {}
end


M.isActive            = isActive
M.draw                = draw

M.onPreRender         = onPreRender
M.onSettingsChanged   = onSettingsChanged
M.onExtensionLoaded   = onExtensionLoaded
M.onDisconnect        = onDisconnect
M.onClientEndMission  = onClientEndMission
M.onExtensionUnloaded = onExtensionUnloaded
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
