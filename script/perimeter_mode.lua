local PerimeterMode = {}

-- How far the unit will scan for enemies from its original post
local PERIMETER_RANGE = 150
-- How long to wait (in ticks) before scanning again if no enemies are found
local SCAN_INTERVAL = 60

-- This is the main 'update' function for perimeter mode.
-- It scans for enemies. If found, it attacks.
-- If not, it returns to its post and waits.
function PerimeterMode.update(unit_data, set_command_func, set_unit_idle_func)
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  -- This is the "post" the unit is defending
  local original_pos = unit_data.original_position
  if not original_pos then return end -- Safety check

  local surface = unit.surface
  local player_force = unit.force

  -- Scan for any enemies within range of the *original position*
  local target = surface.find_nearest_enemy({
    position = original_pos, -- Search *from the origin*, not the unit
    max_distance = PERIMETER_RANGE,
    force = player_force
    -- Note: 'type' parameter was removed as it's not valid here
  })

  if target then
    -- Enemy found! Engage.
    --set_command_func(unit_data, {
    --  type = defines.command.attack,
    --  target = target,
    --  distraction = defines.distraction.by_enemy
    --})
    set_command_func(unit_data, {
      type = defines.command.go_to_location,
      destination = {
        x = target.position.x + math.random(8),
        y = target.position.y + math.random(8)
      },
      distraction = defines.distraction.by_enemy,
      radius = 4
    })
  else
    -- No enemies found in the perimeter.
    local distance_from_origin = util.distance(unit.position, original_pos)
    
    if distance_from_origin > 5 then
      -- The unit is not at its post, so return to it.
      set_command_func(unit_data, {
        type = defines.command.go_to_location,
        destination = original_pos,
        distraction = defines.distraction.never -- Don't get distracted
      })
    else
      -- The unit is at its post. Wait a bit before scanning again.
      set_command_func(unit_data, {
        type = defines.command.stop,
        ticks_to_wait = SCAN_INTERVAL
      })
    end
  end
end

return PerimeterMode