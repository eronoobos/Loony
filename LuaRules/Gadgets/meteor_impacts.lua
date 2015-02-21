function gadget:GetInfo()
  return {
    name      = "Loony: Meteor Impacts",
    desc      = "Generates a new heightmap of meteor impact craters.",
    author    = "zoggop",
    date      = "January 2015",
    license   = "whatever",
    layer     = -3,
    enabled   = true
   }
end

include("LuaLib/perlin.lua")

-- localization:

local pi = math.pi
local twicePi = math.pi * 2
local piHalf = math.pi / 2
local piEighth = math.pi / 8
local piTwelfth = math.pi / 12
local piSixteenth = math.pi / 16
local atan2 = math.atan2
local twoSqrtTwo = 2 * math.sqrt(2)
local naturalE = math.exp(1)
local function mod(one, two)
  return one % two
end

local tInsert = table.insert
local tRemove = table.remove

local spSetHeightMapFunc = Spring.SetHeightMapFunc
local spAdjustHeightMap = Spring.AdjustHeightMap
local radiansPerAngle = math.pi / 180

local myWorld
local bypassSpring = false
local commandsWaiting = {}
local heightMapRuler

local diffDistances = {}
local diffDistancesSq = {}
local sqrts = {}
local gaussians = {}
local angles = {}

local le = {}

-- common functions:

do
  function le.uint32(n)
    return string.char( mod(n,256), mod(n,65536)/256, mod(n, 16777216)/65536,n/16777216 )
  end

  function le.uint16(n)
    return string.char( mod(n,256), mod(n,65536)/256 )
  end

  function le.uint16rev(n)
    return string.char( mod(n,65536)/256, mod(n,256) )
  end

  function le.uint8(n)
    return string.char( mod(n,256) )
  end
end

local function sqrt(number)
  sqrts[number] = sqrts[number] or math.sqrt(number)
  return sqrts[number]
end

local function MinMaxRandom(minimum, maximum)
  return (math.random() * (maximum - minimum)) + minimum
end

local function AngleDXDY(dx, dy)
  angles[dx] = angles[dx] or {}
  angles[dx][dy] = angles[dx][dy] or atan2(dy, dx)
  return angles[dx][dy]
end

local function AngleAdd(angle1, angle2)
  local angle = angle1 + angle2
  if angle > pi then angle = angle - twicePi end
  if angle < -pi then angle = angle + twicePi end
  return angle
end

local function tDuplicate(sourceTable)
  local duplicate = {}
  for k, v in pairs(sourceTable) do
    tInsert(duplicate, v)
  end
  return duplicate
end

