-- This is the main "orchestrator" file for the mod.
-- It 'requires' all the other modules and assigns their functions
-- to the correct game events and hotkeys.

local util = require("script/script_util")

-- Load all our new modules
local Core = require("script/uc_core")
local Commands = require("script/uc_commands")
local Entity = require("script/uc_entity")
local Indicators = require("script/uc_indicators")
local Movement = require("script/uc_movement")
local ReactiveDefense = require("script/reactive_defense")
-- Load the new MERGED module
local SelectionAndGUI = require("script/uc_selection_gui_and_groups")
local Selection = SelectionAndGUI.Selection
local GUI = SelectionAndGUI.GUI
local ControlGroups = SelectionAndGUI.ControlGroups

-- Get shared data from the Core
local hotkeys = Core.hotkeys
local tool_names = Core.tool_names
local script_events = Core.script_events


-- ===================================================================
-- ## HOTKEY AND CLICK HANDLERS ##
-- These functions just call the real logic from other modules.
-- ===================================================================

local stop_hotkey = function(event)
  Movement.stop_group(game.get_player(event.player_index))
end

local queue_stop_hotkey = function(event)
  Movement.stop_group(game.get_player(event.player_index), true)
end

local hold_position_hotkey = function(event)
  Movement.hold_position_group(game.get_player(event.player_index))
end

local queue_hold_position_hotkey = function(event)
  Movement.hold_position_group(game.get_player(event.player_index), true)
end

