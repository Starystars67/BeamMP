-- Copyright (C) 2024 BeamMP Ltd., BeamMP team and contributors.
-- Licensed under AGPL-3.0 (or later), see <https://www.gnu.org/licenses/>.
-- SPDX-License-Identifier: AGPL-3.0-or-later

--- MPPerformanceVE API.
--- Vehicle side of the BeamMP performance graph (MPPerformanceGraph in GE).
--- Only loaded while the performance window is open, it's deliberately not in the BeamMP folder so it doesn't auto load.
--- Times the BeamMP VE extensions of this vehicle, optionally counts the garbage they create (the same way the game's
--- gcprobe() does it) and reports the per frame averages back to GE a few times a second.
--- @module MPPerformanceVE
--- @usage MPPerformanceVE.start({"positionVE", "MPInputsVE"}, false) -- sent by MPPerformanceGraph, not meant to be called by hand

local M = {}

local REPORT_INTERVAL = 0.25 -- seconds between reports to GE
local RESCAN_INTERVAL = 2    -- seconds between checks for BeamMP extensions that loaded after us

local clockhp = os.clockhp
local collect = collectgarbage

local moduleNames = {} -- set by GE, the report is in the same order
local trackGarbage = false

local wrapped = {} -- [moduleIndex] = { tbl = moduleTable, fns = { [name] = { orig, wrapper } } }
local selfTime, selfBytes, calls = {}, {}, {}
local depth = 0
local startAt, childTime, startBytes, childBytes = {}, {}, {}, {}
local gcStopped = false

local frames = 0
local lastReport, lastRescan = 0, 0
local report = {} -- reused, flat { ms, calls, KB } per module


-------------------------------------------------------------------------------
-- Instrumentation
-------------------------------------------------------------------------------

-- Wraps a module function so its self time (time not spent in other wrapped functions) is added to module i.
local function makeWrapper(i, fn)
	local function leave(...)
		if depth < 1 then return ... end -- stack was reset after an error in a wrapped call, drop this sample
		local elapsed = clockhp() - startAt[depth]
		selfTime[i] = selfTime[i] + elapsed - childTime[depth]
		depth = depth - 1
		if depth > 0 then childTime[depth] = childTime[depth] + elapsed end
		return ...
	end
	return function(...)
		depth = depth + 1
		calls[i] = calls[i] + 1
		childTime[depth], childBytes[depth] = 0, 0 -- both, a garbage wrapper can end up nested inside this one right after toggling
		startAt[depth] = clockhp()
		return leave(fn(...))
	end
end

-- Same as makeWrapper but also counts the garbage created. Like gcprobe() the GC is stopped while we measure,
-- otherwise a GC step inside the call frees memory and collectgarbage("count") goes down. It's only stopped
-- for the outermost wrapped call so nested calls don't restart it early.
local function makeGcWrapper(i, fn)
	local function leave(...)
		if depth < 1 then return ... end
		local elapsed = clockhp() - startAt[depth]
		local kb = collect("count") - startBytes[depth]
		selfTime[i] = selfTime[i] + elapsed - childTime[depth]
		selfBytes[i] = selfBytes[i] + kb - childBytes[depth]
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
		calls[i] = calls[i] + 1
		childTime[depth], childBytes[depth] = 0, 0
		startBytes[depth] = collect("count")
		startAt[depth] = clockhp()
		return leave(fn(...))
	end
end

local function resetStack()
	depth = 0
	if gcStopped then -- never leave the GC stopped
		gcStopped = false
		collect("restart")
	end
end

local function wrap()
	local make = trackGarbage and makeGcWrapper or makeWrapper
	for i, name in ipairs(moduleNames) do
		local tbl = extensions.isExtensionLoaded(name) and extensions[name] or nil
		if tbl and not (wrapped[i] and wrapped[i].tbl == tbl) then
			local w = { tbl = tbl, fns = {} }
			for fname, fn in pairs(tbl) do
				if type(fn) == "function" and fn ~= nop and fname:sub(1, 2) ~= "__" then
					w.fns[fname] = { orig = fn, wrapper = make(i, fn) }
				end
			end
			for fname, f in pairs(w.fns) do
				tbl[fname] = f.wrapper
				extensions.hookUpdate(fname) -- VE hooks aren't all "on..." (updateGFX), so refresh every name
			end
			wrapped[i] = w
		end
	end
end

local function unwrap()
	for _, w in pairs(wrapped) do
		for fname, f in pairs(w.fns) do
			if w.tbl[fname] == f.wrapper then w.tbl[fname] = f.orig end -- leave it alone if the module replaced it itself
			extensions.hookUpdate(fname)
		end
	end
	wrapped = {}
	resetStack()
end

local function resetCounters()
	for i = 1, #moduleNames do selfTime[i], selfBytes[i], calls[i] = 0, 0, 0 end
	frames = 0
end


-------------------------------------------------------------------------------
-- Public
-------------------------------------------------------------------------------

--- Starts measuring the given BeamMP VE extensions. Called by MPPerformanceGraph when the window opens.
-- @tparam table names extension names, reports are sent in this order
-- @tparam boolean garbage also count garbage (gcprobe style)
local function start(names, garbage)
	unwrap()
	moduleNames = names
	trackGarbage = garbage and true or false
	resetCounters()
	wrap()
	lastReport, lastRescan = clockhp(), clockhp()
end

--- Turns garbage counting on or off, re-wrapping with the matching wrapper.
-- @tparam boolean garbage
local function setTrackGarbage(garbage)
	garbage = garbage and true or false
	if garbage == trackGarbage then return end
	unwrap()
	trackGarbage = garbage
	resetCounters()
	wrap()
end

local function updateGFX()
	if depth ~= 0 then resetStack() end -- a wrapped call errored and never returned
	if #moduleNames == 0 then return end -- not started by GE yet
	frames = frames + 1

	local now = clockhp() -- wall clock, dtSim is 0 while paused
	if now - lastRescan >= RESCAN_INTERVAL then
		lastRescan = now
		wrap()
	end
	if now - lastReport < REPORT_INTERVAL then return end
	lastReport = now

	local n = 0
	for i = 1, #moduleNames do
		report[n + 1] = selfTime[i] * 1000 / frames -- ms per frame
		report[n + 2] = calls[i] / frames
		report[n + 3] = selfBytes[i] / frames -- KB per frame
		n = n + 3
	end
	obj:queueGameEngineLua(string.format("MPPerformanceGraph.veReport(%d,%d,{%s})", obj:getID(), frames, table.concat(report, ",", 1, n)))
	resetCounters()
end

-- the game reloads a vehicle's extensions itself when the vehicle is reloaded (e.g. a config edit), keep our settings
-- so we carry on straight away instead of sitting there unstarted until GE sends start() again
local function onSerialize()
	return { names = moduleNames, garbage = trackGarbage }
end

local function onExtensionLoaded(data)
	if type(data) == "table" and type(data.names) == "table" and #data.names > 0 then start(data.names, data.garbage) end
end

local function onExtensionUnloaded()
	unwrap()
end


M.start               = start
M.setTrackGarbage     = setTrackGarbage
M.updateGFX           = updateGFX
M.onSerialize         = onSerialize
M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

return M