local function tRemoveRandom(fromTable)
  return tRemove(fromTable, mRandom(1, #fromTable))
end

local function splitIntoWords(s)
  local words = {}
  for w in s:gmatch("%S+") do table.insert(words, w) end
  return words
end

local function XZtoXY(x, z)
  local y = (Game.mapSizeZ - z)
  return x+1, y+1
end

local function XZtoHXHY(x, z)
  local hx = math.floor(x / Game.squareSize) + 1
  local hy = math.floor((Game.mapSizeZ - z) / Game.squareSize) + 1
  return hx, hy
end

local function Gaussian(x, c)
  gaussians[x] = gaussians[x] or {}
  gaussians[x][c] = gaussians[x][c] or math.exp(  -( (x^2) / (2*(c^2)) )  )
  return gaussians[x][c]
end

function pairsByKeys (t, f)
  local a = {}
  for n in pairs(t) do table.insert(a, n) end
  table.sort(a, f)
  local i = 0      -- iterator variable
  local iter = function ()   -- iterator function
    i = i + 1
    if a[i] == nil then return nil
    else return a[i], t[a[i]]
    end
  end
  return iter
end

local function BeginCommand(command)
  table.insert(commandsWaiting, command)
end

local function EndCommands()
  for i, command in pairs(commandsWaiting) do
    SendToUnsynced("CompleteCommand", command)
  end
end

------------------------------------------------------------------------------

local AttributeDict = {
  [0] = { name = "None", rgb = {0,0,0} },
  [1] = { name = "Breccia", rgb = {255,255,255} },
  [2] = { name = "InnerRim", rgb = {0,255,0} },
  [3] = { name = "EjectaBlanket", rgb = {0,255,255} },
  [4] = { name = "Melt", rgb = {255,0,0} },
  [5] = { name = "ThinEjecta", rgb = {0,0,255} },
  [6] = { name = "Ray", rgb = {255,255,0} },
}

local AttributesByName = {}
for i, entry in pairs(AttributeDict) do
  local aRGB = entry.rgb
  local r = string.char(aRGB[1])
  local g = string.char(aRGB[2])
  local b = string.char(aRGB[3])
  local threechars = r .. g .. b
  AttributeDict[i].threechars = threechars
  AttributesByName[entry.name] = { index = i, rgb = aRGB, threechars = threechars}
end

------------------------------------------------------------------------------

-- Compatible with Lua 5.1 (not 5.0).
function class(base, init)
   local c = {}    -- a new class instance
   if not init and type(base) == 'function' then
      init = base
      base = nil
   elseif type(base) == 'table' then
    -- our new class is a shallow copy of the base class!
      for i,v in pairs(base) do
         c[i] = v
      end
      c._base = base
   end
   -- the class will be the metatable for all its objects,
   -- and they will look up their methods in it.
   c.__index = c

   -- expose a constructor which can be called by <classname>(<args>)
   local mt = {}
   mt.__call = function(class_tbl, ...)
   local obj = {}
   setmetatable(obj,c)
   if init then
      init(obj,...)
   else 
      -- make sure that any stuff from the base class is initialized!
      if base and base.init then
      base.init(obj, ...)
      end
   end
   return obj
   end
   c.init = init
   c.is_a = function(self, klass)
      local m = getmetatable(self)
      while m do 
         if m == klass then return true end
         m = m._base
      end
      return false
   end
   setmetatable(c, mt)
   return c
end

------------------------------------------------------------------------------

-- classes: ------------------------------------------------------------------

World = class(function(a, metersPerElmo, baselevel, gravity, density)
  a.metersPerElmo = metersPerElmo or 1 -- meters per elmo for meteor simulation model only
  a.metersPerSquare = a.metersPerElmo * Game.squareSize
  Spring.Echo(a.metersPerElmo, a.metersPerSquare)
  a.baselevel = baselevel or 0
  a.gravity = gravity or (Game.gravity / 130) * 9.8
  a.density = density or (Game.mapHardness / 100) * 1500
  a.complexDiameter = 3200 / (a.gravity / 9.8)
 
  heightMapRuler = heightMapRuler or MapRuler(nil, (Game.mapSizeX / Game.squareSize) + 1, (Game.mapSizeZ / Game.squareSize) + 1)
  a.hei = HeightBuffer(a, heightMapRuler)
  a.meteors = {}
  a.renderers = {}
  SendToUnsynced("ClearMeteors")
end)

MapRuler = class(function(a, elmosPerPixel, width, height)
  elmosPerPixel = elmosPerPixel or Game.mapSizeX / width
  width = width or math.ceil(Game.mapSizeX / elmosPerPixel)
  height = height or math.ceil(Game.mapSizeZ / elmosPerPixel)
  a.elmosPerPixel = elmosPerPixel
  a.width = width
  a.height = height
end)

HeightBuffer = class(function(a, world, mapRuler)
  a.world = world
  a.mapRuler = mapRuler
  a.elmosPerPixel = mapRuler.elmosPerPixel
  a.w, a.h = mapRuler.width, mapRuler.height
  a.heights = {}
  for x = 1, a.w do
    a.heights[x] = {}
    for y = 1, a.h do
      a.heights[x][y] = 0
    end
  end
  a.maxHeight = 0
  a.minHeight = 0
  a.directToSpring = false
  Spring.Echo("new height buffer created", a.w, " by ", a.h)
end)

Renderer = class(function(a, world, mapRuler, pixelsPerFrame, renderType, heightBuf, noCraters)
  a.world = world
  a.mapRuler = mapRuler
  a.pixelsPerFrame = pixelsPerFrame
  a.renderType = renderType
  a.heightBuf = heightBuf
  a.craters = {}
  a.totalcraterarea = 0
  if not noCraters then
    for i, m in ipairs(world.meteors) do
      local crater = Crater(m, a)
      table.insert(a.craters, crater)
      a.totalcraterarea = a.totalcraterarea + crater.area
    end
  end
  a.pixelsRendered = 0
  a.pixelsToRenderCount = mapRuler.width * mapRuler.height
  a.totalPixels = a.pixelsToRenderCount+0
  if renderType == "attributes" then
    SendToUnsynced("BeginPGM", "attrib")
    SendToUnsynced("PiecePGM", "P6 " .. tostring(mapRuler.width) .. " " .. tostring(mapRuler.height) .. " 255 ")
  elseif renderType == "heightimage" then
    SendToUnsynced("BeginPGM", "height")
    SendToUnsynced("PiecePGM", "P5 " .. tostring(mapRuler.width) .. " " .. tostring(mapRuler.height) .. " " .. 65535 .. " ")
  end
  if renderType == "heightprespring" then
    a.totalProgress = a.totalcraterarea
  else
    a.totalProgress = a.totalPixels
  end
end)

-- Crater actually gets rendered. scales horizontal distances to the frame being rendered
Crater = class(function(a, meteor, renderer)
  local elmosPerPixel = renderer.mapRuler.elmosPerPixel
  a.meteor = meteor
  a.renderer = renderer
  a.x, a.y = renderer.mapRuler:XZtoXY(meteor.sx, meteor.sz)
  a.radius = meteor.craterRadius / elmosPerPixel
  a.falloff = meteor.craterRadius * 1.5 / elmosPerPixel
  a.peakC = (a.radius / 8) ^ 2

  a.totalradius = a.radius + a.falloff
  a.totalradiusSq = a.totalradius * a.totalradius
  a.xmin, a.xmax, a.ymin, a.ymax = renderer.mapRuler:RadiusBounds(a.x, a.y, a.totalradius*(1+meteor.distWobbleAmount))
  a.radiusSq = a.radius * a.radius
  a.falloffSq = a.totalradiusSq - a.radiusSq
  a.falloffSqHalf = a.falloffSq / 2
  a.falloffSqFourth = a.falloffSq / 4
  a.brecciaRadiusSq = (a.radius * 0.85) ^ 2
  a.blastRadiusSq = (a.totalradius * 4) ^ 2

  a.width = a.xmax - a.xmin
  a.height = a.ymax - a.ymin
  a.area = a.width * a.height
  a.currentPixel = 0
  -- a.ageNoise = TwoDimensionalNoise(a.width, meteor.ageRatio, a.width)
  -- perlin2D(seed, width, height, persistence, N, amplitude)
  -- a.ageNoise = perlin2D(a.radius+a.x+a.y, a.width+1, a.height+1, 0.25, 6, 0.5)
end)

-- Meteor stores data and does meteor impact model calculations
Meteor = class(function(a, world, sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  -- coordinates sx and sz and diameterSpring are in spring coordinates (elmos)
  a.world = world
  a.sx, a.sz = math.floor(sx), math.floor(sz)
  a.x, a.y = XZtoXY(a.sx, a.sz)
  a.hx, a.hy = XZtoHXHY(a.sx, a.sz)

  a.distWobbleAmount = MinMaxRandom(0.08, 0.18)
  a.heightWobbleAmount = MinMaxRandom(0.1, 0.4)
  a.rayWobbleAmount = MinMaxRandom(0.33, 0.67)
  a.distNoise = WrapNoise(32, a.distWobbleAmount)
  a.rayNoise = WrapNoise(24, a.rayWobbleAmount)
  a.heightNoise = WrapNoise(16, a.heightWobbleAmount)
  a.blastNoise = WrapNoise(48, 0.66)

  local diameterImpactor = diameterSpring * world.metersPerElmo
  a.diameterImpactor = diameterImpactor or 500
  a.velocityImpact = velocityImpact or 70
  a.angleImpact = angleImpact or 90
  a.densityImpactor = densityImpactor or 8000
  a.age = age or 0
  a.ageRatio = a.age / 100

  a.angleImpactRadians = a.angleImpact * radiansPerAngle
  a.diameterTransient = 1.161 * ((a.densityImpactor / world.density) ^ 0.33) * (a.diameterImpactor ^ 0.78) * (a.velocityImpact ^ 0.44) * (world.gravity ^ -0.22) * (math.sin(a.angleImpactRadians) ^ 0.33)
  a.diameterSimple = a.diameterTransient * 1.25
  a.diameterComplex = 1.17 * ((a.diameterTransient ^ 1.13) / (world.complexDiameter ^ 0.13))
  a.depthTransient = a.diameterTransient / twoSqrtTwo
  a.rimHeightTransient = a.diameterTransient / 14.1
  a.rimHeightSimple = 0.07 * ((a.diameterTransient ^ 4) / (a.diameterSimple ^ 3))
  a.brecciaVolume = 0.032 * (a.diameterSimple ^ 3)
  a.brecciaDepth = 2.8 * a.brecciaVolume * ((a.depthTransient + a.rimHeightTransient) / (a.depthTransient * a.diameterSimple * a.diameterSimple))
  a.depthSimple = a.depthTransient - a.brecciaDepth
  a.depthComplex = 0.4 * (a.diameterSimple ^ 0.3)

  a.simpleComplex = math.min(1 + (a.diameterSimple / world.complexDiameter), 3)
  local simpleMult = 3 - a.simpleComplex
  local complexMult  = a.simpleComplex - 1
  a.craterRadius = (a.diameterSimple / 2) / world.metersPerElmo
  a.craterFalloff = a.craterRadius * 0.66
  local depthSimpleAdd = a.depthSimple * simpleMult
  local depthComplexAdd = a.depthComplex * complexMult
  local depth = (depthSimpleAdd + depthComplexAdd) / (simpleMult + complexMult)

  a.energyImpact = piTwelfth * a.densityImpactor * (a.diameterImpactor ^ 3) * (a.velocityImpact ^ 2)
  a.meltVolume = 8.9 * 10^(-12) * a.energyImpact * math.sin(a.angleImpactRadians)
  a.meltThickness = (4 * a.meltVolume) / (pi * (a.diameterTransient ^ 2))

  a.craterMeltThickness = a.meltThickness / world.metersPerElmo
  a.craterDepth = ((depth + a.rimHeightSimple)  ) / world.metersPerElmo
  a.craterRimHeight = a.rimHeightSimple / world.metersPerElmo
  a.craterPeakHeight = (a.simpleComplex - 2) * a.craterDepth
  a.rayWidth = 0.01 -- in radians
  a.rayHeight = (a.craterRimHeight / 3) * simpleMult
  a.meltSurface = a.craterRimHeight + a.craterMeltThickness - a.craterDepth
  -- Spring.Echo(a.meltThickness, a.meltVolume, a.energyImpact)
end)

WrapNoise = class(function(a, length, intensity, persistence, N, amplitude)
  a.values = {}
  a.outValues = {}
  a.absMaxValue = 0
  a.angleDivisor = twicePi / length
  a.length = length
  a.intensity = intensity or 1
  a.halfLength = length / 2
  persistence = persistence or 0.25
  N = N or 6
  amplitude = amplitude or 0.5
  local radius = math.ceil(length / pi)
  local diameter = radius * 2
  local seed = math.floor(math.random()*length*1000)
  local yx = perlin2D( seed, diameter+1, diameter+1, persistence, N, amplitude )
  local i = 1
  local angleIncrement = twicePi / length
  a.valuesByAngle = {}
  for angle = -pi, pi, angleIncrement do
    local x = math.floor(radius + (radius * math.cos(angle))) + 1
    local y = math.floor(radius + (radius * math.sin(angle))) + 1
    local val = yx[y][x]
    if math.abs(val) > a.absMaxValue then a.absMaxValue = math.abs(val) end
    a.values[i] = val
    a.valuesByAngle[angle] = val
    i = i + 1
  end
  for n, v in ipairs(a.values) do
    a.outValues[n] = (v / a.absMaxValue) * a.intensity
  end
end)

TwoDimensionalNoise = class(function(a, sideLength, intensity, realSideLength)
  a.sideLength = sideLength
  a.realSideLength = realSideLength
  a.conversion = realSideLength / sideLength
  a.xNoise = WrapNoise(sideLength, intensity, true)
  a.yNoise = WrapNoise(sideLength, intensity, true)
end)

-- end classes ---------------------------------------------------------------

-- class methods: ------------------------------------------------------------

function World:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity)
  number = number or 3
  minDiameter = minDiameter or 5
  maxDiameter = maxDiameter or 5000
  minVelocity = minVelocity or 15
  maxVelocity = maxVelocity or 110
  minDiameter = minDiameter^0.01
  maxDiameter = maxDiameter^0.01
  minAngle = minAngle or 10
  maxAngle = maxAngle or 80
  minDensity = minDensity or 4000
  maxDensity = maxDensity or 12000
  local hundredConv = 100 / number
  for n = 1, number do
    local diameter = MinMaxRandom(minDiameter, maxDiameter)^100
    Spring.Echo(diameter)
    local velocity = MinMaxRandom(minVelocity, maxVelocity)
    local angle = MinMaxRandom(minAngle, maxAngle)
    local density = MinMaxRandom(minDensity, maxDensity)
    local x = math.floor(math.random() * Game.mapSizeX)
    local z = math.floor(math.random() * Game.mapSizeZ)
    self:AddMeteor(x, z, diameter, velocity, angle, density, math.floor((number-n)*hundredConv))
  end
end

function World:AddMeteor(sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  local m = Meteor(self, sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  table.insert(self.meteors, m)
  SendToUnsynced("Meteor", sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
end

function World:RenderHeightSpring()
  self.hei:Clear()
  local renderer = Renderer(self, heightMapRuler, 4000, "heightprespring", self.hei)
  table.insert(self.renderers, renderer)
end

function World:RenderAttributes(elmosPerPixel)
  local renderer = Renderer(self, heightMapRuler, 8000, "attributes")
  table.insert(self.renderers, renderer)
end

--------------------------------------

function MapRuler:XZtoXY(x, z)
  if self.elmosPerPixel == 1 then
    return x+1, (Game.mapSizeZ - z)+1
  else
    local hx = math.floor(x / self.elmosPerPixel) + 1
    local hy = math.floor((Game.mapSizeZ - z) / self.elmosPerPixel) + 1
    return hx, hy
  end
end

function MapRuler:XYtoXZ(x, y)
  if self.elmosPerPixel == 1 then
    return x-1, (Game.mapSizeZ - (y-1))
  else
    local sx = math.floor((x-1) * self.elmosPerPixel)
    local sz = math.floor(Game.mapSizeZ - ((y-1) * self.elmosPerPixel))
    return sx, sz
  end
end

function MapRuler:RadiusBounds(x, y, radius)
  local w, h = self.width, self.height
  local xmin = math.floor(x - radius)
  local xmax = math.ceil(x + radius)
  local ymin = math.floor(y - radius)
  local ymax = math.ceil(y + radius)
  if xmin < 1 then xmin = 1 end
  if xmax > w then xmax = w end
  if ymin < 1 then ymin = 1 end
  if ymax > h then ymax = h end
  return xmin, xmax, ymin, ymax
end

--------------------------------------

function HeightBuffer:CoordsOkay(x, y)
  if not self.heights[x] then
    -- Spring.Echo("no row at ", x)
    return
  end
  if not self.heights[x][y] then
    -- Spring.Echo("no pixel at ", x, y)
    return
  end
  return true
end

function HeightBuffer:MinMaxCheck(height)
  if height > self.maxHeight then self.maxHeight = height end
  if height < self.minHeight then self.minHeight = height end
end

function HeightBuffer:Write(x, y, height)
  if not self.directToSpring then return end
  local sx, sz = self.mapRuler:XYtoXZ(x, y)
  Spring.LevelHeightMap(sx, sz, sx+8, sz-8, self.world.baselevel+height)
end

function HeightBuffer:Add(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  local newHeight = self.heights[x][y] + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
  self:Write(x, y, newHeight)
end

function HeightBuffer:Blend(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  local orig = 1 - alpha
  local newHeight = (self.heights[x][y] * orig) + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
  self:Write(x, y, newHeight)
end

function HeightBuffer:Set(x, y, height)
  if not self:CoordsOkay(x, y) then return end
  self.heights[x][y] = height
  self:MinMaxCheck(height)
  self:Write(x, y, height)
end

function HeightBuffer:Get(x, y)
  if not self:CoordsOkay(x, y) then return end
  return self.heights[x][y]
end

function HeightBuffer:GetCircle(x, y, radius)
  local xmin, xmax, ymin, ymax = self.mapRuler:RadiusBounds(x, y, radius)
  local totalHeight = 0
  local totalWeight = 0
  local minHeight = 99999
  local maxHeight = -99999
  for x = xmin, xmax do
    for y = ymin, ymax do
      local height = self:Get(x, y)
      totalHeight = totalHeight + height
      totalWeight = totalWeight + 1
      if height < minHeight then minHeight = height end
      if height > maxHeight then maxHeight = height end
    end
  end
  return totalHeight / totalWeight, minHeight, maxHeight
end

function HeightBuffer:Blur(radius)
  radius = radius or 1
  local sradius = math.ceil(radius * 2.57)
  local radiusTwoSq = radius * radius * 2
  local radiusTwoSqPi = radiusTwoSq * pi
  local weights = {}
  for dx = -sradius, sradius do
    weights[dx] = {}
    for dy = -sradius, sradius do
      local distSq = (dx*dx) + (dy*dy)
      local weight = math.exp(-distSq / radiusTwoSq) / radiusTwoSqPi
      weights[dx][dy] = weight
    end
  end
  local newHeights = {}
  for x = 1, self.w do
    for y = 1, self.h do
      local center = self:Get(x, y)
      local totalWeight = 0
      local totalHeight = 0
      local same = true
      for dx = -sradius, sradius do
        for dy = -sradius, sradius do
          local h = self:Get(x+dx, y+dy)
          if h ~= center then
            same = false
            break
          end
        end
        if not same then break end
      end
      local newH
      if same then
        newH = center
      else
        for dx = -sradius, sradius do
          for dy = -sradius, sradius do
            local h = self:Get(x+dx, y+dy)
            if h then
              local weight = weights[dx][dy]
              totalHeight = totalHeight + (h * weight)
              totalWeight = totalWeight + weight
            end
          end
        end
        newH = totalHeight / totalWeight
      end
      newHeights[x] = newHeights[x] or {}
      newHeights[x][y] = newH
    end
  end
  for x = 1, self.w do
    for y = 1, self.h do
      self:Set(x, y, newHeights[x][y])
    end
  end
end

function HeightBuffer:Read()
  for sx=0,Game.mapSizeX, Game.squareSize do
    for sz=Game.mapSizeZ,0, -Game.squareSize do
      local x, y = XZtoHXHY(sx, sz)
      local height = (Spring.GetGroundHeight(sx, sz) - self.world.baselevel) / 8
      self:Set(x, y, height)
    end
  end
  Spring.Echo("height buffer read from map")
end

function HeightBuffer:SendPGM()
  table.insert(self.world.renderers, Renderer(self.world, heightMapRuler, 15000, "heightimage", self, true))
end

function HeightBuffer:Clear()
  for x = 1, self.w do
    for y = 1, self.h do
      -- self:Set(x, y, 0)
      self.heights[x][y] = 0
    end
  end
  self.minHeight = 0
  self.maxHeight = 0
end

--------------------------------------

function Renderer:Frame()
  if self.complete then return end
  local progress
  if self.renderType == "heightprespring" then
    progress = self:HeightFrame()
  elseif self.renderType == "heightspring" then
    progress = self:HeightToSpringFrame()
  elseif self.renderType == "heightimage" then
    progress = self:HeightToImageFrame()
  elseif self.renderType == "attributes" then
    progress = self:AttributeFrame()
  end
  if progress then
    self.progress = (self.progress or 0) + progress
    SendToUnsynced("RenderStatus", self.renderType, self.progress, self.totalProgress)
  else
    SendToUnsynced("RenderStatus", "none")
  end
end

function Renderer:HeightFrame()
  if #self.craters == 0 then
    -- Spring.LevelHeightMap(0, 0, Game.mapSizeX, Game.mapSizeZ, self.world.baselevel)
    if not self.heightBuf.directToSpring then
      table.insert(self.world.renderers, Renderer(self.world, heightMapRuler, 6000, "heightspring", self.heightBuf))
    end
    self.complete = true
    return
  end
  local pixelsRendered = 0
  while pixelsRendered < self.pixelsPerFrame and #self.craters > 0 do
    local c = self.craters[1]
    c:GiveStartingHeight()
    while c.currentPixel <= c.area and pixelsRendered <= self.pixelsPerFrame do
      local x, y, height, alpha = c:OneHeightPixel()
      if height then
        self.heightBuf:Blend(x, y, height+c.startingHeight, alpha)
        pixelsRendered = pixelsRendered + 1
      end
    end
    if c.currentPixel > c.area then
      c.complete = true
      table.remove(self.craters, 1)
    end
    if pixelsRendered == self.pixelsPerFrame then break end
  end
  return pixelsRendered
end

function Renderer:HeightToSpringFrame()
  if self.pixelsToRenderCount <= 0 then
    Spring.Echo("height buffer written to map")
    self.complete = true
    return
  end
  local pixelsThisFrame = math.min(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  Spring.SetHeightMapFunc(function()
    for p = pMin, pMax do
      local x = (p % self.mapRuler.width) + 1
      local y = self.mapRuler.height - math.floor(p / self.mapRuler.width)
      local sx, sz = self.mapRuler:XYtoXZ(x, y)
      local height = (self.heightBuf:Get(x, y) or 0) --* self.elmosPerPixel -- because the horizontal is all scaled to the heightmap
      Spring.SetHeightMap(sx, sz, self.world.baselevel+height)
    end
  end)
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:HeightToImageFrame()
  if self.pixelsToRenderCount <= 0 then
    SendToUnsynced("EndPGM")
    Spring.Echo("height PGM written")
    self.complete = true
    return
  end
  local pixelsThisFrame = math.min(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  local bytes = 0
  local KB = ""
  local heightBuf = self.heightBuf
  local heightDif = (heightBuf.maxHeight - heightBuf.minHeight)
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = self.mapRuler.height - math.floor(p / self.mapRuler.width)
    local pixelHeight = heightBuf:Get(x, y) or self.world.baselevel
    local pixelColor = math.floor(((pixelHeight - heightBuf.minHeight) / heightDif) * 65535)
    local twochars = le.uint16rev(pixelColor)
    KB = KB .. twochars
    bytes = bytes + 2
    if bytes > 1023 then
      SendToUnsynced("PiecePGM", KB)
      bytes = 0
      KB = ""
    end
  end
  if bytes > 0 then
    SendToUnsynced("PiecePGM", KB)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

function Renderer:AttributeFrame()
  if self.pixelsToRenderCount <= 0 then
    SendToUnsynced("EndPGM")
    Spring.Echo("attribute PGM written")
    self.complete = true
    return
  end
  local pixelsThisFrame = math.min(self.pixelsPerFrame, self.pixelsToRenderCount)
  local pMin = self.totalPixels - self.pixelsToRenderCount
  local pMax = pMin + pixelsThisFrame
  local bytes = 0
  local KB = ""
  for p = pMin, pMax do
    local x = (p % self.mapRuler.width) + 1
    local y = self.mapRuler.height - math.floor(p / self.mapRuler.width)
    -- if p < 2000 then Spring.Echo(p, x, y) end
    local attribute = 0
    for i, c in ipairs(self.craters) do
      local a = c:AttributePixel(x, y)
      if a ~= 0 then attribute = a end
    end
    -- local aRGB = {math.floor((x / myWorld.renderWidth) * 255), math.floor((y / myWorld.renderHeight) * 255), math.floor((p / myWorld.totalPixels) * 255)}
    local threechars = AttributeDict[attribute].threechars
    KB = KB .. threechars
    bytes = bytes + 3
    if bytes > 1023 then
      SendToUnsynced("PiecePGM", KB)
      bytes = 0
      KB = ""
    end
  end
  if bytes > 0 then
    SendToUnsynced("PiecePGM", KB)
  end
  self.pixelsToRenderCount = self.pixelsToRenderCount - pixelsThisFrame - 1
  return pixelsThisFrame + 1
end

--------------------------------------

function Crater:GetDistanceSq(x, y)
  local dx, dy = math.abs(x-self.x), math.abs(y-self.y)
  diffDistancesSq[dx] = diffDistancesSq[dx] or {}
  diffDistancesSq[dx][dy] = diffDistancesSq[dx][dy] or ((dx*dx) + (dy*dy))
  return diffDistancesSq[dx][dy]
end

function Crater:GetDistance(x, y)
  local dx, dy = math.abs(x-self.x), math.abs(y-self.y)
  diffDistances[dx] = diffDistances[dx] or {}
  if not diffDistances[dx][dy] then
    local distSq = self:GetDistanceSq(x, y)
    diffDistances[dx][dy] = sqrt(distSq)
  end
  return diffDistances[dx][dy], diffDistancesSq[dx][dy]
end

function Crater:HeightPixel(x, y)
  local meteor = self.meteor
  local dx, dy = x-self.x, y-self.y
  local angle = AngleDXDY(dx, dy)
  local distWobbly = meteor.distNoise:Radial(angle) + 1
  local rayWobbly = meteor.rayNoise:Radial(angle) + 1
  local realDistSq = self:GetDistanceSq(x, y)
  -- local realRimRatio = realDistSq / radiusSq
  local distSq = realDistSq * distWobbly
  local rimRatio = distSq / self.radiusSq
  local heightWobbly = (meteor.heightNoise:Radial(angle) * rimRatio) + 1
  local height = 0
  local alpha = 1
  local rimHeight = meteor.craterRimHeight * heightWobbly
  local rimRatioPower = rimRatio ^ meteor.simpleComplex
  -- Spring.Echo(meltSurface, rimHeight, meteor.craterDepth, rimHeight - meteor.craterDepth)
  if distSq < self.radiusSq then
    height = 1 - rimRatioPower
    height = rimHeight - (height*meteor.craterDepth)
    if meteor.simpleComplex > 2 then
      height = height + (meteor.craterPeakHeight * Gaussian(distSq, self.peakC) * heightWobbly)
      if height < meteor.meltSurface then height = meteor.meltSurface end
    end
    if meteor.age < 10 then
      local rayWidth = meteor.rayWidth * rayWobbly
      local rayWidthMult = twicePi / rayWidth
      local rayHeight = math.max(math.sin(rayWidthMult * angle) - 0.75, 0) * meteor.rayHeight * heightWobbly * rimRatio
      height = height - rayHeight
    end
  else
    height = rimHeight
    local fallDistSq = distSq - self.radiusSq
    local gauss = Gaussian(fallDistSq, self.falloffSqFourth)
    local linearToHalfGrowth = math.min(fallDistSq / self.falloffSqFourth, 1)
    local linearToHalfDecay = 1 - linearToHalfGrowth
    local linearGrowth = fallDistSq / self.falloffSq
    local linearDecay = 1 - linearGrowth
    local secondDecay = 1 - (linearGrowth^0.4)
    alpha = (gauss * linearToHalfGrowth) + (secondDecay * linearToHalfDecay)
    -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
  end
  -- if meteor.age > 0 then
    -- local ageWobbly = self.ageNoise:Smooth(x - self.xmin, y - self.ymin)
    -- height = height * ageWobbly
    -- if height > 0 then height = height / (1+(ageWobbly * meteor.ageRatio)) end
    -- height = math.mix(height, ((ageWobbly - 0.5) * rimHeight), meteor.ageRatio)
  -- end
  return height, alpha
  -- return self.ageNoise[y-self.ymin+1][x-self.xmin+1]*100, 1
end

function Crater:OneHeightPixel()
  local p = self.currentPixel
  local x = (p % self.width) + self.xmin
  local y = math.floor(p / self.width) + self.ymin
  self.currentPixel = self.currentPixel + 1
  local height, alpha = self:HeightPixel(x, y)
  return x, y, height, alpha
end

function Crater:AttributePixel(x, y)
  if x < self.xmin or x > self.xmax or y < self.ymin or y > self.ymax then return 0 end
  local dx, dy = x-self.x, y-self.y
  local realDistSq = self:GetDistanceSq(x, y)
  if realDistSq > self.blastRadiusSq then return 0 end
  local meteor = self.meteor
  local angle = AngleDXDY(dx, dy)
  local distWobbly = meteor.distNoise:Radial(angle) + 1
  local rayWobbly = meteor.rayNoise:Radial(angle) + 1
  local blastWobbly = meteor.blastNoise:Radial(angle) + 0.33
  local distSq = realDistSq * distWobbly
  local rimRatio = distSq / self.radiusSq
  -- local realRimRatio = realDistSq / radiusSq
  local rayWidth = meteor.rayWidth * rayWobbly
  local rayHeight = (angle % rayWidth) * rimRatio
  local rayCutoff = rayWidth * 0.5
  local blastRadiusSqWobbled = self.blastRadiusSq * blastWobbly
  -- local rayHeight = (angle % rayWidth) * self.rayHeight * distWobbly * rimRatio
  if distSq < self.brecciaRadiusSq then
    if rayHeight > rayCutoff then return 6 end
    return 1
  elseif distSq < self.radiusSq then
    if rayHeight > rayCutoff then return 6 end
    return 2
  elseif distSq < self.totalradiusSq then
    return 3
  elseif distSq < blastRadiusSqWobbled then
    local blastRatio = distSq / blastRadiusSqWobbled
    local blastRayWidth = rayWidth * (1 - blastRatio)
    local blastRayRatio = (angle % blastRayWidth) / blastRayWidth
    if math.random() < angle % blastRayWidth and math.random() > blastRatio then return 5 end
  end
  return 0
end

function Crater:GiveStartingHeight()
  if self.startingHeight then return end
  if not self.renderer.heightBuf then return end
  self.startingHeight = self.renderer.heightBuf:GetCircle(self.x, self.y, self.radius)
end

--------------------------------------

function WrapNoise:Smooth(n)
  local n1 = math.floor(n)
  local n2 = math.ceil(n)
  if n1 == n2 then return self:Output(n1) end
  local val1, val2 = self:Output(n1), self:Output(n2)
  local d = val2 - val1
  if n2 < n1 then
    -- Spring.Echo(n, n1, n2, self.length)
  end
  return val1 + (math.smoothstep(n1, n2, n) * d)
end

function WrapNoise:Radial(angle)
  local n = ((angle + pi) / self.angleDivisor) + 1
  return self:Smooth(n)
end

function WrapNoise:Output(n)
  return self.outValues[self:Clamp(n)]
end

function WrapNoise:Dist(n1, n2)
  return math.abs((n1 + self.halfLength - n2) % self.length - self.halfLength)
end

function WrapNoise:Clamp(n)
  if n < 1 then
    n = n + self.length
  elseif n > self.length then
    n = n - self.length
  end
  return n
end

--------------------------------------

function TwoDimensionalNoise:Smooth(dx, dy)
  local nx = dx / self.conversion
  local ny = dy / self.conversion
  return (self.xNoise:Smooth(nx) * self.yNoise:Smooth(ny)) / 2
end

-- end classes and class methods ---------------------------------------------

------------------------------------------------------------------------------

-- synced --------------------------------------------------------------------

if gadgetHandler:IsSyncedCode() then 

function gadget:Initialize()
  -- myWorld = World(2.32, 1000)
  myWorld = World(3, 1000)
  if not bypassSpring then
    Spring.LevelHeightMap(0, 0, Game.mapSizeX, Game.mapSizeZ, myWorld.baselevel)
  end
end

function gadget:RecvLuaMsg(msg, playerID)
  local words = splitIntoWords(msg)
  local where = words[1]
  if where == "loony" then
    local command = words[2]
    if command == "meteor" then
      myWorld:AddMeteor(words[3], words[4], words[5] * 2)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderHeightSpring()
      end
    elseif command == "shower" then
      myWorld:MeteorShower(words[3], words[4], words[5], words[6], words[7], words[8], words[9])
      BeginCommand(command)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderHeightSpring()
      end
    elseif command == "clear" then
      myWorld = World(2.32, 1000)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderHeightSpring()
      end
    elseif command == "blur" then
      local radius = words[3] or 1
      myWorld.hei:Blur(radius)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderHeightSpring()
      end
    elseif command == "read" then
      myWorld.hei:Read()
    elseif command == "heightpgm" then
      myWorld.hei:SendPGM()
    elseif command == "attribpgm" then
      myWorld:RenderAttributes(8)
    elseif command == "bypasstoggle" then
      bypassSpring = not bypassSpring
      Spring.Echo("bypassSpring is now", tostring(bypassSpring))
      SendToUnsynced("BypassSpring", tostring(bypassSpring))
      if not bypassSpring then myWorld:RenderHeightSpring() end
    end
  end
end

function gadget:GameFrame(frame)
  local renderer = myWorld.renderers[1]
  if renderer then
    renderer:Frame()
    if renderer.complete then
      -- Spring.Echo(renderer.renderType, "complete", #myWorld.renderers)
      table.remove(myWorld.renderers, 1)
    end
  end
end

end

-- end synced ----------------------------------------------------------------

-- unsynced ------------------------------------------------------------------

if not gadgetHandler:IsSyncedCode() then
  
local function PiecePGMToLuaUI(_, dataString)
  Script.LuaUI.ReceivePiecePGM(dataString)
end

local function BeginPGMToLuaUI(_, name)
  Script.LuaUI.ReceiveBeginPGM(name)
end

local function EndPGMToLuaUI(_)
  Script.LuaUI.ReceiveEndPGM()
end

local function MeteorToLuaUI(_, sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  Script.LuaUI.ReceiveMeteor(sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
end

local function BypassSpringToLuaUI(_, stateString)
  Script.LuaUI.ReceiveBypassSpring(stateString)
end

local function ClearMeteorsToLuaUI(_)
  Script.LuaUI.ReceiveClearMeteors()
end

local function CompleteCommandToLuaUI(_, command)
  Script.LuaUI.ReceiveCompleteCommand(command)
end

local function RenderStatusToLuaUI(_, renderType, progress, total)
  Script.LuaUI.ReceiveRenderStatus(renderType, progress, total)
end

function gadget:Initialize()
  gadgetHandler:AddSyncAction('PiecePGM', PiecePGMToLuaUI)
  gadgetHandler:AddSyncAction('BeginPGM', BeginPGMToLuaUI)
  gadgetHandler:AddSyncAction('EndPGM', EndPGMToLuaUI)
  gadgetHandler:AddSyncAction('Meteor', MeteorToLuaUI)
  gadgetHandler:AddSyncAction('BypassSpring', BypassSpringToLuaUI)
  gadgetHandler:AddSyncAction('ClearMeteors', ClearMeteorsToLuaUI)
  gadgetHandler:AddSyncAction('CompleteCommand', CompleteCommandToLuaUI)
  gadgetHandler:AddSyncAction('RenderStatus', RenderStatusToLuaUI)
end

end