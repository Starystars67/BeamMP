-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPPerformanceGraph API.
--- Real time performance graph for BeamMP, separate from the game's own performance graph.
--- Shows how much Lua time each BeamMP extension takes per frame (GE, and VE across all vehicles via MPPerformanceVE),
--- optionally how much garbage they create (gcprobe style), and network traffic per packet type.
--- Instrumentation is only installed while the window is open, so it costs nothing when closed.
--- @module MPPerformanceGraph
--- @usage MPPerformanceGraph.toggle() -- open / close the window (also bindable under Controls > BeamMP)

local M = {}
M.dependencies = {"ui_imgui"}

local im = ui_imgui

local HISTORY = 600     -- frames kept for the Lua time graph
local NET_HISTORY = 120 -- seconds kept for the network graph
local STATS_FRAMES = 60 -- frames averaged for the "avg" column
local MAX_POINTS = 100  -- graph segments drawn per series, keeps the window itself cheap
local STATS_INTERVAL = 0.25 -- seconds between table stat refreshes
local VE_STALE = 1          -- seconds without a report before a vehicle stops counting (deleted, culled or reloaded)

-- extensions that get timed, one checkbox each
local modules = {
	{ ext = "MPVehicleGE",        desc = "vehicle spawn/edit/delete, nametags, queue" },
	{ ext = "positionGE",         desc = "position sync" },
	{ ext = "MPInputsGE",         desc = "inputs sync" },
	{ ext = "MPElectricsGE",      desc = "electrics sync" },
	{ ext = "MPPowertrainGE",     desc = "powertrain sync" },
	{ ext = "nodesGE",            desc = "damage / break group sync" },
	{ ext = "MPControllerGE",     desc = "controller sync" },
	{ ext = "MPVehiclePoolGE",    desc = "remote vehicle culling" },
	{ ext = "MPUpdatesGE",        desc = "send tick scheduling" },
	{ ext = "MPGameNetwork",      desc = "launcher socket, packet receive + dispatch" },
	{ ext = "MPCoreNetwork",      desc = "session, server browser" },
	{ ext = "UI",                 desc = "chat window, UI bridge" },
	{ ext = "MPModManager",       desc = "mod management" },
	{ ext = "MPConfig",           desc = "config" },
	{ ext = "MPHelpers",          desc = "helpers" },
	{ ext = "beammp_multiplayer", desc = "instability handler, game overrides" },
	{ ext = "MPDebug",            desc = "developer tool windows" },
}

-- VE extensions that get timed in every vehicle by MPPerformanceVE, summed over all vehicles
local veModules = {
	{ ext = "positionVE",           desc = "position sync, runs every physics step" },
	{ ext = "velocityVE",           desc = "velocity corrections for remote vehicles" },
	{ ext = "MPInputsVE",           desc = "inputs sync" },
	{ ext = "MPElectricsVE",        desc = "electrics sync" },
	{ ext = "MPPowertrainVE",       desc = "powertrain sync" },
	{ ext = "MPPowertrainHydrosVE", desc = "hydros sync" },
	{ ext = "nodesVE",              desc = "damage / break group sync" },
	{ ext = "controllerSyncVE",     desc = "controller sync" },
	{ ext = "couplerVE",            desc = "coupler sync" },
	{ ext = "MPVehicleVE",          desc = "vehicle type, server ID, key events" },
}

-- packet types by first byte of the packet
local packetTypes = {
	{ codes = "Z", label = "Position" },
	{ codes = "V", label = "Inputs" },
	{ codes = "W", label = "Electrics" },
	{ codes = "Y", label = "Powertrain" },
	{ codes = "X", label = "Nodes / damage" },
	{ codes = "R", label = "Controllers" },
	{ codes = "O", label = "Vehicle events" },
	{ codes = "C", label = "Chat" },
	{ codes = "E", label = "Lua events" },
	{ codes = "",  label = "Other" }, -- everything else, must stay last
}

local palette = {
	{0.95, 0.33, 0.31}, {0.30, 0.69, 0.98}, {0.55, 0.85, 0.35}, {0.99, 0.76, 0.20}, {0.73, 0.47, 0.96},
	{0.20, 0.86, 0.80}, {0.98, 0.55, 0.20}, {0.96, 0.45, 0.72}, {0.60, 0.60, 0.98}, {0.85, 0.85, 0.85},
	{0.45, 0.80, 0.55}, {0.98, 0.90, 0.50}, {0.55, 0.75, 0.95}, {0.80, 0.55, 0.45}, {0.70, 0.95, 0.70},
	{0.95, 0.65, 0.65}, {0.65, 0.65, 0.65},
}

local active = false
local windowOpen = im.BoolPtr(false)
local paused = im.BoolPtr(false)
local autoScale = im.BoolPtr(true)
local fixedScaleMs = im.FloatPtr(1.0)
local viewFrames = im.IntPtr(300)
local showTotal = im.BoolPtr(true)
local showFrameTime = im.BoolPtr(false)
local showNetIn = im.BoolPtr(true)
local showNetOut = im.BoolPtr(true)
local showVETotal = im.BoolPtr(true)
local trackGarbage = im.BoolPtr(false) -- gcprobe style, stops the GC around each outermost wrapped call so it's opt in
local graphMode = im.IntPtr(0)         -- 0 = time, 1 = garbage

local clock = hptimer()

-- ring buffers, newest sample at `head`
local head, count = 0, 0
local frameTotal = 0 -- absolute sample counters, graph buckets are aligned to these so they don't shift every frame
local totalSamples, frameSamples, callSamples, totalBytes = {}, {}, {}, {}
local veTotalSamples, veTotalBytes, veCallSamples = {}, {}, {}
local netHead, netCount = 0, 0
local netTotal = 0
local netInTotal, netOutTotal = {}, {}

