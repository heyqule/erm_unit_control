local HuntingMode = {}

--[[
Finds a patrol destination, prioritizing uncharted chunks.
This is used to create a shared destination for the whole group.
]]
local function get_hunt_destination(unit)
  local surface = unit.surface
  local force = unit.force
  
  -- Try to find an uncharted chunk, just like scout
  local chunk_x = math.floor(unit.position.x / 32)
  local chunk_y = math.floor(unit.position.y / 32)
  local scout_range = 10 -- Look 10 chunks away
  
  local uncharted_chunks = {}
  local is_charted = force.is_chunk_charted
  
  for X = -scout_range, scout_range do
    for Y = -scout_range, scout_range do
      local chunk_pos = {x = chunk_x + X, y = chunk_y + Y}
      -- Check if chunk is valid (not out of bounds) before checking if charted
      if surface.is_chunk_generated(chunk_pos) and not is_charted(surface, chunk_pos) then
        table.insert(uncharted_chunks, chunk_pos)
      end
    end
  end
  
  local dest_chunk
  if #uncharted_chunks > 0 then
    -- Go to a random uncharted chunk
    dest_chunk = uncharted_chunks[math.random(#uncharted_chunks)]
  else
    -- No uncharted chunks, pick a random direction far away
    local angle = math.random() * 2 * math.pi
    local distance = 1000 + math.random(1000) -- 1k-2k tiles
    dest_chunk = {
      x = math.floor((unit.position.x + (math.cos(angle) * distance)) / 32),
      y = math.floor((unit.position.y + (math.sin(angle) * distance)) / 32)
    }
  end
  
  -- Pick a random point inside that chunk
  local dest_pos = {
    x = (dest_chunk.x * 32) + math.random(1, 32),
    y = (dest_chunk.y * 32) + math.random(1, 32)
  }
  
  -- Find the closest valid position to that random point
  return surface.find_non_colliding_position(unit.name, dest_pos, 0, 20) or dest_pos
end

--[[
This function is called by process_command_queue.
It finds the nearest enemy and issues an attack command.
If no enemy is found, it coordinates with the group to patrol.
]]
function HuntingMode.update(unit_data, set_command_func, set_unit_idle_func)
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  local surface = unit.surface
  local player_force = unit.force

  -- 1. Find nearby enemies
  local target = surface.find_nearest_enemy({
    position = unit.position,
    max_distance = 5000, -- 5000-tile search radius
    force = player_force
  })

  if target then
    -- 2. If enemy found, attack it.
    -- We also clear any shared patrol destination so that
    -- when the fight is over, they pick a new one.
    if unit_data.group then
      unit_data.group.hunt_patrol_dest = nil
    end
    
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = target,
      distraction = defines.distraction.by_enemy
    })
  else
    -- 3. No enemy found. Check for a shared group patrol destination.
    local group = unit_data.group
    if not group then 
      -- This unit is orphaned (e.g. rest of group died), stop hunting.
      set_unit_idle_func(unit_data) 
      return
    end

    local group_dest = group.hunt_patrol_dest
    local dist_to_dest = 9999
    if group_dest then
      dist_to_dest = util.distance(unit.position, group_dest)
    end

    -- If no dest, or unit is close to old dest (less than 50 tiles), find a new one.
    -- This makes one unit (the first to finish its command) the "leader"
    if not group_dest or dist_to_dest < 50 then
      group_dest = get_hunt_destination(unit)
      group.hunt_patrol_dest = group_dest
    end

    -- 4. Issue an attack-move to the shared destination.
    -- All units in the group will get this same 'group_dest'
    -- The "distraction = by_anything" is the "attack any enemy on sight" part.
    set_command_func(unit_data, {
      type = defines.command.go_to_location,
      destination = group_dest,
      distraction = defines.distraction.by_anything,
      radius = 10 -- Arrive within a 10-tile radius (helps with clumping)
    })
  end
end

return HuntingMode