function widget:GetInfo()
	return {
		name	= "Loony: Meteor Impact Interface",
		desc	= "UI for the Meteor Impacts gadget. Also does file I/O.",
		author  = "zoggop",
		date 	= "February 2015",
		license	= "whatever",
		layer 	= 0,
		enabled	= true
	}
end

local asciis = {}
local timers = {}
local meteor
local currentFile
local currentFilename
local currentReadFilename
local currentReadFile
local readLinesPerFrame = 1
local currentMeteors = {}
local bypassSpring = true
local renderType, renderProgress, renderTotal, renderRatio, renderBgRect, renderFgRect, renderRGB
local renderRatioRect = { x1 = 0.25, y1 = 0.49, x2 = 0.75, y2 = 0.51 }
local renderBgRGB = { r = 0, g = 0, b = 0.5, a = 0.5 }

local function StartTimer(thing)
	timers[thing] = Spring.GetTimer()
end

local function EndTimer(thing)
	if not timers[thing] then return end
	Spring.Echo(string.format(thing .. " in " .. math.ceil(Spring.DiffTimers(Spring.GetTimer(), timers[thing], true)) .. "ms"))
	timers[thing] = nil
end

local function EndTimers()
	for thing, clock in pairs(timers) do
 		Spring.Echo(string.format(thing .. " in " .. math.ceil(Spring.DiffTimers(Spring.GetTimer(), clock, true)) .. "ms"))
 	end
 	timers = {}
end

local function LoonyCommand(command, alreadyLoony)
	local msg = command
	if not alreadyLoony then msg = "loony " .. msg end
	local timerCmd = command
	if alreadyLoony then timerCmd = timerCmd:sub(7) end
	StartTimer(timerCmd)
	Spring.SendLuaGaiaMsg(msg)
end

local function ascii(char)
	asciis[char] = asciis[char] or string.byte(char)
	return asciis[char]
end

local function splitIntoWords(s)
  local words = {}
  for w in s:gmatch("%S+") do table.insert(words, w) end
  return words
end

local function GlRectXYXY(rect)
	gl.Rect(rect.x1, rect.y1, rect.x2, rect.y2)
end

local function GlColorRGB(rgba)
	gl.Color(rgba.r, rgba.g, rgba.b, rgba.a or 1)
end

local function GetMouseGroundPosition()
	local x, y = Spring.GetMouseState()
	local thing, stuff = Spring.TraceScreenRay(x, y)
	if thing == "ground" then
		local gx, gy, gz = math.floor(stuff[1]), math.floor(stuff[2]), math.floor(stuff[3])
		return gx, gy, gz
	end
end

local function BeginMeteor()
	local x, y, z = GetMouseGroundPosition()
	if x then meteor = {x = x, y = y, z = z, radius = 0} end
end

local function EndMeteor()
	if meteor then
		LoonyCommand("meteor " .. meteor.x .. " " .. meteor.z .. " " .. meteor.radius)
		meteor = nil
	end
end

local function ReceiveBeginFile(name, ext, mode)
	name = name or ""
	ext = ext or "txt"
	mode = mode or "wb"
	currentFilename = (string.lower(string.gsub(Game.mapName, ".smf", "_")) .. name .. "." .. ext)
	currentFile = assert(io.open(currentFilename,mode), "Unable to save to "..currentFilename)
end

local function ReceivePieceFile(dataString)
	currentFile:write(dataString)
end

local function ReceiveEndFile()
	currentFile:close()
	Spring.Echo(currentFilename .. " written")
end

local function ReceiveReadFile(name, ext)
	name = name or ""
	ext = ext or "txt"
	currentReadFilename = (string.lower(string.gsub(Game.mapName, ".smf", "_")) .. name .. "." .. ext)
	Spring.Echo("reading from " .. currentReadFilename)
	currentReadFile = assert(io.open(currentReadFilename,"r"), "Unable to read from "..currentReadFilename)
end

local function ReceiveMeteor(sx, sz, diameterImpactor, velocityImpactKm, angleImpact, densityImpactor, age, craterRadius, metal, geothermal)
	local m = { x = sx, z = sz, diameterImpactor = diameterImpactor, velocityImpactKm = velocityImpactKm, angleImpact = angleImpact, densityImpactor = densityImpactor, age = age, craterRadius = craterRadius, metal = metal, geothermal = geothermal, y = Spring.GetGroundHeight(sx, sz), rgb = { 0, 1-(age/100), age/100 } }
	table.insert(currentMeteors, m)
end

local function ReceiveBypassSpring(stateString)
	if stateString == "true" then
		bypassSpring = true
	elseif stateString == "false" then
		bypassSpring = false
	end
end

local function ReceiveClearMeteors()
	currentMeteors = {}
end

local function ReceiveCompleteCommand(command)
	EndTimer(command)
end

