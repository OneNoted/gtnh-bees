local util = require("gtnh_bees.util")
local Planner = {}

local function condition_cost(route)
  local missing = 0
  for _, condition in ipairs(route.conditions or {}) do if not condition.satisfied then missing = missing + 1 end end
  return missing
end

local function has_alternate_princess(roles, uid)
  for candidate in pairs(roles.princess or {}) do if candidate ~= uid then return true end end
  return false
end

local function can_convert(roles, uid)
  return roles.drone[uid] and roles.convertible[uid] and has_alternate_princess(roles, uid)
end

local function orientation_list(route, roles)
  local a, b = route.parents[1], route.parents[2]
  local candidates = {{princess=a, drone=b}}
  if a ~= b then candidates[#candidates + 1] = {princess=b, drone=a} end
  for index, orientation in ipairs(candidates) do
    orientation._order = index
    orientation._missing = (roles.princess[orientation.princess] and 0 or 1) + (roles.drone[orientation.drone] and 0 or 1)
  end
  table.sort(candidates, function(left, right)
    if left._missing ~= right._missing then return left._missing < right._missing end
    return left._order < right._order
  end)
  for _, orientation in ipairs(candidates) do orientation._missing, orientation._order = nil, nil end
  return candidates
end

function Planner.orientation(route, roles)
  for _, orientation in ipairs(orientation_list(route, roles)) do
    if roles.princess[orientation.princess] and roles.drone[orientation.drone] then return orientation end
  end
  return nil
end

function Planner.reachable(catalog, initial)
  local roles = {
    princess=util.copy(initial.princess or {}), drone=util.copy(initial.drone or {}),
    convertible=util.copy(initial.convertible or {}), population=util.copy(initial.population or {})
  }
  local changed = true
  while changed do
    changed = false
    for _, uid in ipairs(util.sorted_keys(roles.drone)) do
      if not roles.princess[uid] and can_convert(roles, uid) then roles.princess[uid], changed = true, true end
    end
    for _, route in ipairs(catalog.routes) do
      if Planner.orientation(route, roles) then
        if not roles.princess[route.result] then roles.princess[route.result], changed = true, true end
        if not roles.drone[route.result] then roles.drone[route.result], changed = true, true end
        roles.convertible[route.result] = true
      end
    end
  end
  local reachable = {}
  for uid in pairs(roles.princess) do if roles.drone[uid] then reachable[uid] = true end end
  return {targets=reachable, roles=roles}
end

function Planner.rank_routes(routes, roles)
  local ranked = {}
  for _, route in ipairs(routes or {}) do
    ranked[#ranked + 1] = {route=route, feasible=Planner.orientation(route, roles) ~= nil, conditions=condition_cost(route)}
  end
  table.sort(ranked, function(a,b)
    if a.feasible ~= b.feasible then return a.feasible end
    if a.conditions ~= b.conditions then return a.conditions < b.conditions end
    local ac,bc=a.route.chance or -math.huge,b.route.chance or -math.huge
    if ac ~= bc then return ac > bc end
    return a.route.key < b.route.key
  end)
  local out = {}
  for _, item in ipairs(ranked) do out[#out + 1] = item.route end
  return out
end

function Planner.route_for(catalog, uid, roles)
  local routes = Planner.rank_routes(catalog.routes_by_result[uid], roles)
  if #routes == 0 then return nil, "no registered mutation produces " .. uid end
  return routes[1], Planner.orientation(routes[1], roles)
end

function Planner.dependencies(catalog, target, roles, excluded)
  excluded=excluded or {}
  local initial={
    princess=util.copy(roles.princess or {}), drone=util.copy(roles.drone or {}),
    convertible=util.copy(roles.convertible or {}), population=util.copy(roles.population or {})
  }
  local function clone_steps(steps)local out={} for i,item in ipairs(steps)do out[i]=item end return out end
  local function clone_roles(value)return{princess=util.copy(value.princess),drone=util.copy(value.drone),convertible=util.copy(value.convertible),population=util.copy(value.population)}end
  local solve_role, produce

  produce=function(uid,working,steps,visiting)
    local candidates=Planner.rank_routes(catalog.routes_by_result[uid],working)
    if #candidates==0 then return nil,nil,"no registered mutation produces "..uid end
    local reasons={}
    for _,route in ipairs(candidates)do
      if not (excluded[uid] and excluded[uid][route.key])then
        for _,orientation in ipairs(orientation_list(route,working))do
          local next_work,next_steps=clone_roles(working),clone_steps(steps)
          local solved,solved_steps,err=solve_role(orientation.princess,"princess",next_work,next_steps,visiting)
          if solved then
            next_work,next_steps=solved,solved_steps
            solved,solved_steps,err=solve_role(orientation.drone,"drone",next_work,next_steps,visiting)
          end
          if solved then
            next_work,next_steps=solved,solved_steps
            next_steps[#next_steps+1]={uid=uid,route=route,orientation={princess=orientation.princess,drone=orientation.drone}}
            next_work.princess[uid],next_work.drone[uid],next_work.convertible[uid],next_work.population[uid]=true,true,true,true
            return next_work,next_steps
          end
          reasons[#reasons+1]=err or ("orientation cannot fill princess/drone roles for "..uid)
        end
      else reasons[#reasons+1]="excluded route "..route.key..": "..tostring(excluded[uid][route.key]) end
    end
    return nil,nil,"all routes to "..uid.." failed: "..table.concat(reasons,"; ")
  end

  solve_role=function(uid,wanted,working,steps,visiting)
    if working[wanted][uid]then return working,steps end
    local key=uid.."\0"..wanted
    if visiting[key]then return nil,nil,"mutation graph cycle blocks "..wanted.." role for "..uid end
    local next_visiting=util.copy(visiting);next_visiting[key]=true
    if wanted=="princess" and can_convert(working,uid) and not (excluded[uid] and excluded[uid].conversion)then
      local converted=clone_roles(working);local converted_steps=clone_steps(steps)
      converted_steps[#converted_steps+1]={kind="convert",uid=uid};converted.princess[uid]=true
      return converted,converted_steps
    end
    return produce(uid,working,steps,next_visiting)
  end

  if initial.population[target] then return {} end
  local working,steps=initial,{}
  if not working.princess[target]then
    local solved,solved_steps,err=solve_role(target,"princess",working,steps,{})
    if not solved then return nil,err end
    working,steps=solved,solved_steps
  end
  if not working.drone[target]then
    local solved,solved_steps,err=solve_role(target,"drone",working,steps,{})
    if not solved then return nil,err end
    working,steps=solved,solved_steps
  end
  if #steps>0 or working.population[target]then return steps end
  if can_convert(working,target) and not (excluded[target] and excluded[target].conversion)then
    return {{kind="convert",uid=target}}
  end
  local _,order,err=produce(target,working,steps,{[target.."\0population"]=true})
  if not order then return nil,err end
  return order
end

function Planner.fixed_targets(reachability)
  local state = {targets=util.copy(reachability.targets), completed={}, failures={}}
  function state:complete(uid) self.completed[uid], self.failures[uid] = true, nil end
  function state:reopen(uid) self.completed[uid] = nil end
  function state:fail(uid, reason) self.failures[uid] = reason end
  function state:missing()
    local out = {}
    for uid in pairs(self.targets) do if not self.completed[uid] then out[#out + 1] = {uid=uid, reason=self.failures[uid]} end end
    table.sort(out, function(a,b) return a.uid < b.uid end)
    return out
  end
  return state
end

return Planner
