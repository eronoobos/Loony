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

local tInsert = table.insert
local tRemove = table.remove

local spSetHeightMapFunc = Spring.SetHeightMapFunc
local spAdjustHeightMap = Spring.AdjustHeightMap
local radiansPerAngle = math.pi / 180

local buf

local diffDistances = {}
local diffDistancesSq = {}
local sqrts = {}
local gaussians = {}
local angles = {}

-- common functions:

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
  local hx = (x / Game.squareSize) + 1
  local hy = ((Game.mapSizeZ - z) / Game.squareSize) + 1
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

HeightBuffer = class(function(a, w, h, scale, baselevel, gravity, density)
  a.w, a.h = w, h
  a.scale = scale or 8
  a.baselevel = baselevel or 0
  a.gravity = gravity or (Game.gravity / 130) * 9.8
  a.density = density or (Game.mapHardness / 100) * 1500
  a.complexDiameter = 3200 / (a.gravity / 9.8)
  local buf = {}
  local possibles = {}
  for i = 1, w do
    buf[i] = {}
    for j = 1, h do
      buf[i][j] = 0
      table.insert(possibles, {x = i, y = j})
    end
  end
  a.heights = buf
  a.possibleCoordinates = possibles
  Spring.Echo("new height buffer created", w, " by ", h)
end)

Meteor = class(function(a, buf, x, y, diameterImpactor, velocityImpact, angleImpact, densityImpactor, age)
  a.buf = buf
  a.x, a.y = math.floor(x), math.floor(y)
  a.distances = {}
  a.distancesSq = {}

  -- Spring.Echo("creating new meteor at ", x, y)
  a.diameterImpactor = diameterImpactor or 500
  a.velocityImpact = velocityImpact or 70
  a.angleImpact = angleImpact or 45
  a.densityImpactor = densityImpactor or 8000
  a.age = age or 0
  a.wobbleFreq = math.floor(MinMaxRandom(1, 3))
  a.wobbleFreq2 = math.floor(MinMaxRandom(1, 3))
  a.wobbleAmount = MinMaxRandom(0.05, 0.15)
  a.wobbleAmount2 = MinMaxRandom(0.1, 0.5)
  a.wobbleOffset = MinMaxRandom(0, pi)
  a.wobbleOffset2 = MinMaxRandom(0, pi)

  a.angleImpactRadians = a.angleImpact * radiansPerAngle
  a.diameterTransient = 1.161 * ((a.densityImpactor / buf.density) ^ 0.33) * (a.diameterImpactor ^ 0.78) * (a.velocityImpact ^ 0.44) * (buf.gravity ^ -0.22) * (math.sin(a.angleImpactRadians) ^ 0.33)
  a.diameterSimple = a.diameterTransient * 1.25
  a.diameterComplex = 1.17 * ((a.diameterTransient ^ 1.13) / (buf.complexDiameter ^ 0.13))
  a.depthTransient = a.diameterTransient / twoSqrtTwo
  a.rimHeightTransient = a.diameterTransient / 14.1
  a.rimHeightSimple = 0.07 * ((a.diameterTransient ^ 4) / (a.diameterSimple ^ 3))
  a.brecciaVolume = 0.032 * (a.diameterSimple ^ 3)
  a.brecciaDepth = 2.8 * a.brecciaVolume * ((a.depthTransient + a.rimHeightTransient) / (a.depthTransient * a.diameterSimple * a.diameterSimple))
  a.depthSimple = a.depthTransient - a.brecciaDepth
  a.depthComplex = 0.4 * (a.diameterSimple ^ 0.3)

  a.simpleComplex = math.min(1 + (a.diameterSimple / buf.complexDiameter), 3)
  local simpleMult = 3 - a.simpleComplex
  local complexMult  = a.simpleComplex - 1
  a.craterRadius = (a.diameterSimple / 2) / buf.scale
  a.craterFalloff = a.craterRadius * 0.66
  local depthSimpleAdd = a.depthSimple * simpleMult
  local depthComplexAdd = a.depthComplex * complexMult
  local depth = (depthSimpleAdd + depthComplexAdd) / (simpleMult + complexMult)
  a.craterDepth = ((depth + a.rimHeightSimple)  ) / buf.scale
  a.craterRimHeight = a.rimHeightSimple / buf.scale
  a.craterPeakHeight = (a.simpleComplex - 2) * a.craterDepth
  a.craterPeakC = (a.craterRadius / 8) ^ 2
  a.rayWidth = 8 / a.craterRadius
  a.rayHeight = (a.craterRimHeight / 3) * simpleMult
  a.rayWobbleAmount = MinMaxRandom(0.5, 1)
  Spring.Echo(a.simpleComplex, a.craterPeakHeight, a.craterPeakC)
  -- Spring.Echo(math.floor(a.diameterSimple), math.floor(a.depthSimple), math.floor(a.rimHeightSimple))
  -- Spring.Echo(math.floor(a.diameterTransient), math.floor(a.depthTransient), math.floor(a.rimHeightTransient))
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
    Spring.Echo(i, n, offset, length)
    a.values[n] = acc+0
  end
end)

