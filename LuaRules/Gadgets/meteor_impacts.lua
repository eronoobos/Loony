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
local pixelsPerFrame = 3000
local commandsWaiting = {}

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
  [5] = { name = "ThinEjecta", rgb = {0,0,255} }
}

local AttributesByName = {}
for i, entry in pairs(AttributeDict) do
  AttributesByName[entry.name] = { index = i, rgb = entry.rgb }
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
 
  a.hei = HeightBuffer(a)
  -- a.heiFull = HeightBuffer(a, true)
  -- a.att = AttributeBuffer(a)
  a.meteors = {}
  SendToUnsynced("ClearMeteors")
end)

AttributeBuffer = class(function(a, world)
  a.world = world
  a.w, a.h = Game.mapSizeX, Game.mapSizeZ
  local attributes = {}
  for x = 1, a.w do
    attributes[x] = {}
    for y = 1, a.h do
      attributes[x][y] = 0
    end
  end
  a.attributes = attributes
end)

HeightBuffer = class(function(a, world, fullResolution)
  a.world = world
  a.elmosPerPixel = Game.squareSize
  if fullResolution then
    a.elmosPerPixel = 1
    a.w, a.h = Game.mapSizeX, Game.mapSizeZ
  end
  a.w, a.h = (Game.mapSizeX / a.elmosPerPixel) + 1, (Game.mapSizeZ / a.elmosPerPixel) + 1
  local heights = {}
  for x = 1, a.w do
    heights[x] = {}
    for y = 1, a.h do
      heights[x][y] = 0
    end
  end
  a.heights = heights
  a.maxHeight = -99999
  a.minHeight = 99999
  Spring.Echo("new height buffer created", a.w, " by ", a.h)
end)

