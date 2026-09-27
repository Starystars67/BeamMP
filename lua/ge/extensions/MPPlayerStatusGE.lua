-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPPlayerStatusGE API.
--- Small player status shared with everyone else on the server, for now just "typing in chat".
--- It's sent as an extra electrics value ("beammp_status") on one of our own vehicles. Servers already relay electrics
--- for your own vehicles as they are, so this works on every server without a server update or plugin, and clients
--- without this just get an electrics value they don't use.
--- @module MPPlayerStatusGE
--- @usage MPPlayerStatusGE.isTyping(playerID) -- true while that player is typing in chat

local M = {}

-- status bits, more can be added later (AFK, in menu...) without changing the packet
local STATUS_TYPING = 1

local RESEND_INTERVAL = 2 -- seconds between resends while a status is set, so players that join late or missed a packet catch up
local REMOTE_TIMEOUT = 5  -- seconds without hearing from a player before their status is cleared (lost "stopped typing", left etc)

local localStatus = 0
local sentStatus = 0
local typingCef, typingImgui = false, false -- each chat window reports on its own so they can't overwrite each other
local imguiTypingAge = 0 -- the imgui chat reports every frame it's drawn, if it stops (window closed) typing ends
local resendTimer = 0
local remoteStatus = {} -- [playerID] = { status = bits, age = seconds since last heard }


-------------------------------------------------------------------------------
-- Sending
-------------------------------------------------------------------------------

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

--- Sets whether we're typing in the CEF chat. Called by the chat app when it changes, and when a message is sent.
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


-------------------------------------------------------------------------------
-- Receiving
-------------------------------------------------------------------------------

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

--- Returns if a player is typing in chat.
-- @tparam number playerID
-- @treturn boolean
local function isTyping(playerID)
	local s = remoteStatus[playerID]
	return s ~= nil and bit.band(s.status, STATUS_TYPING) ~= 0
end


-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function onUpdate(dt)
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
end

local function onDisconnect()
	localStatus, sentStatus, resendTimer = 0, 0, 0
	typingCef, typingImgui = false, false
	remoteStatus = {}
end


M.setTyping      = setTyping
M.setTypingImgui = setTypingImgui
M.isTyping       = isTyping
M.handle         = handle

M.onUpdate       = onUpdate
M.onDisconnect   = onDisconnect
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
