local QRFMode = {}

local QRF_RANGE = 80 -- Updated from 100....more than 80 is janky
local SCAN_INTERVAL = 60 -- Ticks to wait before re-scanning

--[[
This function is called by process_command_queue.
It scans for enemies. If found, it attacks.
If not found, it returns to its post and waits.
]]
function QRFMode.update(unit_data, set_command_func)
  local unit = unit_data.entity
  if not (unit and unit.valid) then return end

  local original_pos = unit_data.original_position
  if not original_pos then return end -- Safety check

  local surface = unit.surface
  local player_force = unit.force

  -- Scan for enemies (units or turrets) within QRF range of the *original position*
  -- MODIFIED to use find_nearest_enemy, which respects all hostile forces (ERM compatible)
  local target = surface.find_nearest_enemy({
    position = original_pos, -- Search *from the origin*
    max_distance = QRF_RANGE,
    force = player_force, -- Finds all forces hostile to the player
    type = {"unit", "turret"} -- FIX: This filters out projectiles
  })
  
  if target then
    -- Enemies found. Engage.
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = target,
      distraction = defines.distraction.by_enemy
    })
  else
    -- No enemies found. Check if we are at our post.
    local distance_from_origin = util.distance(unit.position, original_pos)
    
    if distance_from_origin > 5 then
      -- Not at post. Return to origin.
      set_command_func(unit_data, {
        type = defines.command.go_to_location,
        destination = original_pos,
        distraction = defines.distraction.never -- Don't get distracted on the way home
      })
    else
      -- At post. Wait for a bit before scanning again.
      -- This creates the "scan loop".
      set_command_func(unit_data, {
        type = defines.command.stop,
        ticks_to_wait = SCAN_INTERVAL
      })
    end
  end
end

return QRFMode