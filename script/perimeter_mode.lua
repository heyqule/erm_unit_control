local util = require("script/script_util") -- <-- ADD THIS LINE
local PerimeterMode = {}

--[[
Brainstorm.

- When a valid radar calls the on_sector_scanned event. A valid radar is any radar with max_distance_of_sector_revealed > 10.
- Check whether enemy is found in the scanned chunk
- If an enemy entity is found within the scanned chunk, check whether there are units near the radar (within max_selectable_radius tiles).
- If there are units, select them (up to max group limit) and form a group.
- Once group is formed, give them a chain command 
  1. go to / attack target location, distract by enemy,
  2. wander 5 seconds, distract by enemy 
  3. go to radar location, distract by enemy,
- After the radar issue the command, it attach a sweeper icon sprite and distance line to a unit in map mode. (refer to reactive defense)
- Attach draw icon and line object to radar. When the radar has renderObjectIds, it can no longer call unit to attack new chunk until the current group is done. (to preserve performance and avoid conflicts)
- Refer to reactive defense on unit group handling for return home command after failure and data clean up.

]]--

-- How far the unit will scan for enemies from its original post
local PERIMETER_RANGE = 160

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
    set_command_func(unit_data, {
      type = defines.command.attack,
      target = target,
      distraction = defines.distraction.by_enemy
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