local function ReceiveRenderStatus(rt, progress, total)
	renderType = rt
	if renderType and renderType ~= "none" then
		renderProgress = progress
		renderTotal = total
		renderRatio = progress / total
		renderRGB = { r = 1-renderRatio, g = renderRatio, b = 0 }
		renderProgressString = tostring(math.floor(renderRatio * 100)) .. "%" --renderProgress .. "/" .. renderTotal
		local viewX, viewY, posX, posY = Spring.GetViewGeometry()
		local rrr = renderRatioRect
		local x1, y1 = rrr.x1*viewX, rrr.y1*viewY
		local x2, y2 = rrr.x2*viewX, rrr.y2*viewY
		local dx = x2 - x1
		renderBgRect = { x1 = x1-4, y1 = y1-4, x2 = x2+4, y2 = y2+4 }
		renderFgRect = { x1 = x1, y1 = y1, x2 = x1+(dx*renderRatio), y2 = y2 }
	else
		renderType = nil
	end
end

function widget:Initialize()
	widgetHandler:RegisterGlobal("ReceiveBeginFile", ReceiveBeginFile)
	widgetHandler:RegisterGlobal("ReceivePieceFile", ReceivePieceFile)
	widgetHandler:RegisterGlobal("ReceiveEndFile", ReceiveEndFile)
	widgetHandler:RegisterGlobal("ReceiveReadFile", ReceiveReadFile)
	widgetHandler:RegisterGlobal("ReceiveMeteor", ReceiveMeteor)
	widgetHandler:RegisterGlobal("ReceiveBypassSpring", ReceiveBypassSpring)
	widgetHandler:RegisterGlobal("ReceiveClearMeteors", ReceiveClearMeteors)
	widgetHandler:RegisterGlobal("ReceiveCompleteCommand", ReceiveCompleteCommand)
	widgetHandler:RegisterGlobal("ReceiveRenderStatus", ReceiveRenderStatus)
end

function widget:KeyPress(key, mods, isRepeat)
	if isRepeat == false then
		if key == ascii(".") then
			BeginMeteor()
		elseif key == ascii("b") then
			LoonyCommand("blur")
		elseif key == ascii("/") then
			LoonyCommand("clear")
		elseif key == ascii("r") then
			LoonyCommand("read")
		elseif key == ascii("\\") then
			LoonyCommand("bypasstoggle")
		elseif key == ascii("=") then
			LoonyCommand("mirrornext")
		elseif key == ascii("a") then
			LoonyCommand("attributes")
		elseif key == ascii("h") then
			LoonyCommand("height")
		elseif key == ascii("h") then
			LoonyCommand("metal")
		elseif key == ascii("m") then
			LoonyCommand("underlyingmaretoggle")
		elseif key == ascii("s") then
			LoonyCommand("save")
		elseif key == ascii("l") then
			LoonyCommand("load")
		end
	end
end

function widget:KeyRelease(key)
	if key == ascii(".") then
		EndMeteor()
	end
end

function widget:GameFrame(frame)
	if currentReadFilename then
		local packet = ""
		for i = 1, readLinesPerFrame do
			local line = currentReadFile:read()
			if line then
				packet = packet .. line
				if i ~= readLinesPerFrame then packet = packet .. "\n" end
			else
				currentReadFile:close()
				Spring.SendLuaGaiaMsg("loony fileend")
				currentReadFile = nil
				currentReadFilename = nil
				break
			end
		end
		Spring.SendLuaGaiaMsg("loony fileline " .. packet)
	end
end

function widget:Update()
	if meteor then
		local x, y, z = GetMouseGroundPosition()
		if x then
			local dx, dz = x - meteor.x, z - meteor.z
			meteor.radius = math.sqrt( (dx*dx) + (dz*dz) )
		end
	end
end

function widget:DrawWorld()
	if not meteor and (#currentMeteors == 0 or not bypassSpring) then return end
	gl.DepthTest(false)
	gl.PushMatrix()
	if meteor then
		gl.LineWidth(3)
		gl.Color(1, 0, 0, 1)
		gl.DrawGroundCircle(meteor.x, meteor.y, meteor.z, meteor.radius, 8)
	end
	if #currentMeteors > 0 and bypassSpring then
		for i, m in pairs(currentMeteors) do
			gl.LineWidth(2)
			gl.Color(m.rgb[1], m.rgb[2], m.rgb[3], 1)
			gl.DrawGroundCircle(m.x, m.y, m.z, m.craterRadius, 8)
			if m.metal then
				gl.Color(0, 1, 1)
				gl.LineWidth(8)
				gl.DrawGroundCircle(m.x, m.y, m.z, 8, 4)
			end
			if m.geothermal then
				gl.Color(1, 1, 0)
				gl.LineWidth(8)
				gl.DrawGroundCircle(m.x, m.y, m.z, 32, 3)
			end
		end
	end
	gl.LineWidth(1)
	gl.Color(1, 1, 1, 0.5)
	gl.PopMatrix()
	gl.DepthTest(true)
end

function widget:DrawScreen()
	if renderType then
		GlColorRGB(renderBgRGB)
		GlRectXYXY(renderBgRect)
		GlColorRGB(renderRGB)
		GlRectXYXY(renderFgRect)
		gl.Color(1, 1, 1, 0.5)
		gl.Text(renderType, renderBgRect.x2, renderBgRect.y2, 20, "rdo")
		gl.Text(renderProgressString, renderBgRect.x2, renderBgRect.y1, 16, "rao")
	end
end

function widget:TextCommand(command)
	if (string.find(command, 'loony') == 1) then
		LoonyCommand(command, true)
	end
end