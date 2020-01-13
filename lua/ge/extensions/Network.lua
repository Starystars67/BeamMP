print("[BeamNG-MP] | Network loaded.")
--====================================================================================
-- All work by jojos38 & Titch2000.
-- You have no permission to edit, redistribute or upload. Contact us for more info!
--====================================================================================

local M = {}

-- ============= VARIABLES =============
local socket = require('socket')
local server
local TCPSocket
local connectionStatus = 0 -- Status: 0 not connected | 1 connecting | 2 connected
local serverTimeoutTimer = 0
local twoSecondsTimer = 2
local playersMap = {}
local nickname = ""
local serverPlayerID = ""
local sysTime = 0
local pingStatus = "ready"
local pingTimer = 0
local timeoutMax = 15 --TODO: SET THE TIMER TO 30 SECONDS
local timeoutWarn = 5 --TODO: SET THE TIMER TO 5 SECONDS ONCE WE ARE MORE STREAMLINED
local maxUpdateTimes = 10
-- ============= VARIABLES =============

local function println(stringToPrint)
	print("[BeamNG-MP] [TCP] | "..stringToPrint)
end

local function TCPSend(code, data)
	print("------------------------------------------------")
	print(code)
	print(data)
	print("------------------------------------------------")
	if connectionStatus == 2 then
		if data then
			return TCPSocket:send(code..data.."\n") -- Send data
		else
			return TCPSocket:send(code.."\n") -- Send data
		end
	end
end

--====================== DISCONNECT FROM SERVER ======================
local function disconnectFromServer()
	if connectionStatus > 0 then -- If player were connected
		--vehicleGE.onDisconnect() -- Clear vehicles list...
		--playersList.onDisconnect() -- Clear players list...
		TCPSend("2001") -- Send clientClose to server
		NetworkUDP.disconnectFromUDPServer();
		TCPSocket:close()-- Disconnect from server
		serverTimeoutTimer = 0 -- Reset timeout delay
		connectionStatus = 0
		pingStatus = "received"
		pingTimer = 0
		UI.setStatus("Disconnected")
		UI.disconnectMsgToChat()
	end
end
--====================== DISCONNECT FROM SERVER ======================



--============================================= ON CONNECTED ===============================================
local function onConnected() -- Function called only 1 time when client successfully connect to server
	UI.setStatus("Connected") -- TCP connected
	UI.sendGreetingToChat(Settings.IP, Settings.PORT)
	connectionStatus = 2
	println("Connected")
	TCPSend("USER"..Settings.Nickname) -- Send nickname to server
end
--============================================= ON CONNECTED ===============================================

local function SendChatMessage(message) -- Function called only 1 time when client successfully connect to server
	TCPSend("CHAT"..Settings.Nickname..': '..message) -- Send nickname to server
end

--======================================================================== ON PLAYER CONNECT ==========================================================================
local function onPlayerConnect() -- Function called when a player connect to the server
	updatesGE.onPlayerConnect()
end

local function JoinSession(ip, port)
	Settings.IP = ip
	Settings.PORT = port
  -- start onUpdate to allow pickup of data
  connectionStatus = 1
  UI.setStatus("Connecting...")
  TCPSocket = assert(socket.tcp()) -- Set socket to TCP
  TCPSocket:settimeout(0) -- Set timeout to 0 to avoid freezing
  -- establish connection
  TCPSocket:connect(ip, port); -- Connecting
  -- We now work in the onUpdate function and setup our UDP client
end

local updateTime = 0
local Times = {}

