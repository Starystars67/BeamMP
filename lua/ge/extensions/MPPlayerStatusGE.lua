-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPPlayerStatusGE API.
--- Player status shared with everyone on the server: typing in chat, and away (game not focused). Also whether a player
--- is lagging (late position data or high ping), worked out here so the nametags and the player list agree.
--- Sent as an extra electrics value ("beammp_status") on one of our vehicles. Servers already pass electrics on as they
--- are, so it works on every server without an update or plugin, and older clients just ignore it.
--- @module MPPlayerStatusGE
--- @usage MPPlayerStatusGE.isTyping(playerID) -- true while that player is typing in chat

local M = {}

-- status bits, more can be added later (AFK, in menu...) without changing the packet
local STATUS_TYPING = 1
local STATUS_AWAY = 2

local RESEND_INTERVAL = 2 -- seconds between resends while a status is set, so players that join late or missed a packet catch up
local REMOTE_TIMEOUT = 5  -- seconds without hearing from a player before their status is cleared (lost "stopped typing", left etc)
local AWAY_AFTER = 10     -- seconds with the game window unfocused (alt tabbed) before we show as away
local LAG_NO_DATA = 1.5   -- seconds without a position update before a player shows as lagging
local LAG_RECOVER = 2     -- seconds of steady data before they stop showing as lagging
local LAG_PING, LAG_PING_OK = 400, 300 -- ms

local localStatus = 0
local sentStatus = 0
local typingCef, typingImgui = false, false -- each chat window reports on its own so they can't overwrite each other
local imguiTypingAge = 0 -- the imgui chat reports every frame it's drawn, if it stops (window closed) typing ends
local unfocusedFor = 0
local focusTimer = 0
local resendTimer = 0
local remoteStatus = {} -- [playerID] = { status = bits, age = seconds since last heard }
local lag = {} -- [playerID] = { posTim, posAt, dataSince, lagging }
local clockNow = 0


-- ============= SENDING =============

-- one vehicle is enough, the status belongs to the player not the vehicle
local function getOwnServerVehicleID()
	local ownID = MPConfig.getPlayerServerID()
	if not ownID then return end
	for serverVehicleID, _ in pairs(MPVehicleGE.getPlayerVehicleObjects(ownID)) do
		return serverVehicleID
	end
end

local function sendStatus()
	if not MPGameNetwork.launcherConnected() then return end
	local serverVehicleID = getOwnServerVehicleID()
	if not serverVehicleID then return end -- no vehicle, so nothing to show a status above anyway
	MPGameNetwork.send(MPNetworkHelpers.generatePacketBuffer('We', serverVehicleID, '{"beammp_status":' .. localStatus .. '}'))
	sentStatus = localStatus
	resendTimer = 0
end

local function setStatusBit(flag, on)
	local status = on and bit.bor(localStatus, flag) or bit.band(localStatus, bit.bnot(flag))
	if status == localStatus then return end
	localStatus = status
	sendStatus()
end

local function updateTyping()
	setStatusBit(STATUS_TYPING, typingCef or typingImgui)
end

--- Sets whether we're typing in the CEF chat, called by the chat apps when it changes and when a message is sent.
-- @tparam boolean typing
local function setTyping(typing)
	typingCef = typing and true or false
	if not typingCef then typingImgui = false end -- a sent message ends typing in both
	updateTyping()
end

--- Same for the imgui chat, called every frame the chat input is drawn.
-- @tparam boolean typing
local function setTypingImgui(typing)
	typingImgui = typing and true or false
	imguiTypingAge = 0
	updateTyping()
end


-- ============= RECEIVING =============

--- Takes the status out of a received electrics packet. Called by MPElectricsGE.
-- @tparam string serverVehicleID
-- @tparam string data the electrics json
-- @treturn boolean true if the packet was only a status, so it doesn't need to go to the vehicle
local function handle(serverVehicleID, data)
	local status = tonumber(data:match('"beammp_status":(%d+)'))
	local playerID = tonumber(serverVehicleID:match("^(%d+)"))
	if not status or not playerID then return false end
	if status == 0 then
		remoteStatus[playerID] = nil
	else
		local s = remoteStatus[playerID]
		if not s then
			s = {}
			remoteStatus[playerID] = s
		end
		s.status, s.age = status, 0
	end
	return data:match('^{"beammp_status":%d+}$') ~= nil
