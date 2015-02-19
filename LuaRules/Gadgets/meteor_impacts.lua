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

-- localization:

local pi = math.pi
local twicePi = math.pi * 2
local piHalf = math.pi / 2
local piEighth = math.pi / 8
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
  a.maxHeight = -99999
  a.minHeight = 99999
  Spring.Echo("new height buffer created", a.w, " by ", a.h)
end)

Renderer = class(function(a, world, mapRuler, pixelsPerFrame, renderType, heightBuf)
  a.world = world
  a.mapRuler = mapRuler
  a.pixelsPerFrame = pixelsPerFrame
  a.renderType = renderType
  a.heightBuf = heightBuf
  a.craters = {}
  for i, m in ipairs(world.meteors) do
    table.insert(a.craters, Crater(m, a))
  end
  a.pixelsToRenderCount = mapRuler.width * mapRuler.height
  a.totalPixels = a.pixelsToRenderCount+0
  if renderType == "attributes" then
    SendToUnsynced("BeginPGM", "attrib")
    SendToUnsynced("PiecePGM", "P6 " .. tostring(mapRuler.width) .. " " .. tostring(mapRuler.height) .. " 255 ")
  end
end)

Crater = class(function(a, meteor, renderer)
  local elmosPerPixel = renderer.mapRuler.elmosPerPixel
  a.meteor = meteor
  a.renderer = renderer
  a.x, a.y = renderer.mapRuler:XZtoXY(meteor.sx, meteor.sz)
  a.craterRadius = meteor.craterRadius / elmosPerPixel
  a.craterFalloff = meteor.craterRadius / elmosPerPixel
  a.craterPeakC = (meteor.craterRadius / 8) ^ 2

  a.totalradius = a.craterRadius + a.craterFalloff
  a.totalradiusSq = a.totalradius * a.totalradius
  a.xmin, a.xmax, a.ymin, a.ymax = renderer.mapRuler:RadiusBounds(a.x, a.y, a.totalradius*(1+meteor.distWobbleAmount))
  a.craterRadiusSq = a.craterRadius * a.craterRadius
  a.craterFalloffSq = a.totalradiusSq - a.craterRadiusSq
  if renderer.heightBuf then a.startingHeight = renderer.heightBuf:GetCircle(a.x, a.y, a.craterRadius) end
  a.brecciaRadiusSq = (a.craterRadius * 0.85) ^ 2
  a.blastRadiusSq = (a.totalradius * 4) ^ 2

  a.width = a.xmax - a.xmin
  a.height = a.ymax - a.ymin
  a.area = a.width * a.height
  a.currentPixel = 0
end)