-- per frame accumulators
local frameSelf, frameCallsPer, frameBytesPer = {}, {}, {}
local frameCalls = 0
local depth = 0
local startAt, childTime, startBytes, childBytes = {}, {}, {}, {}
local gcStopped = false
local collect = collectgarbage

-- per second network accumulators
local netTimer = 0
local secInBytes, secOutBytes, secInCount, secOutCount = {}, {}, {}, {}
local lastInBytes, lastOutBytes, lastInCount, lastOutCount = {}, {}, {}, {}
local typeByByte = {}

local wrapped = {} -- [moduleIndex] = { tbl = moduleTable, fns = { [name] = { orig, wrapper } } }

-- VE side, filled by veReport
local veVehicles = {} -- [gameVehicleID] = { at = veClock of the last report, frames, values = { ms, calls, KB, ... } }
local veLoaded = {}   -- [gameVehicleID] = true once MPPerformanceVE was sent to that vehicle
local veNow, veNowCalls, veNowBytes = {}, {}, {} -- latest sum over all vehicles per VE module
local veNowTotal, veNowTotalBytes, veNowTotalCalls, veReporting = 0, 0, 0, 0
local veClock = 0
local veDirty = false
local veStartCommand = ""
local instrumentTimer = 0
local timerCallCost = 0 -- ms per wrapped call (two clock reads)

local p1, p2 -- reused ImVec2 for line drawing when the binding allows mutation
local vec2Mutable = false

local function u32(r, g, b, a)
	return math.floor(r * 255 + 0.5) + math.floor(g * 255 + 0.5) * 256 + math.floor(b * 255 + 0.5) * 65536 + math.floor((a or 1) * 255 + 0.5) * 16777216
end

local colBackground = u32(0.08, 0.08, 0.08, 0.9)
local colGrid = u32(1, 1, 1, 0.12)
local colGridText = u32(1, 1, 1, 0.55)
local colHover = u32(1, 1, 1, 0.35)
local colTotal = u32(1, 1, 1, 1)
local colFrame = u32(0.5, 0.5, 0.5, 1)
local colNetIn = u32(0.30, 0.69, 0.98, 1)
local colNetOut = u32(0.98, 0.55, 0.20, 1)