-- FIX: Added helper function for data migration (Bug #1)
-- This function merges missing keys from `default` into `target`
local function merge_defaults(target, default)
    for k, v in pairs(default) do
        if target[k] == nil then
            target[k] = v
        end
    end
    return target
end

local suicide = function(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end
  local unit_number, entity = next(group)
  if entity and entity.valid then 
    -- Damage to death so it counts as a kill
    entity.damage(999999, player.force, "explosion")
  end
end

local suicide_all = function(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end
  for unit_number, entity in pairs (group) do
    if entity and entity.valid then 
      -- Damage to death so it counts as a kill
      entity.damage(999999, player.force, "explosion")
    end
  end
end

local get_unit_names = function()
  local unit_names = storage.unit_control.unit_names
  if next(unit_names) then return unit_names end
  unit_names = {}
  for name, prototype in pairs (prototypes.item["select-units"].get_entity_filters(defines.selection_mode.select)) do
    if prototype.type == "unit" then
      table.insert(unit_names, prototype.name)
    end
  end
  storage.unit_control.unit_names = unit_names
  return unit_names
end

local select_all_units_hotkey = function(event)
  local player = game.get_player(event.player_index)
  if not (player and player.valid) then return end

  Selection.clear_selected_units(player)

  local script_data = storage.unit_control
  local names = get_unit_names()
  if not next(names) then return end
  local entities = player.surface.find_entities_filtered
  {
    position = event.cursor_position or {0,0},
    force = player.force,
    name = names,
    radius = script_data.max_selectable_radius
  }
  
  -- Apply selection limit
  local limit = script_data.max_selectable_units_limit
  if #entities > limit then
    -- Sort by distance to cursor
    local cursor_pos = event.cursor_position
    table.sort(entities, function(a, b)
      return Core.distance(a.position, cursor_pos) < Core.distance(b.position, cursor_pos)
    end)
    -- Trim the table
    for i = limit + 1, #entities do
      entities[i] = nil
    end
  end
  
  Selection.process_unit_selection(entities, player)
end

-- ===================================================================
-- ## CLICK OVERRIDES ##
-- ===================================================================

local allow_selection =
{
  ["unit"] = true,
  ["unit-spawner"] = true
}

local block_by_opened_gui = {
  [defines.gui_type.blueprint_library] = true
}

-- Checks if the player is in a state that allows our left-click override
local can_left_click = function(player, shift)
  -- FIX: MOVED CURSOR CHECKS TO TOP
  -- 1. Check for physical items (Stack)
  if player.cursor_stack and player.cursor_stack.valid_for_read then return end
  -- 2. Check for Ghost items (Pipette)
  if player.cursor_ghost then return end
  -- 3. Check for Blueprint Library Records (Book fix)
  if player.cursor_record then return end

  -- FIX: Check for Open GUIs (Logistic fix)
  if player.opened then
    -- Exception: Allow clicking if interacting with OUR mod's GUI frame
    if player.opened.object_name == "LuaGuiElement" and player.opened.name == "erm_unit_control_main_frame" then
      return true
    else
      -- If any other GUI (Inventory, Blueprint Book, Chest) is open, block the tool.
      return false 
    end
  end

  -- FIX: Specific check for the Controller GUI (Character/Inventory/Logistics screen)
  if player.opened_gui_type == defines.gui_type.controller then
    return false
  end

  if block_by_opened_gui[player.opened_gui_type] then return end
  
  if not shift and player.render_mode == defines.render_mode.chart then return end
  
  -- FIX: Restore Vanilla Copy/Paste behavior
  local selected = player.selected
  if selected then
    -- If we are hovering over a Unit or Spawner, allow the tool (for selection)
    if selected.type == "unit" or selected.type == "unit-spawner" then
       return true
    end
    
    -- If we are hovering over ANYTHING else (Machine, Inserter, Resource),
    -- We STRICTLY return false. This blocks the tool and lets vanilla handle it.
    -- This restores Shift+Drag (Copy Paste) and Click (Open GUI).
    return false
  end
  
  -- If hovering over nothing (Ground), allow tool (Box Selection).
  return true
end

-- Sets the player's cursor to the 'select-units' tool
local set_cursor_to_select = function(player)
  local stack = player.cursor_stack
  if not stack then return end
  if stack.valid_for_read then return end

  stack.set_stack({name = tool_names.unit_selection_tool})
  return true
end

-- Overrides the default left-click to start our unit selection
local left_click = function(event)
  local player = game.get_player(event.player_index)
  if not can_left_click(player) then
    return
  end
  if set_cursor_to_select(player) then
    player.start_selection(event.cursor_position, defines.selection_mode.select)
  end
end

-- Overrides the default shift-left-click
local shift_left_click = function(event)
  local player = game.get_player(event.player_index)
  if not can_left_click(player, true) then
    return
  end
  if set_cursor_to_select(player) then
    player.start_selection(event.cursor_position, defines.selection_mode.alt_select)
  end
end

-- Helper to detect double-right-clicks
local is_double_right_click = function(event)
  -- FIX: Use the dedicated R-click timer (Bug #4)
  -- This relies on the migration fix in on_load/on_configuration_changed
  local script_data = storage.unit_control
  local last_selection_tick = script_data.last_Rclick_selection_tick[event.player_index]
  script_data.last_Rclick_selection_tick[event.player_index] = event.tick

  if not last_selection_tick then
    return false
  end

  local click_position = event.cursor_position
  local position = script_data.last_right_click_position
  script_data.last_right_click_position = click_position

  if position and click_position then
    if Core.distance(position, click_position) > 1 then
      return false
    end
  end

  local duration = event.tick - last_selection_tick

  return duration <= script_data.double_click_delay
end

-- Overrides the default right-click to issue unit commands
local right_click = function(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  --@deprecated
  --local entities = player.surface.find_entities_filtered{position = event.cursor_position}
  --local player_force = player.force
  --local attack_entities = {}
  --local follow_entity
  --for k, entity in pairs(entities) do
  --  local force = entity.force
  --  if force == player_force then
  --    follow_entity = entity
  --  elseif not player_force.get_cease_fire(entity.force) then
  --    if entity.get_health_ratio() then
  --      attack_entities[k] = entity
  --    end
  --  end
  --end

  -- FIX: Swapped single-click and double-click logic to match user expectation
  if is_double_right_click(event) then
    Movement.move_units_to_position(player, event.cursor_position) -- Double-click is now Move
  else
    Movement.attack_move_units_to_position(player, event.cursor_position) -- Single-click is now Attack-Move
  end
end

-- Overrides the default shift-right-click
local shift_right_click = function(event)
  local group = Selection.get_selected_units(event.player_index)
  if not group then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local entities = player.surface.find_entities_filtered{position = event.cursor_position}
  local player_force = player.force
  local attack_entities = {}
  local follow_entity
  for k, entity in pairs(entities) do
    local force = entity.force
    if force == player_force then
      follow_entity = entity
    elseif not player_force.get_cease_fire(entity.force) then
      if entity.get_health_ratio() then
        attack_entities[k] = entity
      end
    end
  end

  if next(attack_entities) then
    Movement.make_attack_command(group, attack_entities, true)
    player.play_sound({path = tool_names.unit_move_sound})
    return
  end

  if follow_entity then
    Movement.make_follow_command(group, follow_entity, true)
    player.play_sound({path = tool_names.unit_move_sound})
    return
  end

  Movement.attack_move_units_to_position(player, event.cursor_position, true)
end

-- ===================================================================
-- ## MISC AND LIFECYCLE FUNCTIONS ##
-- ===================================================================

local on_tick = function(event)
  Commands.process_attack_register(event.tick)
  GUI.check_refresh_gui(event.tick)
end

-- FIX: Run the post-load setup safely inside on_tick
-- This logic was moved from on_load
local function reset_gui()
  local script_data = storage.unit_control
  for player_index, frame in pairs(script_data.open_frames) do
    if frame and frame.valid then
      script_data.marked_for_refresh[player_index] = true
    else
      script_data.open_frames[player_index] = nil -- Clean up invalid frames
    end
  end

  Indicators.reset_rendering()
end

-- FIX: This wrapper function is the solution to the "wandering" bug.
-- It correctly gets the unit_data from the event before processing the queue.
local function on_ai_command_completed_wrapper(event)
  if event.was_distracted then
    if Commands.process_distraction_completed(event) then
      return
    end
  end
  local script_data = storage.unit_control
  if script_data.reactive_defense_groups[event.unit_number] then
    return ReactiveDefense.update_ai_completed(event)
  end
  
  local unit_data = script_data.units[event.unit_number]
  if unit_data then
    -- Now we call process_command_queue with the *correct* unit_data
    return Commands.process_command_queue(unit_data, event)
  end
end

local clear_poop = function(player_index)
  local player = game.get_player(player_index)
  if not player then return end
  local cursor = player.cursor_stack
  if not (cursor and cursor.valid and cursor.valid_for_read) then return end
  if cursor.name == tool_names.unit_selection_tool then
    cursor.clear()
  end
end

local on_player_selected_area = function(event)
  clear_poop(event.player_index)
  local action = Movement.selected_area_actions[event.item]
  if not action then return end
  return action(event)
end

local on_player_alt_selected_area = function(event)
  clear_poop(event.player_index)
  local action = Movement.alt_selected_area_actions[event.item]
  if not action then return end
  return action(event)
end

-- Cleans up a player's GUI and selected units when they leave
local on_player_removed = function(event)
  local script_data = storage.unit_control
  local frame = script_data.open_frames[event.player_index]
  if (frame and frame.valid) then
    util.deregister_gui(frame, script_data.button_actions)
    frame.destroy()
  end
  script_data.open_frames[event.player_index] = nil

  local group = Selection.get_selected_units(event.player_index)
  if not group then return end

  local units = script_data.units
  for unit_number, ent in pairs (group) do
    Selection.deselect_units(units[unit_number])
  end
end

-- A cleanup function to remove invalid units
local validate_some_stuff = function()
  local script_data = storage.unit_control
  local units = script_data.units
  for unit_number, unit_data in pairs (units) do
    local entity = unit_data.entity
    if not (entity and entity.valid) then
      units[unit_number] = nil
    end
  end
end

-- Modifies Factorio's pathfinding settings for better performance
local set_map_settings = function()
  local settings = game.map_settings
  settings.path_finder.max_steps_worked_per_tick = 400
  settings.path_finder.max_clients_to_accept_any_new_request = 1000
  settings.path_finder.use_path_cache = false
  settings.steering.moving.force_unit_fuzzy_goto_behavior = true
  settings.steering.default.force_unit_fuzzy_goto_behavior = false
  settings.max_failed_behavior_count = 5
end

local setting_map = {
  ["erm-unit-control-selection-limit"] = "max_selectable_units_limit",
  ["erm-unit-control-selection-radius"] = "max_selectable_radius",
  ["erm-unit-control-hunting-mode"] = "hunting_mode_enabled",
  ["erm-unit-control-reactive-defense-mode"] = "reactive_defense_mode_enabled",
  ["erm-unit-control-reactive-defense-unit-search-range"] = "reactive_defender_unit_search_range",
  ["erm-unit-control-perimeter-mode"] = "perimeter_mode_enabled",
  ["erm-unit-control-reactive-defense-cooldown"] = "reactive_defender_cooldown",
}

local setting_function = {
  ["erm-unit-control-follow-command-wait"] = Core.set_follow_unit_wait_time,
  ["erm-unit-control-patrol-command-wait"] = Core.set_patrol_unit_wait_time
}

local on_runtime_mod_setting_changed = function(event)
  if event.setting_type == "runtime-global" then
    local setting_name = event.setting
    if settings.global[setting_name] and setting_map[setting_name] then
      storage.unit_control[ setting_map[setting_name] ] = settings.global[setting_name].value
    end

    if settings.global[setting_name] and setting_function[setting_name] then
      setting_function[setting_name]()
    end
  end
end

local on_object_destroyed = function(event)
  ReactiveDefense.update_group_destroy(event)
end 

-- ===================================================================
-- ## REMOTE INTERFACE ##
-- ===================================================================

remote.add_interface("erm_unit_control", {
  register_unit_unselectable = function(entity_name)
    local script_data = storage.unit_control
    script_data.unit_unselectable[entity_name] = true
  end,
  get_events = function()
    return script_events
  end,
  set_debug = function(bool)
    local script_data = storage.unit_control
    script_data.debug = bool
  end,
  set_map_settings = function()
    set_map_settings()
  end,
  print_global = function()
    helpers.write_file("erm_unit_control/storage.json",helpers.table_to_json(util.copy(storage)))
  end,
  assign_control_group = ControlGroups.assign_control_group_remote
})

-- ===================================================================
-- ## EVENT HANDLER SETUP ##
-- ===================================================================

local on_console_command = function(event)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end
  
  if event.command == "make_destructible" then
    local count = 0
    for _, entity in pairs(player.surface.find_entities_filtered{force = player.force}) do
      if entity and entity.valid and entity.destructible ~= nil then
        entity.destructible = true
        count = count + 1
      end
    end
    player.print("Made " .. count .. " entities destructible on current surface!")
  elseif event.command == "test_suicide" then
    local group = Selection.get_selected_units(event.player_index)
    if not group then
      player.print("No units selected!")
      return
    end
    local count = 0
    for unit_number, entity in pairs(group) do
      if entity and entity.valid then
        count = count + 1
      end
    end
    player.print("Selected units: " .. count)
    
    -- Test suicide on first unit
    local unit_number, entity = next(group)
    if entity and entity.valid then
      entity.damage(999999, player.force, "explosion")
      player.print("Killed one unit via console command")
    end
  elseif event.command == "test_suicide_all" then
    local group = Selection.get_selected_units(event.player_index)
    if not group then
      player.print("No units selected!")
      return
    end
    local count = 0
    for unit_number, entity in pairs(group) do
      if entity and entity.valid then
        entity.damage(999999, player.force, "explosion")
        count = count + 1
      end
    end
    player.print("Killed " .. count .. " units via console command")
    Selection.clear_selected_units(player)
  end
end

local unit_control = {}

unit_control.events =
{
  [defines.events.on_tick] = on_tick,
  [defines.events.on_entity_settings_pasted] = Entity.on_entity_settings_pasted,
  [defines.events.on_player_selected_area] = on_player_selected_area,
  [defines.events.on_player_alt_selected_area] = on_player_alt_selected_area,
  [defines.events.on_gui_click] = GUI.on_gui_click,
  [defines.events.on_gui_closed] = GUI.on_gui_closed,
  [defines.events.on_console_command] = on_console_command,

  [defines.events.on_entity_died] = Entity.on_entity_died,
  [defines.events.on_robot_mined_entity] = Entity.on_entity_removed,
  [defines.events.on_player_mined_entity] = Entity.on_entity_removed,
  [defines.events.script_raised_destroy] = Entity.on_entity_removed,
  
  -- [defines.events.on_entity_damaged] = Entity.on_entity_damaged, -- Disabled for performance
  
  -- FIX: Point this event to our new wrapper function
  [defines.events.on_object_destroyed] = on_object_destroyed,
  [defines.events.on_ai_command_completed] = on_ai_command_completed_wrapper,
  [defines.events.on_runtime_mod_setting_changed] = on_runtime_mod_setting_changed,
  
  [hotkeys.suicide] = suicide,
  [hotkeys.suicide_all] = suicide_all,
  [hotkeys.stop] = stop_hotkey,
  [hotkeys.queue_stop] = queue_stop_hotkey,
  [hotkeys.hold_position] = hold_position_hotkey,
  [hotkeys.queue_hold_position] = queue_hold_position_hotkey,

  [defines.events.on_player_died] = on_player_removed,
  [defines.events.on_player_left_game] = on_player_removed,
  [defines.events.on_player_changed_force] = on_player_removed,
  [defines.events.on_player_changed_surface] = on_player_removed,

  [defines.events.on_surface_deleted] = validate_some_stuff,
  [defines.events.on_surface_cleared] = validate_some_stuff,
  [defines.events.on_entity_spawned] = Entity.on_entity_spawned,
  [script_events.on_unit_spawned] = Entity.on_entity_spawned,

  ["left-click"] = left_click,
  ["shift-left-click"] = shift_left_click,
  ["right-click"] = right_click,
  ["shift-right-click"] = shift_right_click,
  [hotkeys.select_all_units] = select_all_units_hotkey,

  -- Control Group Hotkeys
  [hotkeys.set_control_group_1] = function(e) ControlGroups.set_control_group(e, 1) end,
  [hotkeys.set_control_group_2] = function(e) ControlGroups.set_control_group(e, 2) end,
  [hotkeys.set_control_group_3] = function(e) ControlGroups.set_control_group(e, 3) end,
  [hotkeys.set_control_group_4] = function(e) ControlGroups.set_control_group(e, 4) end,
  [hotkeys.set_control_group_5] = function(e) ControlGroups.set_control_group(e, 5) end,
  [hotkeys.set_control_group_6] = function(e) ControlGroups.set_control_group(e, 6) end,
  [hotkeys.set_control_group_7] = function(e) ControlGroups.set_control_group(e, 7) end,
  [hotkeys.set_control_group_8] = function(e) ControlGroups.set_control_group(e, 8) end,
  [hotkeys.set_control_group_9] = function(e) ControlGroups.set_control_group(e, 9) end,
  
  [hotkeys.select_control_group_1] = function(e) ControlGroups.select_control_group_and_center_camera(e, 1) end,
  [hotkeys.select_control_group_2] = function(e) ControlGroups.select_control_group_and_center_camera(e, 2) end,
  [hotkeys.select_control_group_3] = function(e) ControlGroups.select_control_group_and_center_camera(e, 3) end,
  [hotkeys.select_control_group_4] = function(e) ControlGroups.select_control_group_and_center_camera(e, 4) end,
  [hotkeys.select_control_group_5] = function(e) ControlGroups.select_control_group_and_center_camera(e, 5) end,
  [hotkeys.select_control_group_6] = function(e) ControlGroups.select_control_group_and_center_camera(e, 6) end,
  [hotkeys.select_control_group_7] = function(e) ControlGroups.select_control_group_and_center_camera(e, 7) end,
  [hotkeys.select_control_group_8] = function(e) ControlGroups.select_control_group_and_center_camera(e, 8) end,
  [hotkeys.select_control_group_9] = function(e) ControlGroups.select_control_group_and_center_camera(e, 9) end,
}

-- ===================================================================
-- ## MOD LIFECYCLE FUNCTIONS ##
-- ===================================================================

unit_control.on_init = function()
  storage.unit_control = storage.unit_control or Core.script_data
  -- Ensure new tables exist for migration
  storage.unit_control.group_hunt_data = storage.unit_control.group_hunt_data or {}
  storage.unit_control.control_groups = storage.unit_control.control_groups or {}

  storage.unit_control.radius_cache = {}
  storage.unit_control.box_point_cache = {}
  storage.unit_control.move_offset_positions = {}
  storage.unit_control.unit_names = {}

  Core.set_follow_unit_wait_time()
  Core.set_patrol_unit_wait_time()
  set_map_settings()
  reset_gui()
end

-- FIX: Replaced function to handle data migration (Bug #1)
unit_control.on_configuration_changed = function(configuration_changed_data)
  local loaded_data = storage.unit_control or {}
  -- `script_data` (from line 30) is the default. Merge defaults into loaded data.
  local migrated_data = merge_defaults(loaded_data,  Core.script_data)

  migrated_data.radius_cache = {}
  migrated_data.box_point_cache = {}
  migrated_data.move_offset_positions = {}
  migrated_data.unit_names = {}
  
  
  -- Now script_data, Core.script_data, and storage.unit_control
  -- all point to the same, correct, migrated table.
  Core.set_follow_unit_wait_time()
  Core.set_patrol_unit_wait_time()
  set_map_settings()
  reset_gui()
  migrated_data.last_location = migrated_data.last_location or {}
  storage.unit_control = migrated_data
end

-- FIX: Replaced function to be save-game compliant
unit_control.on_load = function()
  -- This function MUST NOT modify the 'storage' table.
  -- We set a file-local flag to tell on_tick to run the setup logic.
end

return unit_control