end

--- Returns if a player is away (their game has been out of focus for a while).
-- @tparam number playerID
-- @treturn boolean
local function isAway(playerID)
	local s = remoteStatus[playerID]
	return s ~= nil and bit.band(s.status, STATUS_AWAY) ~= 0
end

--- Returns if a player is typing in chat.
-- @tparam number playerID
-- @treturn boolean
local function isTyping(playerID)
	local s = remoteStatus[playerID]
	return s ~= nil and bit.band(s.status, STATUS_TYPING) ~= 0
end

--- Returns if a player is lagging: no position data for a while, or a high ping. With a bit of hysteresis so it
--- doesn't flicker when position packets come in bursts.
-- @tparam number playerID
-- @treturn boolean
local function isLagging(playerID)
	local l = lag[playerID]
	return l ~= nil and l.lagging
end

-- the newest position packet time from any of their spawned vehicles, nil if they have none
local function lastPositionTime(player)
	local tim
	for serverVehicleID in pairs(player.vehicles and player.vehicles.IDs or {}) do
		local v = MPVehicleGE.getVehicleByServerID(serverVehicleID)
		if v and v.isSpawned and v.lastDt and (not tim or v.lastDt > tim) then tim = v.lastDt end
	end
	return tim
end

local function updateLag(dt)
	clockNow = clockNow + dt
	local players = MPVehicleGE and MPVehicleGE.getPlayers() or {}
	for playerID, player in pairs(players) do
		if not player.isLocal then
			local l = lag[playerID]
			if not l then
				l = { posAt = clockNow, dataSince = clockNow, lagging = false }
				lag[playerID] = l
			end
			local tim = lastPositionTime(player)
			if not tim then
				l.posAt = clockNow -- nothing spawned, so only the ping counts
			elseif tim ~= l.posTim then
				if clockNow - l.posAt > LAG_NO_DATA then l.dataSince = clockNow end -- data again after a gap
				l.posTim, l.posAt = tim, clockNow
			end
			local ping = player.ping or 0
			if l.lagging then
				if clockNow - l.posAt < LAG_NO_DATA and clockNow - l.dataSince > LAG_RECOVER and ping < LAG_PING_OK then l.lagging = false end
			elseif clockNow - l.posAt > LAG_NO_DATA or ping > LAG_PING then
				l.lagging = true
			end
		end
	end
	for playerID in pairs(lag) do
		if not players[playerID] then lag[playerID] = nil end
	end
end


-- ============= EVENTS =============

local function onUpdate(dt)
	focusTimer = focusTimer + dt
	if focusTimer >= 1 then -- once a second is plenty
		if Engine and Engine.isProgramFocused and not Engine.isProgramFocused() then unfocusedFor = unfocusedFor + focusTimer else unfocusedFor = 0 end
		focusTimer = 0
		setStatusBit(STATUS_AWAY, unfocusedFor >= AWAY_AFTER)
	end
	if typingImgui then
		imguiTypingAge = imguiTypingAge + dt
		if imguiTypingAge > 0.5 then -- imgui chat stopped drawing while we were typing
			typingImgui = false
			updateTyping()
		end
	end
	if localStatus ~= 0 then
		resendTimer = resendTimer + dt
		if resendTimer >= RESEND_INTERVAL or sentStatus ~= localStatus then sendStatus() end
	end
	for playerID, s in pairs(remoteStatus) do
		s.age = s.age + dt
		if s.age > REMOTE_TIMEOUT then remoteStatus[playerID] = nil end
	end
	updateLag(dt)
end

local function onDisconnect()
	localStatus, sentStatus, resendTimer = 0, 0, 0
	typingCef, typingImgui = false, false
	unfocusedFor, focusTimer = 0, 0
	remoteStatus, lag = {}, {}
end


M.setTyping      = setTyping
M.setTypingImgui = setTypingImgui
M.isTyping       = isTyping
M.isAway         = isAway
M.isLagging      = isLagging
M.handle         = handle

M.onUpdate       = onUpdate
M.onDisconnect   = onDisconnect
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