Meteor = class(function(a, world, sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  -- coordinates sx and sz and diameterSpring are in spring coordinates (elmos)
  a.world = world
  a.sx, a.sz = math.floor(sx), math.floor(sz)
  a.x, a.y = XZtoXY(a.sx, a.sz)
  a.hx, a.hy = XZtoHXHY(a.sx, a.sz)

  a.noise1 = CumulativeNoise(32)
  a.noise2 = CumulativeNoise(24)
  a.noise3 = CumulativeNoise(16)
  a.noise4 = CumulativeNoise(96)

  local diameterImpactor = diameterSpring * world.metersPerElmo
  a.diameterImpactor = diameterImpactor or 500
  a.velocityImpact = velocityImpact or 70
  a.angleImpact = angleImpact or 45
  a.densityImpactor = densityImpactor or 8000
  a.age = age or 0
  a.wobbleFreq = math.floor(MinMaxRandom(1, 3))
  a.wobbleFreq2 = math.floor(MinMaxRandom(1, 3))
  a.distWobbleAmount = MinMaxRandom(0.05, 0.15)
  a.heightWobbleAmount = MinMaxRandom(0.1, 0.5)
  a.rayWobbleAmount = MinMaxRandom(0.5, 1)

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

  a.craterDepth = ((depth + a.rimHeightSimple)  ) / world.metersPerElmo
  a.craterRimHeight = a.rimHeightSimple / world.metersPerElmo
  a.craterPeakHeight = (a.simpleComplex - 2) * a.craterDepth
  a.rayWidth = 0.008 -- in radians
  a.rayHeight = (a.craterRimHeight / 3) * simpleMult
end)

CumulativeNoise = class(function(a, length)
  a.values = {}
  a.absMaxValue = 0
  a.angleDivisor = twicePi / length
  a.length = length
  a.halfLength = length / 2
  local offset = math.floor(MinMaxRandom(0, length-1))
  local acc = 0
  local fade = math.ceil(length / 6)
  for i = 1, length do
    local add = (math.random() * 2) - 1
    local distFromEnd = (length + 1 - i)
    local mod = 1
    if distFromEnd < fade then
      local ratio = distFromEnd / fade
      mod = 1 - ratio
    end
    acc = acc + add
    local val = acc * mod
    if math.abs(val) > a.absMaxValue then a.absMaxValue = math.abs(val) end
    local n = i + offset
    if n > length then n = n - length end
    -- Spring.Echo(i, n, offset, length)
    a.values[n] = val+0
  end
end)

-- end classes ---------------------------------------------------------------

-- class methods: ------------------------------------------------------------

function World:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity)
  number = number or 3
  minDiameter = minDiameter or 10
  maxDiameter = maxDiameter or 2000
  minVelocity = minVelocity or 15
  maxVelocity = maxVelocity or 110
  minAngle = minAngle or 10
  maxAngle = maxAngle or 80
  minDensity = minDensity or 4000
  maxDensity = maxDensity or 12000
  for n = 1, number do
    local diameter = MinMaxRandom(minDiameter, maxDiameter)
    local velocity = MinMaxRandom(minVelocity, maxVelocity)
    local angle = MinMaxRandom(minAngle, maxAngle)
    local density = MinMaxRandom(minDensity, maxDensity)
    local x = math.floor(math.random() * Game.mapSizeX)
    local z = math.floor(math.random() * Game.mapSizeZ)
    self:AddMeteor(x, z, diameter, velocity, angle, density, number-n)
  end
end