local function initModules(list, idPrefix, paletteOffset)
	for i, m in ipairs(list) do
		local c = palette[(i - 1 + paletteOffset) % #palette + 1]
		m.color = u32(c[1], c[2], c[3], 1)
		m.color4 = im.ImVec4(c[1], c[2], c[3], 1)
		m.enabled = m.enabled or im.BoolPtr(true)
		m.samples = {}
		m.calls = {}
		m.bytes = {}
		m.checkboxLabel = m.ext .. "##" .. idPrefix .. i
		m.swatchId = "##" .. idPrefix .. "swatch" .. i
		for k = 1, HISTORY do m.samples[k] = 0; m.calls[k] = 0; m.bytes[k] = 0 end
	end
end

local function initData()
	initModules(modules, "perfmod", 0)
	initModules(veModules, "perfve", 5)
	for i = 1, #modules do frameSelf[i], frameCallsPer[i], frameBytesPer[i] = 0, 0, 0 end
	for i = 1, #veModules do veNow[i], veNowCalls[i], veNowBytes[i] = 0, 0, 0 end
	veNowTotal, veNowTotalBytes, veNowTotalCalls, veReporting = 0, 0, 0, 0
	for k = 1, HISTORY do
		totalSamples[k], frameSamples[k], callSamples[k], totalBytes[k] = 0, 0, 0, 0
		veTotalSamples[k], veTotalBytes[k], veCallSamples[k] = 0, 0, 0
	end

	for t, pt in ipairs(packetTypes) do
		local c = palette[(t + 3) % #palette + 1]
		pt.color = u32(c[1], c[2], c[3], 1)
		pt.color4 = im.ImVec4(c[1], c[2], c[3], 1)
		pt.enabled = pt.enabled or im.BoolPtr(false)
		pt.inBytes = {}
		pt.checkboxLabel = pt.label .. "##perfnet" .. t
		pt.swatchId = "##perfnetswatch" .. t
		for k = 1, NET_HISTORY do pt.inBytes[k] = 0 end
		for ci = 1, #pt.codes do typeByByte[pt.codes:byte(ci)] = t end
		secInBytes[t], secOutBytes[t], secInCount[t], secOutCount[t] = 0, 0, 0, 0
		lastInBytes[t], lastOutBytes[t], lastInCount[t], lastOutCount[t] = 0, 0, 0, 0
	end
	for k = 1, NET_HISTORY do netInTotal[k] = 0; netOutTotal[k] = 0 end
	head, count, netHead, netCount = 0, 0, 0, 0
	frameTotal, netTotal = 0, 0
end

-- ============================================================================
-- Instrumentation
-- ============================================================================

-- Wraps a module function so its self time (time not spent in other wrapped functions) is added to module i.
-- Multiple return values are passed straight through, no tables are created.
local function makeWrapper(i, fn)
	local function leave(...)
		if depth < 1 then return ... end -- stack was reset (error in a wrapped call or a new frame), drop this sample
		local elapsed = clock:stop() - startAt[depth]
		frameSelf[i] = frameSelf[i] + elapsed - childTime[depth]
		depth = depth - 1
		if depth > 0 then childTime[depth] = childTime[depth] + elapsed end
		return ...
	end
	return function(...)
		depth = depth + 1
		frameCalls = frameCalls + 1
		frameCallsPer[i] = frameCallsPer[i] + 1
		childTime[depth], childBytes[depth] = 0, 0 -- both, a garbage wrapper can end up nested inside this one right after toggling
		startAt[depth] = clock:stop()
		return leave(fn(...))
	end
end

-- Same as makeWrapper but also counts the garbage created (KB). Like the game's gcprobe() the GC is stopped while we
-- measure, otherwise a GC step inside the call frees memory and collectgarbage("count") goes down. It's only stopped
-- for the outermost wrapped call so nested calls don't restart it early.
local function makeGcWrapper(i, fn)
	local function leave(...)
		if depth < 1 then return ... end
		local elapsed = clock:stop() - startAt[depth]
		local kb = collect("count") - startBytes[depth]
		frameSelf[i] = frameSelf[i] + elapsed - childTime[depth]
		frameBytesPer[i] = frameBytesPer[i] + kb - childBytes[depth]
		depth = depth - 1
		if depth > 0 then
			childTime[depth] = childTime[depth] + elapsed
			childBytes[depth] = childBytes[depth] + kb
		elseif gcStopped then
			gcStopped = false
			collect("restart")
		end
		return ...
	end
	return function(...)
		if depth == 0 and not gcStopped and collect("isrunning") then -- leave it alone if something else already stopped it
			gcStopped = true
			collect("stop")
		end
		depth = depth + 1
		frameCalls = frameCalls + 1
		frameCallsPer[i] = frameCallsPer[i] + 1
		childTime[depth], childBytes[depth] = 0, 0
		startBytes[depth] = collect("count")
		startAt[depth] = clock:stop()
		return leave(fn(...))
	end
end

local function resetStack()
	depth = 0
	if gcStopped then -- never leave the GC stopped, even if a wrapped call errored
		gcStopped = false
		collect("restart")
	end
end

-- sends MPPerformanceVE to vehicles that don't have it yet (new, or respawned so their Lua VM was rebuilt)
local function instrumentVehicles()
	for _, veh in ipairs(getAllVehicles()) do
		local id = veh:getID()
		if not veLoaded[id] then
			veLoaded[id] = true
			veh:queueLuaCommand(veStartCommand)
		end
	end
end

local function uninstrumentVehicles()
	-- every vehicle, not just veLoaded ones: one that was respawning gets MPPerformanceVE back from the game by itself
	for _, veh in ipairs(getAllVehicles()) do veh:queueLuaCommand("extensions.unload('MPPerformanceVE')") end
	veLoaded, veVehicles = {}, {}
end

local function buildVeStartCommand()
	local names = {}
	for i, m in ipairs(veModules) do names[i] = string.format("%q", m.ext) end
	veStartCommand = string.format("extensions.load('MPPerformanceVE') MPPerformanceVE.start({%s}, %s)", table.concat(names, ","), tostring(trackGarbage[0]))
end

local function instrument()
	local make = trackGarbage[0] and makeGcWrapper or makeWrapper
	local hookNames = {}
	for i, m in ipairs(modules) do
		local tbl = extensions.isExtensionLoaded(m.ext) and extensions[m.ext] or nil
		m.loaded = tbl ~= nil
		if tbl and not (wrapped[i] and wrapped[i].tbl == tbl) then -- new, or reloaded since we last wrapped it
			local w = { tbl = tbl, fns = {} }
			for name, fn in pairs(tbl) do
				if type(fn) == "function" and fn ~= nop and name:sub(1, 2) ~= "__" then
					w.fns[name] = { orig = fn, wrapper = make(i, fn) }
				end
			end
			for name, f in pairs(w.fns) do
				tbl[name] = f.wrapper
				if name:sub(1, 2) == "on" then hookNames[name] = true end
			end
			wrapped[i] = w
		end
	end
	for name in pairs(hookNames) do extensions.hookUpdate(name) end -- the hook cache holds the old function references
	instrumentVehicles()
end

local function uninstrument()
	local hookNames = {}
	for _, w in pairs(wrapped) do
		for name, f in pairs(w.fns) do
			if w.tbl[name] == f.wrapper then w.tbl[name] = f.orig end -- leave it alone if the module replaced it itself
			if name:sub(1, 2) == "on" then hookNames[name] = true end
		end
	end
	wrapped = {}
	resetStack()
	for name in pairs(hookNames) do extensions.hookUpdate(name) end
end

-- the GE wrappers are swapped rather than branching on the setting in every call, VE vehicles get told to do the same
local function setTrackGarbage()
	uninstrument()
	buildVeStartCommand()
	instrument()
	local cmd = "if MPPerformanceVE then MPPerformanceVE.setTrackGarbage(" .. tostring(trackGarbage[0]) .. ") end"
	for _, veh in ipairs(getAllVehicles()) do
		if veLoaded[veh:getID()] then veh:queueLuaCommand(cmd) end
	end
	if not trackGarbage[0] then graphMode[0] = 0 end
end

local function measureTimerCost()
	local n = 20000
	local t0 = clock:stop()
	for _ = 1, n do clock:stop() end
	timerCallCost = (clock:stop() - t0) / n * 2
end

-- ============================================================================
-- Network counters, called from MPGameNetwork
-- ============================================================================

--- Counts a received packet. Called by MPGameNetwork for every packet.
-- @tparam number codeByte first byte of the packet
-- @tparam number bytes packet size
local function packetReceived(codeByte, bytes)
	if not active then return end
	local t = typeByByte[codeByte] or #packetTypes
	secInBytes[t] = secInBytes[t] + bytes
	secInCount[t] = secInCount[t] + 1
end

--- Counts a sent packet. Called by MPGameNetwork for every packet.
-- @tparam number codeByte first byte of the packet
-- @tparam number bytes packet size
local function packetSent(codeByte, bytes)
	if not active then return end
	local t = typeByByte[codeByte] or #packetTypes
	secOutBytes[t] = secOutBytes[t] + bytes
	secOutCount[t] = secOutCount[t] + 1
end

-- ============================================================================
-- VE reports, called from MPPerformanceVE in each vehicle
-- ============================================================================

--- Takes a report from a vehicle's MPPerformanceVE. Values are per frame averages over the last report window.
-- @tparam number gameVehicleID
-- @tparam number frames VE frames the report covers
-- @tparam table values flat { ms, calls, KB } per VE module, same order as veModules
local function veReport(gameVehicleID, frames, values)
	if not active then -- left over in a vehicle that was reloaded around the time the window closed, tell it to stop
		local veh = be:getObjectByID(gameVehicleID)
		if veh then veh:queueLuaCommand("extensions.unload('MPPerformanceVE')") end
		return
	end
	if type(values) ~= "table" or #values < #veModules * 3 then return end -- not started yet (e.g. just reloaded) or from an older version
	local v = veVehicles[gameVehicleID]
	if not v then
		v = {}
		veVehicles[gameVehicleID] = v
	end
	v.at, v.frames, v.values = veClock, frames, values
	veDirty = true
end

-- sums the latest report of every vehicle, only when something changed instead of every frame
local function sumVehicles()
	for i = 1, #veModules do veNow[i], veNowCalls[i], veNowBytes[i] = 0, 0, 0 end
	veNowTotal, veNowTotalBytes, veNowTotalCalls, veReporting = 0, 0, 0, 0
	for id, v in pairs(veVehicles) do
		v.stale = veClock - v.at > VE_STALE -- deleted, culled (inactive vehicles don't run Lua) or respawned
		if not v.stale then
			local values, ms, kb = v.values, 0, 0
			for i = 1, #veModules do
				local b = i * 3 - 2
				veNow[i] = veNow[i] + values[b]
				veNowCalls[i] = veNowCalls[i] + values[b + 1]
				veNowBytes[i] = veNowBytes[i] + values[b + 2]
				ms, kb = ms + values[b], kb + values[b + 2]
				veNowTotalCalls = veNowTotalCalls + values[b + 1]
			end
			v.ms, v.kb = ms, kb
			veNowTotal, veNowTotalBytes = veNowTotal + ms, veNowTotalBytes + kb
			veReporting = veReporting + 1
		end
	end
	veDirty = false
end

-- ============================================================================
-- Sampling
-- ============================================================================

local function commitFrame(dtReal)
	head = head % HISTORY + 1
	frameTotal = frameTotal + 1
	local total, totalKb = 0, 0
	for i, m in ipairs(modules) do
		local v = frameSelf[i]
		m.samples[head] = v
		m.calls[head] = frameCallsPer[i]
		m.bytes[head] = frameBytesPer[i]
		total = total + v
		totalKb = totalKb + frameBytesPer[i]
	end
	totalSamples[head] = total
	totalBytes[head] = totalKb
	frameSamples[head] = dtReal * 1000
	callSamples[head] = frameCalls

	-- VE reports come in a few times a second, so these step rather than change every frame
	for i, m in ipairs(veModules) do
		m.samples[head] = veNow[i]
		m.calls[head] = veNowCalls[i]
		m.bytes[head] = veNowBytes[i]
	end
	veTotalSamples[head] = veNowTotal
	veTotalBytes[head] = veNowTotalBytes
	veCallSamples[head] = veNowTotalCalls
	if count < HISTORY then count = count + 1 end
end

local function resetFrame()
	for i = 1, #modules do frameSelf[i], frameCallsPer[i], frameBytesPer[i] = 0, 0, 0 end
	frameCalls = 0
	resetStack()
end

local function commitNetwork()
	netHead = netHead % NET_HISTORY + 1
	netTotal = netTotal + 1
	local inTotal, outTotal = 0, 0
	for t, pt in ipairs(packetTypes) do
		pt.inBytes[netHead] = secInBytes[t] / 1000
		inTotal = inTotal + secInBytes[t]
		outTotal = outTotal + secOutBytes[t]
		lastInBytes[t], lastOutBytes[t], lastInCount[t], lastOutCount[t] = secInBytes[t], secOutBytes[t], secInCount[t], secOutCount[t]
		secInBytes[t], secOutBytes[t], secInCount[t], secOutCount[t] = 0, 0, 0, 0
	end
	netInTotal[netHead] = inTotal / 1000
	netOutTotal[netHead] = outTotal / 1000
	if netCount < NET_HISTORY then netCount = netCount + 1 end
end

-- ============================================================================
-- Drawing
-- ============================================================================

local function vec2(which, x, y)
	if vec2Mutable then
		which.x, which.y = x, y
		return which
	end
	return im.ImVec2(x, y)
end

local function ringIndex(h, size, k) -- k samples before the newest
	return (h - 1 - k) % size + 1
end

local function niceMax(v)
	if v <= 0 then return 0.01 end
	local mag = 10 ^ math.floor(math.log10(v))
	local n = v / mag
	if n <= 1 then n = 1 elseif n <= 2 then n = 2 elseif n <= 5 then n = 5 else n = 10 end
	return n * mag
end

-- series = array of { values = ring, color = u32, label = string }
local function drawGraph(id, height, series, ringHead, ringCount, ringSize, shown, fixedMax, unitFmt, hoverFmt, absNewest)
	local avail = im.GetContentRegionAvail()
	local width = math.max(100, avail.x)
	local origin = im.GetCursorScreenPos()
	local ox, oy = origin.x, origin.y
	im.InvisibleButton(id, im.ImVec2(width, height))
	local hovered = im.IsItemHovered()
	local dl = im.GetWindowDrawList()

	shown = math.min(shown, ringCount)
	local yMax = fixedMax
	if not yMax then
		yMax = 0
		for _, s in ipairs(series) do
			local values = s.values
			for k = 0, shown - 1 do
				local v = values[ringIndex(ringHead, ringSize, k)]
				if v > yMax then yMax = v end
			end
		end
		yMax = niceMax(yMax)
	end

	im.ImDrawList_AddRectFilled(dl, vec2(p1, ox, oy), vec2(p2, ox + width, oy + height), colBackground)
	for g = 1, 3 do
		local y = oy + height - height * g / 4
		im.ImDrawList_AddLine(dl, vec2(p1, ox, y), vec2(p2, ox + width, y), colGrid, 1)
		im.ImDrawList_AddText1(dl, vec2(p1, ox + 4, y - 14), colGridText, string.format(unitFmt, yMax * g / 4))
	end
	im.ImDrawList_AddText1(dl, vec2(p1, ox + 4, oy + 2), colGridText, string.format(unitFmt, yMax))

	if shown > 1 then
		local span = math.max(2, shown)
		local step = width / (span - 1)
		-- at most MAX_POINTS segments per series; each point is the max of its bucket so short spikes stay visible.
		-- Buckets are aligned to the absolute sample number, so a sample always lands in the same bucket and the
		-- line scrolls smoothly instead of re-picking peaks every frame.
		local bucket = math.max(1, math.ceil(shown / MAX_POINTS))
		local flat = yMax * 0.002
		local oldestAbs = absNewest - (shown - 1)
		local firstBucket = oldestAbs - (oldestAbs % bucket)
		for _, s in ipairs(series) do
			local values, col = s.values, s.color
			local peak = 0
			for k = 0, shown - 1 do
				local v = values[ringIndex(ringHead, ringSize, k)]
				if v > peak then peak = v end
			end
			if peak > flat then -- a series that stays at ~0 is just a line on the axis, skip the draw calls
				-- flat stretches are drawn as one segment: a vertex is only added where the line moves by half a pixel or
				-- more. VE values only change 4 times a second and most extensions sit still, so this saves most draw calls
				local thickness = s.thickness or 1.5
				local px, py -- last vertex drawn to
				local lx, ly -- end of the flat stretch we're on, not drawn yet
				for bs = firstBucket, absNewest, bucket do
					local be = math.min(bs + bucket - 1, absNewest)
					local v = 0
					for j = math.max(bs, oldestAbs), be do
						local x = values[ringIndex(ringHead, ringSize, absNewest - j)]
						if x > v then v = x end
					end
					local x = ox + width - (absNewest - be) * step
					local y = oy + height - math.min(v / yMax, 1) * height
					if not px then
						px, py, lx, ly = x, y, x, y
					elseif math.abs(y - ly) < 0.5 then
						lx = x -- still flat, just extend it
					else
						if lx ~= px then im.ImDrawList_AddLine(dl, vec2(p1, px, py), vec2(p2, lx, ly), col, thickness) end
						im.ImDrawList_AddLine(dl, vec2(p1, lx, ly), vec2(p2, x, y), col, thickness)
						px, py, lx, ly = x, y, x, y
					end
				end
				if px and lx ~= px then im.ImDrawList_AddLine(dl, vec2(p1, px, py), vec2(p2, lx, ly), col, thickness) end
			end
		end

		if hovered then
			local mouse = im.GetMousePos()
			local k = math.floor((ox + width - mouse.x) / step + 0.5)
			if k >= 0 and k < shown then
				local x = ox + width - k * step
				im.ImDrawList_AddLine(dl, vec2(p1, x, oy), vec2(p2, x, oy + height), colHover, 1)
				im.BeginTooltip()
				im.Text(string.format(hoverFmt, k))
				for _, s in ipairs(series) do
					im.Text(string.format("%-20s " .. unitFmt, s.label, s.values[ringIndex(ringHead, ringSize, k)]))
				end
				im.EndTooltip()
			end
		end
	end
end

-- table stats only change meaningfully a few times a second, recompute them every STATS_INTERVAL instead of every frame
local statsCache, statsTimer = {}, 0
local function seriesStatsUncached(values, ringHead, ringCount, ringSize, avgCount, shown)
	local sum, max = 0, 0
	local n = math.min(avgCount, ringCount)
	for k = 0, n - 1 do sum = sum + values[ringIndex(ringHead, ringSize, k)] end
	for k = 0, math.min(shown, ringCount) - 1 do
		local v = values[ringIndex(ringHead, ringSize, k)]
		if v > max then max = v end
	end
	return n > 0 and sum / n or 0, max
end

local function seriesStats(values, ringHead, ringCount, ringSize, avgCount, shown)
	local key = tostring(values) .. avgCount .. ":" .. shown
	local c = statsCache[key]
	if not c then
		c = { seriesStatsUncached(values, ringHead, ringCount, ringSize, avgCount, shown) }
		statsCache[key] = c
	end
	return c[1], c[2]
end

local luaSeries, veSeries, netSeries = {}, {}, {}
local perVehicle = {}

local function clearArray(t)
	for k = #t, 1, -1 do t[k] = nil end
end

local function showingGarbage()
	return trackGarbage[0] and graphMode[0] == 1
end

-- graph ring for a module / total depending on the graph mode
local function graphValues(timeRing, byteRing)
	if showingGarbage() then return byteRing end
	return timeRing
end

local function drawTableHeader(id, firstColumn)
	local gc = trackGarbage[0]
	im.Columns(gc and 6 or 5, id, false)
	im.SetColumnWidth(0, 250)
	im.TextDisabled(firstColumn) im.NextColumn()
	im.TextDisabled("avg ms") im.NextColumn()
	im.TextDisabled("max ms") im.NextColumn()
	im.TextDisabled("pct of frame") im.NextColumn()
	im.TextDisabled("calls/frame") im.NextColumn()
	if gc then im.TextDisabled("KB/frame") im.NextColumn() end
end

local function drawStatsRow(avg, max, frameAvg, calls, kb)
	im.Text(string.format("%.3f", avg)) im.NextColumn()
	im.Text(string.format("%.3f", max)) im.NextColumn()
	im.Text(string.format("%.2f", frameAvg > 0 and avg / frameAvg * 100 or 0)) im.NextColumn()
	im.Text(string.format("%.0f", calls)) im.NextColumn()
	if trackGarbage[0] then im.Text(string.format("%.2f", kb)) im.NextColumn() end
end

local function drawModuleRows(list, frameAvg, shown, loadedCheck)
	for _, m in ipairs(list) do
		im.ColorButton(m.swatchId, m.color4, 0, im.ImVec2(12, 12))
		im.SameLine()
		if m.loaded or not loadedCheck then
			im.Checkbox(m.checkboxLabel, m.enabled)
			if im.IsItemHovered() then im.SetTooltip(m.desc) end
			im.NextColumn()
			local avg, max = seriesStats(m.samples, head, count, HISTORY, STATS_FRAMES, shown)
			local calls = seriesStats(m.calls, head, count, HISTORY, STATS_FRAMES, shown)
			local kb = trackGarbage[0] and seriesStats(m.bytes, head, count, HISTORY, STATS_FRAMES, shown) or 0
			drawStatsRow(avg, max, frameAvg, calls, kb)
		else
			im.TextDisabled(m.ext .. " (not loaded)") im.NextColumn()
			for _ = 2, trackGarbage[0] and 6 or 5 do im.NextColumn() end
		end
	end
end

local function drawGraphFor(id, height, series, shown)
	if showingGarbage() then
		drawGraph(id, height, series, head, count, HISTORY, shown, nil, "%.2f KB", "%d frames ago", frameTotal)
	else
		drawGraph(id, height, series, head, count, HISTORY, shown, (not autoScale[0]) and fixedScaleMs[0] or nil, "%.3f ms", "%d frames ago", frameTotal)
	end
end

local function drawLuaSection()
	local shown = viewFrames[0]
	local frameAvg = seriesStats(frameSamples, head, count, HISTORY, STATS_FRAMES, shown)
	local totalAvg, totalMax = seriesStats(totalSamples, head, count, HISTORY, STATS_FRAMES, shown)
	local callsAvg = seriesStats(callSamples, head, count, HISTORY, STATS_FRAMES, shown)
	local totalKb = trackGarbage[0] and seriesStats(totalBytes, head, count, HISTORY, STATS_FRAMES, shown) or 0

	im.TextUnformatted(string.format("BeamMP GE Lua: %.3f ms/frame avg (max %.3f), %.2f%% of a %.2f ms frame", -- unformatted, the text contains a literal %
		totalAvg, totalMax, frameAvg > 0 and totalAvg / frameAvg * 100 or 0, frameAvg))
	if trackGarbage[0] then
		im.TextDisabled(string.format("garbage: %.2f KB/frame, %.0f KB/s", totalKb, frameAvg > 0 and totalKb / frameAvg * 1000 or 0))
	end
	im.TextDisabled(string.format("self time per extension, %d wrapped calls/frame, instrumentation overhead ~%.3f ms/frame",
		math.floor(callsAvg + 0.5), callsAvg * timerCallCost))

	clearArray(luaSeries)
	if showFrameTime[0] and not showingGarbage() then luaSeries[#luaSeries + 1] = { values = frameSamples, color = colFrame, label = "Frame time" } end
	if showTotal[0] then luaSeries[#luaSeries + 1] = { values = graphValues(totalSamples, totalBytes), color = colTotal, label = "GE total", thickness = 2 } end
	for _, m in ipairs(modules) do
		if m.enabled[0] and m.loaded then luaSeries[#luaSeries + 1] = { values = graphValues(m.samples, m.bytes), color = m.color, label = m.ext } end
	end
	drawGraphFor("##luagraph", 180, luaSeries, shown)

	-- legend / table
	drawTableHeader("##perfluacols", "GE extension")
	im.Checkbox("GE total##perftotal", showTotal) im.NextColumn()
	drawStatsRow(totalAvg, totalMax, frameAvg, callsAvg, totalKb)

	im.Checkbox("Frame time##perfframe", showFrameTime) im.NextColumn()
	im.Text(string.format("%.3f", frameAvg)) im.NextColumn()
	for _ = 3, trackGarbage[0] and 6 or 5 do im.NextColumn() end

	drawModuleRows(modules, frameAvg, shown, true)
	im.Columns(1)
end

local function vehicleLabel(id)
	local vehicle = MPVehicleGE and MPVehicleGE.getVehicleByGameID(id)
	if vehicle then
		return string.format("%d %s (%s)", id, vehicle.jbeam or "?", MPVehicleGE.isOwn(id) and "own" or (vehicle.ownerName or "remote"))
	end
	local veh = be:getObjectByID(id)
	return string.format("%d %s", id, veh and veh:getJBeamFilename() or "?")
end

local function drawVESection()
	local shown = viewFrames[0]
	local frameAvg = seriesStats(frameSamples, head, count, HISTORY, STATS_FRAMES, shown)
	local totalAvg, totalMax = seriesStats(veTotalSamples, head, count, HISTORY, STATS_FRAMES, shown)
	local callsAvg = seriesStats(veCallSamples, head, count, HISTORY, STATS_FRAMES, shown)
	local totalKb = trackGarbage[0] and seriesStats(veTotalBytes, head, count, HISTORY, STATS_FRAMES, shown) or 0

	local vehicleCount = 0
	for _ in pairs(veLoaded) do vehicleCount = vehicleCount + 1 end
	im.Text(string.format("BeamMP VE Lua: %.3f ms/frame avg (max %.3f) across %d of %d vehicles", totalAvg, totalMax, veReporting, vehicleCount))
	if trackGarbage[0] then im.TextDisabled(string.format("garbage: %.2f KB/frame", totalKb)) end
	im.TextDisabled(string.format("runs on the vehicle threads next to physics, updates every 0.25 s, %d wrapped calls/frame", math.floor(callsAvg + 0.5)))
	if im.IsItemHovered() then im.SetTooltip("Culled (inactive) vehicles don't run Lua, so they drop out of the count") end

	clearArray(veSeries)
	if showVETotal[0] then veSeries[#veSeries + 1] = { values = graphValues(veTotalSamples, veTotalBytes), color = colTotal, label = "VE total", thickness = 2 } end
	for _, m in ipairs(veModules) do
		if m.enabled[0] then veSeries[#veSeries + 1] = { values = graphValues(m.samples, m.bytes), color = m.color, label = m.ext } end
	end
	drawGraphFor("##vegraph", 150, veSeries, shown)

	drawTableHeader("##perfvecols", "VE extension (all vehicles)")
	im.Checkbox("VE total##perfvetotal", showVETotal) im.NextColumn()
	drawStatsRow(totalAvg, totalMax, frameAvg, callsAvg, totalKb)
	drawModuleRows(veModules, frameAvg, shown, false)
	im.Columns(1)

	if im.CollapsingHeader1("Per vehicle##perfvehicles") then
		clearArray(perVehicle)
		for id, v in pairs(veVehicles) do perVehicle[#perVehicle + 1] = id end
		table.sort(perVehicle, function(a, b) return (veVehicles[a].ms or 0) > (veVehicles[b].ms or 0) end)
		im.Columns(trackGarbage[0] and 3 or 2, "##perfvehcols", false)
		im.SetColumnWidth(0, 300)
		im.TextDisabled("Vehicle") im.NextColumn()
		im.TextDisabled("ms/frame") im.NextColumn()
		if trackGarbage[0] then im.TextDisabled("KB/frame") im.NextColumn() end
		for _, id in ipairs(perVehicle) do
			local v = veVehicles[id]
			v.label = v.label or vehicleLabel(id)
			if v.stale then
				im.TextDisabled(v.label .. " (no report)") im.NextColumn()
				im.NextColumn()
				if trackGarbage[0] then im.NextColumn() end
			else
				im.Text(v.label) im.NextColumn()
				im.Text(string.format("%.3f", v.ms or 0)) im.NextColumn()
				if trackGarbage[0] then im.Text(string.format("%.2f", v.kb or 0)) im.NextColumn() end
			end
		end
		im.Columns(1)
	end
end

local function drawNetworkSection()
	local inTotal, outTotal, inCount, outCount = 0, 0, 0, 0
	for t = 1, #packetTypes do
		inTotal, outTotal = inTotal + lastInBytes[t], outTotal + lastOutBytes[t]
		inCount, outCount = inCount + lastInCount[t], outCount + lastOutCount[t]
	end
	im.Text(string.format("Received %.2f KB/s (%d packets/s), sent %.2f KB/s (%d packets/s)", inTotal / 1000, inCount, outTotal / 1000, outCount))

	clearArray(netSeries)
	if showNetIn[0] then netSeries[#netSeries + 1] = { values = netInTotal, color = colNetIn, label = "Received total", thickness = 2 } end
	if showNetOut[0] then netSeries[#netSeries + 1] = { values = netOutTotal, color = colNetOut, label = "Sent total", thickness = 2 } end
	for _, pt in ipairs(packetTypes) do
		if pt.enabled[0] then netSeries[#netSeries + 1] = { values = pt.inBytes, color = pt.color, label = "In: " .. pt.label } end
	end
	drawGraph("##netgraph", 130, netSeries, netHead, netCount, NET_HISTORY, NET_HISTORY, nil, "%.2f KB/s", "%d seconds ago", netTotal)

	im.Columns(5, "##perfnetcols", false)
	im.SetColumnWidth(0, 250)
	im.TextDisabled("Packet type (graph = received)") im.NextColumn()
	im.TextDisabled("in pkt/s") im.NextColumn()
	im.TextDisabled("in KB/s") im.NextColumn()
	im.TextDisabled("out pkt/s") im.NextColumn()
	im.TextDisabled("out KB/s") im.NextColumn()

	im.Checkbox("Received total##perfnetin", showNetIn) im.NextColumn()
	im.Text(tostring(inCount)) im.NextColumn()
	im.Text(string.format("%.2f", inTotal / 1000)) im.NextColumn()
	im.NextColumn() im.NextColumn()
	im.Checkbox("Sent total##perfnetout", showNetOut) im.NextColumn()
	im.NextColumn() im.NextColumn()
	im.Text(tostring(outCount)) im.NextColumn()
	im.Text(string.format("%.2f", outTotal / 1000)) im.NextColumn()

	for t, pt in ipairs(packetTypes) do
		im.ColorButton(pt.swatchId, pt.color4, 0, im.ImVec2(12, 12))
		im.SameLine()
		im.Checkbox(pt.checkboxLabel, pt.enabled) im.NextColumn()
		im.Text(tostring(lastInCount[t])) im.NextColumn()
		im.Text(string.format("%.2f", lastInBytes[t] / 1000)) im.NextColumn()
		im.Text(tostring(lastOutCount[t])) im.NextColumn()
		im.Text(string.format("%.2f", lastOutBytes[t] / 1000)) im.NextColumn()
	end
	im.Columns(1)
end

local windowBegun = false -- so a failed frame can still close the imgui window it opened

local function drawWindow()
	im.SetNextWindowSize(im.ImVec2(640, 760), im.Cond_FirstUseEver)
	windowBegun = true
	if im.Begin("BeamMP Performance##MPPerformanceGraph", windowOpen) then
		im.Checkbox("Pause", paused)
		im.SameLine()
		im.Checkbox("Auto scale", autoScale)
		if not autoScale[0] then
			im.SameLine()
			im.PushItemWidth(120)
			im.SliderFloat("max ms", fixedScaleMs, 0.01, 20, "%.2f")
			im.PopItemWidth()
		end
		im.SameLine()
		im.PushItemWidth(120)
		im.SliderInt("frames", viewFrames, 60, HISTORY)
		im.PopItemWidth()

		if im.Checkbox("Track garbage (gcprobe)", trackGarbage) then setTrackGarbage() end
		if im.IsItemHovered() then im.SetTooltip("Counts the garbage each extension creates. Stops the GC around each measured call like the game's gcprobe(), so it adds a bit of overhead") end
		if trackGarbage[0] then
			im.SameLine()
			im.RadioButton2("Graph time##perfmode", graphMode, im.Int(0))
			im.SameLine()
			im.RadioButton2("Graph garbage##perfmode", graphMode, im.Int(1))
		end

		im.Separator()
		drawLuaSection()
		im.Separator()
		drawVESection()
		im.Separator()
		drawNetworkSection()
	end
	im.End()
	windowBegun = false
	if not windowOpen[0] then M.hide() end
end

-- ============================================================================
-- Public
-- ============================================================================

--- Opens the window and installs the instrumentation.
local function show()
	if active then return end
	if not p1 then
		p1, p2 = im.ImVec2(0, 0), im.ImVec2(0, 0)
		vec2Mutable = pcall(function() p1.x = 1; assert(p1.x == 1); p1.x = 0 end)
	end
	initData()
	measureTimerCost()
	buildVeStartCommand()
	instrument()
	resetFrame()
	instrumentTimer = 0
	netTimer = 0
	active = true
	windowOpen[0] = true
end

--- Closes the window and removes the instrumentation, restoring every wrapped function.
local function hide()
	if not active then return end
	active = false
	windowOpen[0] = false
	uninstrument()
	uninstrumentVehicles()
end

--- Opens or closes the window.
local function toggle()
	if active then hide() else show() end
end

local function update(dtReal)
	if not paused[0] then commitFrame(dtReal) end
	resetFrame()

	veClock = veClock + dtReal
	statsTimer = statsTimer + dtReal
	if statsTimer >= STATS_INTERVAL then
		statsTimer = 0
		statsCache = {}
		veDirty = true -- also picks up vehicles that stopped reporting
	end
	if veDirty then sumVehicles() end

	netTimer = netTimer + dtReal
	if netTimer >= 1 then
		netTimer = netTimer - 1
		if not paused[0] then commitNetwork() end
	end

	instrumentTimer = instrumentTimer + dtReal
	if instrumentTimer >= 2 then -- pick up extensions loaded or reloaded, and vehicles spawned, while the window is open
		instrumentTimer = 0
		instrument()
	end

	drawWindow()
end

local function onUpdate(dtReal)
	if not active then return end
	-- a bug in the window must never break the extensions hooked after us, so if it errors we log it and close
	local ok, err = xpcall(update, debug.traceback, dtReal)
	if not ok then
		if windowBegun then im.End() windowBegun = false end
		log('E', 'MPPerformanceGraph', "Performance window error, closing it: " .. tostring(err))
		hide()
	end
end

-- hooks only run between wrapped calls, so a non zero depth here means a wrapped call errored and never returned
local function onPreRender()
	if active and (depth ~= 0 or gcStopped) then resetStack() end
end

local function onVehicleSpawned(gameVehicleID)
	if not active then return end
	veLoaded[gameVehicleID] = nil -- (re)spawning rebuilds the vehicle's Lua VM, resend MPPerformanceVE on the next instrument tick
	if veVehicles[gameVehicleID] then veVehicles[gameVehicleID].label = nil end
end

local function onVehicleDestroyed(gameVehicleID)
	veLoaded[gameVehicleID] = nil
	veVehicles[gameVehicleID] = nil
end

local function onExtensionUnloaded()
	hide()
end

M.show                = show
M.hide                = hide
M.toggle              = toggle
M.packetReceived      = packetReceived
M.packetSent          = packetSent
M.veReport            = veReport

M.onUpdate            = onUpdate
M.onPreRender         = onPreRender
M.onVehicleSpawned    = onVehicleSpawned
M.onVehicleDestroyed  = onVehicleDestroyed
M.onExtensionUnloaded = onExtensionUnloaded
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