local function onUpdate(dt)
	local runTime = socket.gettime() -- Get update run time
	local uTime = (socket.gettime() - updateTime)*1000 -- Calculate time between send and receive
	local roundedUpdateTime = uTime + 0.5 - (uTime + 0.5) % 1 -- Round -- Get update cycle time
	table.insert(Times, roundedUpdateTime)

	if #Times > maxUpdateTimes then
		table.remove(Times, 1)
	end

	local sum = 0
	local averageUpdateTime = 0
	local elements = #Times

	for i = 1, elements do
	    sum = sum + Times[i]
	end

	averageUpdateTime = sum / elements
	averageUpdateTime = averageUpdateTime + 0.5 - (averageUpdateTime + 0.5) % 1 -- Round
	Debug.updateUI("updateTime", averageUpdateTime)

	-- Client Code
  if connectionStatus > 0 then -- If player is connecting or connected
		local received, status, partial = TCPSocket:receive() -- Receive data
		if received ~= "" and received ~= nil then -- If data have been received then
			--received =

			local packetLength = string.len(received)
			local code = string.sub(received, 1, 4)
			local containVehicleID = string.sub(code, 2, 2)
			local serverVehicleID = ""
			local data = ""

			if containVehicleID == "-" then
				serverVehicleID = string.sub(received, 5, 8)
				data = string.sub(received, 9, packetLength)
			else
				data = string.sub(received, 5, packetLength)
			end

			if code ~= "PONG" then
			  print("-----------------------------------------------------")
			  print("data :"..data)
			  print("code :"..code)
				print("serverVehicleID :"..serverVehicleID)
			  print("whole :"..received)

			  println("Data received! > Code: "..code.." > Data: "..data)
			end

			--==============================================================================

			if     code == "HOLA" then -- If server ready
				onConnected()
				Settings.PlayerID = data

			elseif code == "PONG" then -- Ping request
				UI.setStatus("Connected")
				serverTimeoutTimer = 0 -- Reset timeout timer

				local ping = (socket.gettime() - sysTime)*1000 -- Calculate time between send and receive
				local roundedPing = ping + 0.5 - (ping + 0.5) % 1 -- Round
				local roundedPing2 = roundedPing - averageUpdateTime
				if roundedPing2 < 0 then
					roundedPing2 = 0
				end
				UI.setPing(math.floor(roundedPing/roundedPing2)) -- Set the ping
				pingStatus = "ready" -- Ready for next ping

			elseif code == "PLST" then
				UI.error(data)
				UI.sendPlayerList(data)

			elseif code == "KICK" then -- Server kicked the player for any reason
				disconnectFromServer()
				UI.setStatus("Kicked ("..data..")")

			elseif code == "CHAT" then
				UI.updateChatLog(data)

			elseif code == "MAPC" then
				if data == getMissionFilename() then
					NetworkUDP.CreateClient(Settings.IP, Settings.PORT+1)
				else
					UI.message("Map check failed. Please use: "..data)
					disconnectFromServer()
					UI.setStatus("Kicked (Please use the correct map)")
				end

			elseif code == "MAPS" then
				local map = getMissionFilename()
				TCPSend("MAPS"..map)

			elseif code == "JOIN" then
				onPlayerConnect()

			elseif code == "1012" then -- Update connected players list
				playersList.setConnectedPlayers(jsonDecode(data)) -- Set connected players list

			--==============================================================================

		    elseif code == "U-VC" then -- Spawn vehicle and sync vehicle id or only sync vehicle ID
				vehicleGE.onServerVehicleSpawned(data)

			elseif code == "U-VR" then -- Server vehicle removed
				vehicleGE.onServerVehicleRemoved(serverVehicleID)

			--==============================================================================

			elseif code == "U-VI" then -- Update - Vehicle Inputs
				if data and serverVehicleID then
					inputsGE.applyInputs(data, serverVehicleID)
				end

			elseif code == "U-VE" then -- Update - Vehicle Electrics
				if data and serverVehicleID then
					electricsGE.applyElectrics(data, serverVehicleID)
				end

			elseif code == "U-VN" then -- Update - Vehicle Nodes
				if data and serverVehicleID then
					nodesGE.applyNodes(data, serverVehicleID)
				end

			elseif code == "U-VP" then -- Update - Vehicle Powertrain
				if data and serverVehicleID then
					powertrainGE.applyPowertrain(data, serverVehicleID)
				end

			elseif code == "U-VL" then -- Update - Vehicle Position / Location
				if data and serverVehicleID then
					positionGE.applyPos(data, serverVehicleID)
				end

			--elseif code == "U-VI" then -- Update - Vehicle Inputs
				--println("Veh update received")
				--Updates.HandleUpdate(received)
			else
				println("Data received unidentified! > Code: "..code.." > Data: "..tostring(data))
			end
			--==============================================================================
		end
--====================================================== DATA RECEIVE ======================================================



--===================================================== CHECK SERVER TIMEOUT =====================================================
		serverTimeoutTimer = serverTimeoutTimer + dt -- Time in seconds
		if serverTimeoutTimer > timeoutMax then -- If serverTimeoutTimer haven't been set to 0 for 15 seconds it mean the server is not answering
			if connectionStatus == 2 then -- If was connected to server then
				disconnectFromServer() -- Disconnect from server since it doesn't answer
				UI.setStatus("Connection lost") -- Connection have been lost
				println("Connection to server timed out after "..timeoutMax.." seconds")
			elseif connectionStatus == 1 then -- If was never connected to server
				disconnectFromServer() -- Cancel connection attempt to server since it doesn't answer
				UI.setStatus("Connection to server failed. Check IP / Port") -- Connection is impossible
				println("Connection to server failed. (Wrong IP / port / server closed on the target computer)")
			end
		end
		if serverTimeoutTimer > timeoutWarn and connectionStatus == 2 then -- If serverTimeoutTimer pass 7 seconds
			UI.setStatus("No answer... ("..serverTimeoutTimer..")", 0) -- Warning message
		end
--===================================================== CHECK SERVER TIMEOUT =====================================================

--================================ TWO SECONDS TIMER ================================
		twoSecondsTimer = twoSecondsTimer + dt -- Time in seconds
		if twoSecondsTimer > 2 then -- If twoSecondsTimer pass 2 seconds
			--TCPSend("BEAT") -- Still connected
			--twoSecondsTimer = 0	-- Reset timer
		end
--================================ TWO SECONDS TIMER ================================

	end
	if connectionStatus > 1 then
--================================ CHECK PING ================================

		pingTimer = pingTimer + dt
		if pingTimer > 2 and pingStatus == "ready" then -- Ping every 2 seconds
			pingStatus = "send" -- Set status to send
			pingTimer = 0
		end

		if pingStatus == "send" then -- Send the ping request
			--println("Ping Check Sent")
			TCPSend("PING")
			pingStatus = "wait" -- Wait for server answer
			sysTime = socket.gettime() -- Get send time
		end
--================================ CHECK PING ================================
	end
	-- ?????
	local rTime = (socket.gettime() - runTime)*1000 -- Calculate time between send and receive
	local roundedRunTime = rTime + 0.5 - (rTime + 0.5) % 1 -- Round
	Debug.updateUI("runTime", roundedRunTime)
	updateTime = socket.gettime()
end

--================================ Function return + Handling ================================

local function GetTCPStatus()
	return connectionStatus
end

M.onUpdate = onUpdate
M.JoinSession = JoinSession
M.TCPSend = TCPSend
M.SendChatMessage = SendChatMessage
M.disconnectFromServer = disconnectFromServer
M.connectionStatus = connectionStatus
M.GetTCPStatus = GetTCPStatus

return M