-- end classes ---------------------------------------------------------------

-- class methods: ------------------------------------------------------------

function CumulativeNoise:RadialNoise(angle)
  local anglefalse = (angle + pi) / self.angleDivisor
  local angle1 = math.floor(anglefalse)
  local angle2 = math.ceil(anglefalse)
  if angle1 == 0 then angle1 = self.length end
  if angle2 == self.length+1 then angle2 = 1 end
  if angle1 == angle2 then
    return self:NormalizedNoise(angle1)
  end
  local adist1, adist2 = self:RadialDist(anglefalse, angle1), self:RadialDist(anglefalse, angle2)
  local totaldist = adist1 + adist2
  -- Spring.Echo(angle1, angle2, self.values[angle1], self.values[angle2])
  local val = ((self.values[angle1] * adist2) + (self.values[angle2] * adist1)) / totaldist
  local normval = val / self.absMaxValue
  return normval
end

function CumulativeNoise:NormalizedNoise(n)
  return self.values[n] / self.absMaxValue
end

function CumulativeNoise:RadialDist(n1, n2)
  return math.abs((n1 + self.halfLength - n2) % self.length - self.halfLength)
end

function Meteor:Impact()
  -- Spring.Echo("impacting meteor at ", self.x, self.y)
  self:Crater()
  -- self:Rays()
end

function Meteor:GetDistanceSq(x, y)
  self.distancesSq[x] = self.distancesSq[x] or {}
  if not self.distancesSq[x][y] then
    local dx, dy = math.abs(x-self.x), math.abs(y-self.y)
    diffDistancesSq[dx] = diffDistancesSq[dx] or {}
    self.distancesSq[x][y] = diffDistancesSq[dx][dy] or (dx*dx) + (dy*dy)
    diffDistancesSq[dx][dy] = diffDistancesSq[dx][dy] or self.distancesSq[x][y]
  end
  return self.distancesSq[x][y]
end

function Meteor:GetDistance(x, y)
  self.distances[x] = self.distances[x] or {}
  if not self.distances[x][y] then
    local dx, dy = math.abs(x-self.x), math.abs(y-self.y)
    diffDistances[dx] = diffDistances[dx] or {}
    if not diffDistances[dx][dy] then
      local distSq = self:GetDistanceSq(x, y)
      self.distances[x][y] = sqrt(distSq)
      diffDistances[dx][dy] = self.distances[x][y]
    end
  end
  return self.distances[x][y], self.distancesSq[x][y]
end

