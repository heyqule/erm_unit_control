local PerimeterMode = {}

local PERIMETER_RANGE = 150 -- Updated from 1000. why the fuck i put 1000 earlier lol.
local SCAN_INTERVAL = 60 -- Ticks to wait before re-scanning (1 second)

--[[
This function is called by process_command_queue.
It scans for enemies within a perimeter. If found, it attacks.
If not found, it returns to its post and waits to scan again.
]]
function PerimeterMode.update(unit_data, set_command_func, set_unit_idle_func)
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  local original_pos = unit_data.original_position
  if not original_pos then return end -- Safety check

  local surface = unit.surface
  local player_force = unit.force

  -- Scan for enemies (units or turrets) within perimeter range of the *original position*
  local target = surface.find_nearest_enemy({
    position = original_pos, -- Search *from the origin*
    max_distance = PERIMETER_RANGE,
    force = player_force,
    type = {"unit", "turret"} -- FIX: This filters out projectiles
  })

  if target then
    -- Enemy found within perimeter. Engage.
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = target,
      distraction = defines.distraction.by_enemy
    })
  else
    -- No enemies found in perimeter.
    local distance_from_origin = util.distance(unit.position, original_pos)
    
    if distance_from_origin > 5 then
      -- Not at post. Return to origin.
      set_command_func(unit_data, {
        type = defines.command.go_to_location,
        destination = original_pos,
        distraction = defines.distraction.never
      })
    else
      -- At post and no enemies left. Wait before scanning again.
      set_command_func(unit_data, {
        type = defines.command.stop,
        ticks_to_wait = SCAN_INTERVAL
      })
    end
  end
end

return PerimeterMode