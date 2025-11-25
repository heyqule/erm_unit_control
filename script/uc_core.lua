-- This file holds the "global" state for the unit control script.
-- By putting it in its own file, all other modules can 'require' it
-- to access the same script_data table, tool_names, etc.

local names = require("shared")

local Core = {}

-- Get the tool names from the data phase (via shared.lua)
Core.tool_names = names.unit_tools

-- ===================================================================
-- ## ON_LOAD HOTKEY FIX ##
-- This is a fix for loading saved games.
-- We must re-define hotkey names here because loading a save doesn't
-- re-run the data phase, so `names.hotkeys` would be empty.
-- ===================================================================
if not names.hotkeys then names.hotkeys = {} end
Core.hotkeys = names.hotkeys

for i = 0, 9 do
  local key_num_str = tostring(i)
  Core.hotkeys["select_control_group_" .. key_num_str] = "erm-unit-control-select_control_group_" .. key_num_str
  Core.hotkeys["set_control_group_" .. key_num_str] = "erm-unit-control-set_control_group_" .. key_num_str
end
-- ===================================================================
-- ## END OF ON_LOAD FIX ##
-- ===================================================================

-- This is the main global table that holds all the mod's
-- active data and state, like selected units, groups, etc.
Core.script_data =
{
  button_actions = {},
  groups = {},
  selected_units = {},
  open_frames = {},
  units = {},
  indicators = {},
  unit_unselectable = {},
  debug = false,
  marked_for_refresh = {},
  last_selection_tick = {},
  last_right_click_position = nil,
  last_Rclick_selection_tick = {}, -- FIX: Added for Bug #4
  target_indicators = {},
  attack_register = {},
  last_location = {},
  control_groups = {},
  selected_control_groups = {},
  double_click_delay = 30,
  max_selectable_units_limit = settings.global["erm-unit-control-selection-limit"].value,
  max_selectable_radius = settings.global["erm-unit-control-selection-radius"].value,
  max_follow_unit_wait_time = settings.global["erm-unit-control-follow-command-wait"].value,
  min_follow_unit_wait_time = settings.global["erm-unit-control-follow-command-wait"].value - 30,
  max_patrol_unit_wait_time = settings.global["erm-unit-control-patrol-command-wait"].value,
  min_patrol_unit_wait_time = settings.global["erm-unit-control-patrol-command-wait"].value - 60,
  --- Caches
  --- These need to be reset during on_init or on_config_changed because of mod / mod setting changes.
  radius_cache = {},
  box_point_cache = {},
  move_offset_positions = {},
  unit_names = {},

  --- Data for hunt mode
  group_hunt_data = {},
  hunting_mode_enabled = settings.global["erm-unit-control-hunting-mode"].value,
  
  --- Data for reactive defense
  reactive_defense_mode_enabled = settings.global["erm-unit-control-reactive-defense-mode"].value,
  reactive_defense_unit_search_range = settings.global["erm-unit-control-reactive-defense-unit-search-range"].value,
  reactive_defender_cooldown = settings.global["erm-unit-control-reactive-defense-cooldown"].value,
  next_reactive_defense_garbage_collect_tick = 0,
  reactive_defense_groups = {},
  reactive_defense_cooldown = {},
  
  
  --- Data for perimeter
  perimeter_mode_enabled = settings.global["erm-unit-control-perimeter-mode"].value,
}

Core.set_follow_unit_wait_time = function()
    storage.unit_control.max_follow_unit_wait_time = settings.global["erm-unit-control-follow-command-wait"].value
    storage.unit_control.min_follow_unit_wait_time = settings.global["erm-unit-control-follow-command-wait"].value - 30
end

Core.set_patrol_unit_wait_time = function()
  storage.unit_control.max_patrol_unit_wait_time = settings.global["erm-unit-control-patrol-command-wait"].value
  storage.unit_control.min_patrol_unit_wait_time = settings.global["erm-unit-control-patrol-command-wait"].value - 60
end


-- A simple 'enum' to define our custom command types
Core.next_command_type =
{
  move = 1,
  patrol = 2,
  scout = 3,
  idle = 4,
  attack = 5,
  follow = 6,
  hold_position = 7,
  hunt = 8,
  perimeter = 10
}

-- Custom event names for the mod
Core.script_events =
{
  on_unit_spawned = script.generate_event_name()
}

Core.get_storage_data =  function()
  return storage.unit_control
end

-- Simple helper for distance
Core.distance = function(position_1, position_2)
  local d_x = position_2.x - position_1.x
  local d_y = position_2.y - position_1.y
  return ((d_x * d_x) + (d_y * d_y)) ^ 0.5
end

-- Gets a unique ID number for a unit
local delim = "."
local concat = table.concat
Core.get_unit_number = function(entity)
  return entity.unit_number or concat{entity.surface.index, delim, entity.position.x, delim, entity.position.y}
end

-- A custom print function for debugging
-- Only prints if Core.script_data.debug is true
Core.print = function(string)
  if not Core.script_data.debug then return end
  local tick = game.tick
  log(tick.." | "..string)
  game.print(tick.." | "..string)
end

return Core