function Meteor:Crater()
  local w, h = self.buf.w, self.buf.h
  local x, y = self.x, self.y
  local totalradius = self.craterRadius + self.craterFalloff
  local totalradiusSq = totalradius * totalradius
  local xmin, xmax, ymin, ymax = self.buf:DetermineRadiusExtent(x, y, totalradius*(1+self.wobbleAmount))
  local craterRadiusSq = self.craterRadius * self.craterRadius
  local craterFalloffSq = totalradiusSq - craterRadiusSq
  self.noise1 = CumulativeNoise(16)
  self.noise2 = CumulativeNoise(32)
  self.noise3 = CumulativeNoise(24)
  -- self:CreateRadialNoise()
  Spring.Echo(self.radialNoiseMax)
  local startingHeight = self.buf:CircleHeight(x, y, self.craterRadius)
  local newHeights = {}
  local newAlphas = {}
  local diameterTransientFourth = self.diameterTransient ^ 4
  for i=xmin,xmax do
    newHeights[i] = {}
    newAlphas[i] = {}
    for j=ymin,ymax do
      local origHeight = self.buf:GetHeight(i, j) - startingHeight
      local dx, dy = i-x, j-y
      local angle = AngleDXDY(dx, dy)
      -- local wobbly = math.sin((angle*self.wobbleFreq)+self.wobbleOffset) * self.wobbleAmount
      local wobbly =  self.noise1:RadialNoise(angle) * self.wobbleAmount --self:GetRadialNoise(angle)
      local rayWobbly = self.noise3:RadialNoise(angle) * self.rayWobbleAmount
      local realDistSq = self:GetDistanceSq(i, j)
      local distSq = realDistSq * (1 + wobbly)
      local rimRatio = distSq / craterRadiusSq
      local wobbly2 = self.noise2:RadialNoise(angle) * self.wobbleAmount2 * rimRatio
      -- local wobbly2 = math.sin((angle*self.wobbleFreq2)+self.wobbleOffset2) * self.wobbleAmount2 * rimRatio
      local height = 0
      local alpha = 1
      local rayWidth = self.rayWidth * (1+rayWobbly)
      if distSq < craterRadiusSq then
        height = 1 - (rimRatio^self.simpleComplex)
        height = self.craterRimHeight - (height*self.craterDepth)
        if self.simpleComplex > 2 then
          height = height + (self.craterPeakHeight * Gaussian(distSq, self.craterPeakC) * (1 + wobbly2))
        end
        local rayHeight = (angle % rayWidth) * self.rayHeight * (1+wobbly2) * rimRatio
        height = height + rayHeight
      else
        local fallDistSq = distSq - craterRadiusSq
        if fallDistSq < craterFalloffSq then
          local fallscale = (fallDistSq / craterFalloffSq) ^ 0.33
          height = self.craterRimHeight
          -- height = diameterTransientFourth / (112 * (fallDistSq^1.5))
          alpha = 1 - fallscale
        else
          alpha = 0
        end
      end
      height = height * (1 + wobbly2)
      newHeights[i][j] = height
      newAlphas[i][j] = alpha
    end
  end
  for i=xmin,xmax do
    for j=ymin,ymax do
      -- self.buf:AddHeight(i, j, newHeights[i][j], newAlphas[i][j])
      self.buf:BlendHeight(i, j, newHeights[i][j]+startingHeight, newAlphas[i][j])
    end
  end

end

function HeightBuffer:AddHeight(x, y, height, alpha)
  alpha = alpha or 1
  if not self.heights[x] then
    Spring.Echo("no row at ", x)
    return
  end
  if not self.heights[x][y] then
    Spring.Echo("no pixel at ", x, y)
    return
  end
  self.heights[x][y] = self.heights[x][y] + (height * alpha)
end

function HeightBuffer:BlendHeight(x, y, height, alpha)
  if not self.heights[x] then
    Spring.Echo("no row at ", x)
    return
  end
  if not self.heights[x][y] then
    Spring.Echo("no pixel at ", x, y)
    return
  end
  local orig = 1 - alpha
  self.heights[x][y] = (self.heights[x][y] * orig) + (height * alpha)
end

function HeightBuffer:SetHeight(x, y, height)
  if not self.heights[x] then
    Spring.Echo("no row at ", x)
    return
  end
  if not self.heights[x][y] then
    Spring.Echo("no pixel at ", x, y)
    return
  end
  self.heights[x][y] = height
end

function HeightBuffer:GetHeight(x, y)
  if not self.heights[x] then return end
  if not self.heights[x][y] then return end
  return self.heights[x][y]
end

function HeightBuffer:DetermineRadiusExtent(x, y, radius)
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

function HeightBuffer:CircleHeight(x, y, radius)
  local xmin, xmax, ymin, ymax = self:DetermineRadiusExtent(x, y, radius)
  local totalHeight = 0
  local totalWeight = 0
  local minHeight = 99999
  local maxHeight = -99999
  for x = xmin, xmax do
    for y = ymin, ymax do
      local height = self:GetHeight(x, y)
      totalHeight = totalHeight + height
      totalWeight = totalWeight + 1
      if height < minHeight then minHeight = height end
      if height > maxHeight then maxHeight = height end
    end
  end
  return totalHeight / totalWeight, minHeight, maxHeight
end

function HeightBuffer:MeteorShower(number, minDiameter, maxDiameter, minVelocity, maxVelocity, minAngle, maxAngle, minDensity, maxDensity)
  number = number or 3
  minDiameter = minDiameter or 10^0.33
  maxDiameter = maxDiameter or 2000^0.33
  minVelocity = minVelocity or 15
  maxVelocity = maxVelocity or 110
  minAngle = minAngle or 10
  maxAngle = maxAngle or 80
  minDensity = minDensity or 4000
  maxDensity = maxDensity or 12000
  for n = 1, number do
    local diameter = MinMaxRandom(minDiameter, maxDiameter)^3
    local velocity = MinMaxRandom(minVelocity, maxVelocity)
    local angle = MinMaxRandom(minAngle, maxAngle)
    local density = MinMaxRandom(minDensity, maxDensity)
    local x = (math.random() * self.w) + 1
    local y = (math.random() * self.h) + 1
    local m = Meteor(self, x, y, diameter, velocity, angle, density, number-n)
    m:Impact()
  end