Meteor = class(function(a, world, sx, sz, diameterSpring, velocityImpact, angleImpact, densityImpactor, age)
  -- coordinates sx and sz and diameterSpring are in spring coordinates (elmos)
  a.world = world
  a.sx, a.sz = math.floor(sx), math.floor(sz)
  a.x, a.y = XZtoXY(a.sx, a.sz)
  a.hx, a.hy = XZtoHXHY(a.sx, a.sz)
  a.distances = {}
  a.distancesSq = {}

  a.noise1 = CumulativeNoise(32)
  a.noise2 = CumulativeNoise(24)
  a.noise3 = CumulativeNoise(16)

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
  a.craterPeakC = (a.craterRadius / 8) ^ 2
  a.rayWidth = 8 / a.craterRadius
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
  for i = 1, length do
    local add
    local distFromEnd = (length + 1 - i)
    if distFromEnd < math.abs(acc) then
      add = (-acc / distFromEnd)
    else
      add = (math.random() * 2) - 1
    end
    acc = acc + add
    if math.abs(acc) > a.absMaxValue then a.absMaxValue = math.abs(acc) end
    local n = i + offset
    if n > length then n = n - length end
    -- Spring.Echo(i, n, offset, length)
    a.values[n] = acc+0
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

function World:RenderSpring()
  self.meteorsToRender = {}
  for i, m in ipairs(self.meteors) do
    m:Impact(self.hei)
  end
  self.postRender = "spring"
end

function World:RenderFull()
  self.meteorsToRender = {}
  if not self.heiFull then self.heiFull = HeightBuffer(self, true) end
  if not self.att then self.att = AttributeBuffer(self) end
  for i, m in ipairs(self.meteors) do
    m:Impact(self.heiFull, self.att)
  end
  self.postRender = "fullpgm"
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

function HeightBuffer:RadiusBounds(x, y, radius)
  local w, h = self.w, self.h
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

function HeightBuffer:GetCircle(x, y, radius)
  local xmin, xmax, ymin, ymax = self:RadiusBounds(x, y, radius)
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
  local normalized = {}
  for x = 1, self.w do
     normalized[x] = {}
     for y = 1, self.h do
        local pixelHeight = self:Get(x, y)
        local pixelColor = math.floor(((pixelHeight - self.minHeight) / heightDif) * maxvalue)
        normalized[x][y] = pixelColor
     end
  end
  local KB = ""
  local bytes = 0
  for y = self.h, 1, -1 do
    for x = 1, self.w do
      local twochars = le.uint16rev(normalized[x][y] or 0)
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

function AttributeBuffer:CoordsOkay(x, y)
  if not self.attributes[x] then
    -- Spring.Echo("no row at ", x)
    return
  end
  if not self.attributes[x][y] then
    -- Spring.Echo("no pixel at ", x, y)
    return
  end
  return true
end

function AttributeBuffer:Set(x, y, attributeName)
  if not self:CoordsOkay(x, y) then return end
  self.attributes[x][y] = AttributesByName[attributeName].index
end

function AttributeBuffer:Get(x, y)
  if not self:CoordsOkay(x, y) then return end
  return self.attributes[x][y]
end

function AttributeBuffer:GetName(x, y)
  local index = self:Get(x,y)
  if index then return AttributeDict[index].name end
end

function AttributeBuffer:SendPGM()
  SendToUnsynced("BeginPGM", "attrib")
  SendToUnsynced("PiecePGM", "P6 " .. tostring(self.w) .. " " .. tostring(self.h) .. " 255 ")
  local KB = ""
  local bytes = 0
  for y = self.h, 1, -1 do
    for x = 1, self.w do
      local aRGB = AttributeDict[self.attributes[x][y]].rgb
      local r = string.char(aRGB[1])
      local g = string.char(aRGB[2])
      local b = string.char(aRGB[3])
      local threechars = r .. g .. b
      KB = KB .. twochars
      bytes = bytes + 3
      if bytes > 1023 then
        SendToUnsynced("PiecePGM", KB)
        bytes = 0
        KB = ""
      end
    end
  end
  if bytes > 0 then SendToUnsynced("PiecePGM", KB) end
  SendToUnsynced("EndPGM")
end

--------------------------------------

function Meteor:GetDistanceSq(x, y, heightBuf)
  local mx, my = self.hx, self.hy
  if heightBuf.elmosPerPixel == 1 then mx, my = self.x, self.y end 
  self.distancesSq[x] = self.distancesSq[x] or {}
  if not self.distancesSq[x][y] then
    local dx, dy = math.abs(x-mx), math.abs(y-my)
    diffDistancesSq[dx] = diffDistancesSq[dx] or {}
    self.distancesSq[x][y] = diffDistancesSq[dx][dy] or (dx*dx) + (dy*dy)
    diffDistancesSq[dx][dy] = diffDistancesSq[dx][dy] or self.distancesSq[x][y]
  end
  return self.distancesSq[x][y]
end

function Meteor:GetDistance(x, y, heightBuf)
  local mx, my = self.hx, self.hy
  if heightBuf.elmosPerPixel == 1 then mx, my = self.x, self.y end
  self.distances[x] = self.distances[x] or {}
  if not self.distances[x][y] then
    local dx, dy = math.abs(x-mx), math.abs(y-my)
    diffDistances[dx] = diffDistances[dx] or {}
    if not diffDistances[dx][dy] then
      local distSq = self:GetDistanceSq(x, y)
      self.distances[x][y] = sqrt(distSq)
      diffDistances[dx][dy] = self.distances[x][y]
    end
  end
  return self.distances[x][y], self.distancesSq[x][y]
end

function Meteor:LocalRadii(heightBuf)
  local craterRadius = self.craterRadius / heightBuf.elmosPerPixel
  local craterFalloff = self.craterRadius / heightBuf.elmosPerPixel
  local craterPeakC = (craterRadius / 8) ^ 2
  local rayWidth = 8 / craterRadius
  return craterRadius, craterFalloff, craterPeakC, rayWidth
end

function Meteor:Impact(heightBuf, attributeBuf)
  heightBuf = heightBuf or self.world.hei
  local mx, my = self.hx, self.hy
  if heightBuf.elmosPerPixel == 1 then mx, my = self.x, self.y end
  local craterRadius, craterFalloff, craterPeakC, craterRayWidth = self:LocalRadii(heightBuf)
  local totalradius = craterRadius + craterFalloff
  local totalradiusSq = totalradius * totalradius
  local xmin, xmax, ymin, ymax = heightBuf:RadiusBounds(mx, my, totalradius*(1+self.distWobbleAmount))
  local craterRadiusSq = craterRadius * craterRadius
  local brecciaRadiusSq = (craterRadius * 0.85) ^ 2
  local craterFalloffSq = totalradiusSq - craterRadiusSq
  local startingHeight = heightBuf:GetCircle(mx, my, craterRadius)
  local pixels = {}
  for x=xmin,xmax do
    for y=ymin,ymax do
      table.insert(pixels, {x = x, y = y})
    end
  end
  self.pixelsToRender = pixels
  self.renderData = {
    heightBuf = heightBuf,
    attributeBuf = attributeBuf,
    mx = mx, my = my,
    craterRadius = craterRadius,
    craterFalloff = craterFalloff,
    craterPeakC = craterPeakC,
    craterRayWidth = craterRayWidth,
    totalRadius = totalradius,
    totalradiusSq = totalradiusSq,
    craterRadiusSq = craterRadiusSq,
    craterFalloffSq = craterFalloffSq,
    startingHeight = startingHeight,
  }
  tInsert(self.world.meteorsToRender, self)
end

function Meteor:RenderPixel(pixel)
  local x, y = pixel.x, pixel.y
  local rd = self.renderData
  heightBuf = rd.heightBuf
  attributeBuf = rd.attributeBuf
  mx, my = rd.mx, rd.my
  craterRadius = rd.craterRadius
  craterFalloff = rd.craterFalloff
  craterPeakC = rd.craterPeakC
  craterRayWidth = rd.craterRayWidth
  totalRadius = rd.totalradius
  totalradiusSq = rd.totalradiusSq
  craterRadiusSq = rd.craterRadiusSq
  craterFalloffSq = rd.craterFalloffSq
  startingHeight = rd.startingHeight
  local dx, dy = x-mx, y-my
  local angle = AngleDXDY(dx, dy)
  local distWobbly = self.noise1:Radial(angle) * self.distWobbleAmount
  local rayWobbly = self.noise2:Radial(angle) * self.rayWobbleAmount
  local realDistSq = self:GetDistanceSq(x, y, heightBuf)
  -- local realRimRatio = realDistSq / craterRadiusSq
  local distSq = realDistSq * (1 + distWobbly)
  local rimRatio = distSq / craterRadiusSq
  local heightWobbly = self.noise3:Radial(angle) * self.heightWobbleAmount * rimRatio
  local height = 0
  local alpha = 1
  local rayWidth = craterRayWidth * (1+rayWobbly)
  local rimHeight = self.craterRimHeight * (1+heightWobbly)
  local rayHeight = (angle % rayWidth) * self.rayHeight * (1+distWobbly) * rimRatio
  if distSq < craterRadiusSq then
    height = 1 - (rimRatio^self.simpleComplex)
    height = rimHeight - (height*self.craterDepth)
    if self.simpleComplex > 2 then
      height = height + (self.craterPeakHeight * Gaussian(distSq, craterPeakC) * (1 + distWobbly))
    end
    height = height + rayHeight
  else
    local fallDistSq = distSq - craterRadiusSq
    if fallDistSq < craterFalloffSq then
      local fallscale = (fallDistSq / craterFalloffSq) ^ 0.3
      height = rimHeight + (rayHeight * (1 - fallscale)^2)
      -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
      alpha = 1 - fallscale
    else
      alpha = 0
    end
  end
  -- Spring.Echo(dx, dy, realDistSq, distSq, craterRadiusSq, rimRatio, rimHeight)
  height = height * (1 + heightWobbly)
  heightBuf:Blend(x, y, height+startingHeight, alpha)
  if attributeBuf then
    if distSq < brecciaRadiusSq then
      attributeBuf:Set(x, y, "Breccia")
    elseif distSq < craterRadiusSq then
      attributeBuf:Set(x, y, "InnerRim")
    elseif distSq < totalradiusSq then
      attributeBuf:Set(x, y, "EjectaBlanket")
    end
  end
end

function Meteor:RenderOnePixel()
  if #self.pixelsToRender == 0 then return end
  local pixel = table.remove(self.pixelsToRender)
  self:RenderPixel(pixel)
  return true
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
  if not bypassSpring then myWorld:RenderSpring() end
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
        myWorld:RenderSpring()
      end
    elseif command == "shower" then
      myWorld:MeteorShower(words[3], words[4], words[5], words[6], words[7], words[8], words[9])
      BeginCommand(command)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderSpring()
      end
    elseif command == "clear" then
      myWorld = World(2.32, 1000)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderSpring()
      end
    elseif command == "blur" then
      local radius = words[3] or 1
      myWorld.hei:Blur(radius)
      if not bypassSpring then
        BeginCommand(command)
        myWorld:RenderSpring()
      end
    elseif command == "read" then
      myWorld.hei:Read()
    elseif command == "heightpgm" then
      myWorld.hei:SendPGM()
    elseif command == "heightfull" then
      myWorld:RenderFull()
    elseif command == "bypasstoggle" then
      bypassSpring = not bypassSpring
      Spring.Echo("bypassSpring is ", tostring(bypassSpring))
    end
  end
end

function gadget:GameFrame(frame)
  local pixelsRendered = 0
  for i = #myWorld.meteorsToRender, 1, -1 do
    local m = myWorld.meteorsToRender[i]
    while #m.pixelsToRender > 0 and pixelsRendered < pixelsPerFrame do
      if m:RenderOnePixel() then pixelsRendered = pixelsRendered + 1 end
    end
    if #m.pixelsToRender == 0 then table.remove(myWorld.meteorsToRender, i) end
    if pixelsRendered == pixelsPerFrame then return end
  end
  if pixelsRendered > 0 and #myWorld.meteorsToRender == 0 and myWorld.postRender then
    if myWorld.postRender == "spring" then
      myWorld.hei:Write()
    elseif myWorld.postRender == "fullpgm" then
      myWorld.heiFull:SendPGM()
      myWorld.att:SendPGM()
    end
    myWorld.postRender = nil
    EndCommands()
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