function World:AddMeteor(sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  local m = Meteor(self, sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  table.insert(self.meteors, m)
  if bypassSpring then SendToUnsynced(sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age) end
end

function World:RenderHeightSpring()
  local renderer = Renderer(self, heightMapRuler, 4000, "heightspring", self.hei)
  table.insert(self.renderers, renderer)
end

function World:RenderAttributes(elmosPerPixel)
  local renderer = Renderer(self, heightMapRuler, 8000, "attributes")
  table.insert(self.renderers, renderer)
end

--------------------------------------

function MapRuler:XZtoXY(x, z)
  if self.elmosPerPixel == 1 then
    local y = (Game.mapSizeZ - z)
    return x+1, y+1
  else
    local hx = math.floor(x / self.elmosPerPixel) + 1
    local hy = math.floor((Game.mapSizeZ - z) / self.elmosPerPixel) + 1
    return hx, hy
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

function HeightBuffer:Add(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  local newHeight = self.heights[x][y] + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
end

function HeightBuffer:Blend(x, y, height, alpha)
  if not self:CoordsOkay(x, y) then return end
  alpha = alpha or 1
  local orig = 1 - alpha
  local newHeight = (self.heights[x][y] * orig) + (height * alpha)
  self.heights[x][y] = newHeight
  self:MinMaxCheck(newHeight)
end

function HeightBuffer:Set(x, y, height)
  if not self:CoordsOkay(x, y) then return end
  self.heights[x][y] = height
  self:MinMaxCheck(height)
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

function HeightBuffer:Write()
  Spring.Echo(self.minHeight, self.maxHeight, math.floor(self.minHeight * 8), math.floor(self.maxHeight * 8), math.floor(self.minHeight * self.world.metersPerSquare), math.floor(self.maxHeight * self.world.metersPerSquare))
  Spring.LevelHeightMap(0, 0, Game.mapSizeX, Game.mapSizeZ, self.world.baselevel)
  Spring.SetHeightMapFunc(function()
    for sx=0,Game.mapSizeX, Game.squareSize do
      for sz=Game.mapSizeZ,0, -Game.squareSize do
        local x, y = XZtoHXHY(sx, sz)
        local height = (self:Get(x, y) or 0) --* self.elmosPerPixel -- because the horizontal is all scaled to the heightmap
        Spring.SetHeightMap(sx, sz, self.world.baselevel+height)
      end
    end
  end)
  Spring.Echo("height buffer written to map")
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
  local maxvalue = (2 ^ 16) - 1
  SendToUnsynced("BeginPGM", "height")
  SendToUnsynced("PiecePGM", "P5 " .. tostring(self.w) .. " " .. tostring(self.h) .. " " .. maxvalue .. " ")
  local heightDif = (self.maxHeight - self.minHeight)
  local KB = ""
  local bytes = 0
  for y = self.h, 1, -1 do
    for x = 1, self.w do
      local pixelHeight = self:Get(x, y) or self.world.baselevel
      local pixelColor = math.floor(((pixelHeight - self.minHeight) / heightDif) * maxvalue)
      local twochars = le.uint16rev(pixelColor)
      KB = KB .. twochars
      bytes = bytes + 2
      if bytes == 1024 then
        SendToUnsynced("PiecePGM", KB)
        bytes = 0
        KB = ""
      end
    end
  end
  SendToUnsynced("PiecePGM", KB)
  SendToUnsynced("EndPGM")
end

function HeightBuffer:Clear()
  for x = 1, self.w do
    for y = 1, self.h do
      self:Set(x, y, 0)
    end
  end
end

--------------------------------------

function Renderer:Frame()
  if self.complete then return end
  if self.renderType == "heightspring" then
    self:HeightFrame()
  elseif self.renderType == "attributes" then
    self:AttributeFrame()
  end
end

function Renderer:HeightFrame()
  if #self.craters == 0 then
    self.heightBuf:Write()
    self.complete = true
    return
  end
  local pixelsRendered = 0
  for i = #self.craters, 1, -1 do
    local c = self.craters[i]
    while c.currentPixel <= c.area and pixelsRendered <= self.pixelsPerFrame do
      local x, y, height, alpha = c:OneHeightPixel()
      if height then
        self.heightBuf:Blend(x, y, height+c.startingHeight, alpha)
        pixelsRendered = pixelsRendered + 1
      end
    end
    if c.currentPixel > c.area then table.remove(self.craters, i) end
    if pixelsRendered == self.pixelsPerFrame then return end
  end
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
  local distWobbly = meteor.noise1:Radial(angle) * meteor.distWobbleAmount
  local rayWobbly = meteor.noise2:Radial(angle) * meteor.rayWobbleAmount
  local realDistSq = self:GetDistanceSq(x, y)
  -- local realRimRatio = realDistSq / craterRadiusSq
  local distSq = realDistSq * (1 + distWobbly)
  local rimRatio = distSq / self.craterRadiusSq
  local heightWobbly = meteor.noise3:Radial(angle) * meteor.heightWobbleAmount * rimRatio
  local height = 0
  local alpha = 1
  local rayWidth = meteor.rayWidth * (1+rayWobbly)
  local rayWidthMult = twicePi / rayWidth
  local rimHeight = meteor.craterRimHeight * (1+heightWobbly)
  -- local rayHeight = (angle % rayWidth) * self.rayHeight * (1+distWobbly) * rimRatio
  local rayHeight = math.max(math.sin(rayWidthMult * angle) - 0.75, 0) * meteor.rayHeight * (1+distWobbly) * rimRatio
  if distSq < self.craterRadiusSq then
    height = 1 - (rimRatio^meteor.simpleComplex)
    height = rimHeight - (height*meteor.craterDepth)
    if meteor.simpleComplex > 2 then
      height = height + (meteor.craterPeakHeight * Gaussian(distSq, self.craterPeakC) * (1 + distWobbly))
    end
    height = height + rayHeight
  else
    local fallDistSq = distSq - self.craterRadiusSq
    if fallDistSq < self.craterFalloffSq then
      local fallscale = (fallDistSq / self.craterFalloffSq) ^ 0.3
      height = rimHeight + (rayHeight * (1 - fallscale)^2)
      -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
      alpha = 1 - fallscale
    else
      alpha = 0
    end
  end
  -- Spring.Echo(dx, dy, realDistSq, distSq, craterRadiusSq, rimRatio, rimHeight)
  height = height * (1 + heightWobbly)
  return height, alpha
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
  local distWobbly = meteor.noise1:Radial(angle) * meteor.distWobbleAmount
  local rayWobbly = meteor.noise2:Radial(angle) * meteor.rayWobbleAmount
  local blastWobbly = (meteor.noise4:Radial(angle) * 0.66) + 0.33
  local distSq = realDistSq * (1 + distWobbly)
  local rimRatio = distSq / self.craterRadiusSq
  -- local realRimRatio = realDistSq / craterRadiusSq
  local rayWidth = meteor.rayWidth * (1+rayWobbly)
  local rayHeight = (angle % rayWidth) * rimRatio
  local rayCutoff = rayWidth * 0.5
  local blastRadiusSqWobbled = self.blastRadiusSq * blastWobbly
  -- local rayHeight = (angle % rayWidth) * self.rayHeight * (1+distWobbly) * rimRatio
  if distSq < self.brecciaRadiusSq then
    if rayHeight > rayCutoff then return 6 end
    return 1
  elseif distSq < self.craterRadiusSq then
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

--------------------------------------

function CumulativeNoise:Radial(angle)
  local anglefalse = (angle + pi) / self.angleDivisor
  local angle1 = math.floor(anglefalse)
  local angle2 = math.ceil(anglefalse)
  if angle1 == 0 then angle1 = self.length end
  if angle2 == self.length+1 then angle2 = 1 end
  if angle1 == angle2 then
    return self:Normalized(angle1)
  end
  local adist1, adist2 = self:RadialDist(anglefalse, angle1), self:RadialDist(anglefalse, angle2)
  local totaldist = adist1 + adist2
  -- Spring.Echo(angle1, angle2, self.values[angle1], self.values[angle2])
  local val = ((self.values[angle1] * adist2) + (self.values[angle2] * adist1)) / totaldist
  local normval = val / self.absMaxValue
  return normval
end

function CumulativeNoise:Normalized(n)
  return self.values[n] / self.absMaxValue
end

function CumulativeNoise:RadialDist(n1, n2)
  return math.abs((n1 + self.halfLength - n2) % self.length - self.halfLength)
end

-- end classes and class methods ---------------------------------------------

------------------------------------------------------------------------------

-- synced --------------------------------------------------------------------

if gadgetHandler:IsSyncedCode() then 

function gadget:Initialize()
  myWorld = World(2.32, 1000)
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
      Spring.Echo("bypassSpring is ", tostring(bypassSpring))
    end
  end
end

function gadget:GameFrame(frame)
  for i = #myWorld.renderers, 1, -1 do
    local renderer = myWorld.renderers[i]
    renderer:Frame()
    if renderer.complete then
      table.remove(myWorld.renderers, i)
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

local function ClearMeteorsToLuaUI(_)
  Script.LuaUI.ReceiveClearMeteors()
end

local function CompleteCommandToLuaUI(_, command)
  Script.LuaUI.ReceiveCompleteCommand(command)
end

function gadget:Initialize()
  gadgetHandler:AddSyncAction('PiecePGM', PiecePGMToLuaUI)
  gadgetHandler:AddSyncAction('BeginPGM', BeginPGMToLuaUI)
  gadgetHandler:AddSyncAction('EndPGM', EndPGMToLuaUI)
  gadgetHandler:AddSyncAction('Meteor', MeteorToLuaUI)
  gadgetHandler:AddSyncAction('ClearMeteors', ClearMeteorsToLuaUI)
  gadgetHandler:AddSyncAction('CompleteCommand', CompleteCommandToLuaUI)
end

end