end

function HeightBuffer:Blur(radius)
  radius = radius or 1
  local sradius = math.ceil(radius * 2.57)
  local radiusTwoSq = radius * radius * 2
  local weights = {}
  for dx = -sradius, sradius do
    weights[dx] = {}
    for dy = -sradius, sradius do
      local distSq = (dx*dx) + (dy*dy)
      local weight = math.exp(-distSq / radiusTwoSq) / (pi * radiusTwoSq)
      weights[dx][dy] = weight
    end
  end
  local newHeights = {}
  for i = 1, self.w do
    for j = 1, self.h do
      local center = self:GetHeight(i, j)
      local totalWeight = 0
      local totalHeight = 0
      local same = true
      for ii = -sradius, sradius do
        for jj = -sradius, sradius do
          local h = self:GetHeight(i+ii, j+jj)
          if h then
            if h ~= center then same = false end
            local weight = weights[ii][jj]
            totalHeight = totalHeight + (h * weight)
            totalWeight = totalWeight + weight
          end
        end
      end
      local newH
      if same then
        newH = center
      else
        newH = totalHeight / totalWeight
      end
      newHeights[i] = newHeights[i] or {}
      newHeights[i][j] = newH
    end
  end
  for i = 1, self.w do
    for j = 1, self.h do
      self:SetHeight(i, j, newHeights[i][j])
    end
  end
end

function HeightBuffer:Write()
  Spring.LevelHeightMap(0, 0, Game.mapSizeX, Game.mapSizeZ, self.baselevel)
  Spring.SetHeightMapFunc(function()
    for x=0,Game.mapSizeX, Game.squareSize do
      for z=Game.mapSizeZ,0, -Game.squareSize do
        local i, j = XZtoXY(x, z)
        local height = (self:GetHeight(i, j) or 0) * 8 -- because the horizontal is all scaled to the heightmap
        Spring.SetHeightMap( x, z, self.baselevel+height)
      end
    end
  end)
  Spring.Echo("height buffer written to map")
end

function HeightBuffer:Read()
  for x=0,Game.mapSizeX, Game.squareSize do
    for z=Game.mapSizeZ,0, -Game.squareSize do
      local i, j = XZtoXY(x, z)
      local height = (Spring.GetGroundHeight(x, z) - self.baselevel) / 8
      self:SetHeight(i, j, height)
    end
  end
  Spring.Echo("height buffer read from map")
end

function HeightBuffer:Clear()
  for i = 1, self.w do
    for j = 1, self.h do
      self:SetHeight(i, j, 0)
    end
  end
end

-- end classes and class methods ---------------------------------------------

------------------------------------------------------------------------------

-- synced --------------------------------------------------------------------

if gadgetHandler:IsSyncedCode() then 

function gadget:Initialize()
  for dx = -1, 1 do
    for dy = -1, 1 do
      Spring.Echo(dx, dy, AngleDXDY(dx, dy))
    end
  end
  buf = HeightBuffer((Game.mapSizeX / 8) + 1, (Game.mapSizeZ / 8) + 1, 18.6, 1000, 9.8, 1500)
  buf:Write()
end

function gadget:RecvLuaMsg(msg, playerID)
  local words = splitIntoWords(msg)
  local where = words[1]
  if where == "loony" then
    local command = words[2]
    if command == "meteor" then
      local x, y = XZtoXY(words[3], words[4])
      local diameter = (words[5] * 2) * (buf.scale / 8)
      local m = Meteor(buf, x, y, diameter)
      m:Impact()
      buf:Write()
    elseif command == "shower" then
      buf:MeteorShower(words[3], words[4], words[5], words[6], words[7], words[8], words[9])
      buf:Write()
    elseif command == "clear" then
      buf:Clear()
      buf:Write()
    elseif command == "blur" then
      local radius = words[3] or 1
      buf:Blur(radius)
      buf:Write()
    elseif command == "read" then
      buf:Read()
    end
  end
end

end

-- end synced ----------------------------------------------------------------

-- unsynced ------------------------------------------------------------------

if not gadgetHandler:IsSyncedCode() then

end