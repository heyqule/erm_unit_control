-- This module handles all logic for Selection, GUI, and Control Groups.
-- These were merged into one file to solve a circular dependency crash.

local Core = require("script/uc_core")
local Commands = require("script/uc_commands")
local Indicators = require("script/uc_indicators")
-- FIX: Removed this require to break the circular dependency.
-- We will "lazy load" it inside the button click handlers.
local SharedMovement = require("script/uc_shared_movement") 
local util = require("script/script_util")

local next_command_type = Core.next_command_type
local tool_names = Core.tool_names

-- Create a main table to return all functions
local Module = {
  Selection = {},
  GUI = {},
  ControlGroups = {}
}

-- ===================================================================
-- ## SELECTION FUNCTIONS ##
-- (From uc_selection.lua)
-- ===================================================================

-- Gets the currently selected units for a player
function Module.Selection.get_selected_units(player_index)
  local script_data = storage.unit_control
  local selected = script_data.selected_units[player_index]
  if not selected then return end

  for unit_number, entity in pairs (selected) do
    if not entity.valid then
      selected[unit_number] = nil
    end
  end

  if not next(selected) then
    script_data.selected_units[player_index] = nil
    return
  end

  return selected
end

-- Removes a unit from a player's selection
function Module.Selection.deselect_units(unit_data)
  if unit_data.player then
    local script_data = storage.unit_control
    script_data.marked_for_refresh[unit_data.player] = true
    unit_data.player = nil
  end
  Indicators.clear_selection_indicator(unit_data)
  Indicators.clear_indicators(unit_data)
end

-- Clears a player's entire selection
function Module.Selection.clear_selected_units(player)
  local script_data = storage.unit_control
  local units = script_data.units
  local group = Module.Selection.get_selected_units(player.index)
  if not group then return end
  for unit_number, ent in pairs (group) do
    Module.Selection.deselect_units(units[unit_number])
    group[unit_number] = nil
  end
end

-- Helper to detect double-clicks
local is_double_click = function(event)
  local this_area = event.area
  local radius = util.radius(this_area)
  if radius > 1 then return end

  local script_data = storage.unit_control
  local last_selection_tick = script_data.last_selection_tick[event.player_index]
  script_data.last_selection_tick[event.player_index] = event.tick

  if not last_selection_tick then
    return
  end

  local click_position = this_area.left_top
  local position = script_data.last_left_click_position
  script_data.last_left_click_position = click_position

  if position and click_position then
    if Core.distance(position, click_position) > 1 then
      return
    end
  end

  local duration = event.tick - last_selection_tick
  return duration <= script_data.double_click_delay
end

-- Selects all units of the same type on screen
local select_similar_nearby = function(entity)
  local r = 32 * 4
  local origin = entity.position
  local area = {{origin.x - r, origin.y - r},{origin.x + r, origin.y + r}}
  return entity.surface.find_entities_filtered{area = area, force = entity.force, name = entity.name}
end

-- Handles adding units to a player's selection, creating the GUI if needed
function Module.Selection.process_unit_selection(entities, player)
  player.clear_cursor()
  local player_index = player.index
  local script_data = storage.unit_control
  local map = script_data.unit_unselectable
  local group = Module.Selection.get_selected_units(player_index) or {}
  local units = script_data.units
  local types = {}
  
  -- Apply selection limit
  local limit = script_data.max_selectable_units_limit
  if #entities > limit then
    -- Trim the table to only the first 'limit' units
    for i = limit + 1, #entities do
      entities[i] = nil
    end
  end
  
  for k, entity in pairs (entities) do
    local name = entity.name
    if not map[name] then
      types[name] = true
      local unit_index = entity.unit_number
      group[unit_index] = entity

      local unit_data = units[unit_index]
      if unit_data then
        Module.Selection.deselect_units(unit_data)
      else
        unit_data =
        {
          entity = entity,
          command_queue = {},
          idle = true
        }
        units[unit_index] = unit_data
      end
      unit_data.entity = entity
      unit_data.group = group
      unit_data.player = player_index
      Indicators.add_unit_indicators(unit_data)
    end
  end
  script_data.selected_units[player_index] = group

  -- Call the GUI function (now in the same file)
  Module.GUI.open_or_update_gui(player, types)
end

-- Event handler for when a player selects units
function Module.Selection.unit_selection(event)
  local entities = event.entities
  -- FIX: Don't check for nil here. An empty selection is valid.
  -- if not entities then return end 

  local append = (event.name == defines.events.on_player_alt_selected_area)
  local player = game.players[event.player_index]
  if not (player and player.valid) then return end

  if not append then
    Module.Selection.clear_selected_units(player)
  end

  if entities and #entities > 0 then
    local first_index, first = next(entities)
    if first and is_double_click(event) then
      entities = select_similar_nearby(first)
    end
    Module.Selection.process_unit_selection(entities, player)
  elseif not append then
     -- This is a drag-select that got 0 units. We must close the GUI.
     Module.GUI.open_or_update_gui(player, {}) -- Pass empty types
  end
end

-- ===================================================================
-- ## CONTROL GROUP FUNCTIONS ##
-- (From uc_control_groups.lua)
-- ===================================================================

-- Core logic for setting a control group
function Module.ControlGroups.set_control_group(event, group_number)
  local player_index = event.player_index
  local player = game.get_player(player_index)
  if not player then return end
  
  local script_data = storage.unit_control
  script_data.control_groups[player_index] = script_data.control_groups[player_index] or {}
  group_number = tonumber(group_number)
  
  local selected = Module.Selection.get_selected_units(player_index)
  
  if not selected then
    -- No units selected, so clear the control group
    script_data.control_groups[player_index][group_number] = nil
    player.play_sound({path = "utility/cannot_build"})
  else
    -- Store the list of selected unit numbers
    local unit_numbers_list = {}
    for unit_number, _ in pairs(selected) do
      unit_numbers_list[unit_number] = true
    end
    script_data.control_groups[player_index][group_number] = unit_numbers_list
    player.play_sound({path = "utility/confirm"})
  end
  
  -- Refresh the GUI if it's open
  if script_data.open_frames[player_index] and script_data.open_frames[player_index].valid then
      script_data.marked_for_refresh[player_index] = true
  end
end

-- Core logic for selecting a control group
function Module.ControlGroups.select_control_group(event, group_number)
  local player_index = event.player_index
  local player = game.get_player(player_index)
  if not player then return end
  
  group_number = tonumber(group_number)
  local script_data = storage.unit_control
  if not script_data.control_groups[player_index] or not script_data.control_groups[player_index][group_number] then
    player.play_sound({path = "utility/cannot_build"})
    return
  end

  local unit_numbers_list = script_data.control_groups[player_index][group_number]
  if not unit_numbers_list or table_size(unit_numbers_list) == 0 then
    player.play_sound({path = "utility/cannot_build"})
    return
  end

  local all_units = script_data.units
  local entities_to_select = {}
  local valid_unit_numbers = {} -- To clean dead units from the group

  for unit_number, _ in pairs(unit_numbers_list) do
    local unit_data = all_units[unit_number]
    if unit_data and unit_data.entity and unit_data.entity.valid then
      table.insert(entities_to_select, unit_data.entity)
      valid_unit_numbers[unit_number] = true
    end
  end

  -- Auto-clean the group of dead units
  script_data.control_groups[player_index][group_number] = valid_unit_numbers

  Module.Selection.clear_selected_units(player)

  if table_size(entities_to_select) > 0 then
    script_data.selected_control_groups[player_index] = group_number
    Module.Selection.process_unit_selection(entities_to_select, player)
    return entities_to_select
  else
    -- Group was full of dead units and is now empty
    script_data.control_groups[player_index][group_number] = nil
    script_data.marked_for_refresh[player_index] = true
    player.play_sound({path = "utility/cannot_build"})
    return nil
  end
end

-- Selects a group and also centers the camera on them
function Module.ControlGroups.select_control_group_and_center_camera(event, group_number)
  local player = game.get_player(event.player_index)
  if not player then return end

  local selected_entities = Module.ControlGroups.select_control_group(event, group_number)
  if not selected_entities then return end
  
  local selected_size = table_size(selected_entities)
  if selected_size > 0 then
    -- Find the center position of the group
    local total_x, total_y = 0, 0
    for _, entity in pairs(selected_entities) do
      total_x = total_x + entity.position.x
      total_y = total_y + entity.position.y
    end

    local center_pos = {
      x = total_x / selected_size,
      y = total_y / selected_size
    }

    --- Don't move camera if distance is lower than 48 tile from player position
    if util.distance(player.position, center_pos) < 48 then
      return
    end

    -- This block handles compatibility with Space Exploration/Space Age
    if remote.interfaces["space-exploration"] and remote.interfaces["space-exploration"]["remote_view_start"] then
      local surface = selected_entities[1].surface
      local zone_data = remote.call("space-exploration", "get_zone_from_surface_index", {surface_index = surface.index})

      if zone_data and zone_data.name then
        remote.call("space-exploration", "remote_view_start", {
          player = player,
          zone_name = zone_data.name,
          position = center_pos,
          freeze_history = true
        })
      else
        player.print({"ERM Unit Control: Could not find Space Exploration zone data for this surface."})
      end

    else
      local zoom = player.zoom
      player.set_controller {
        type = defines.controllers.remote,
        position = center_pos,
      }
      player.zoom = zoom
    end
  end
end

-- Allows other mods to assign a unit to a control group
function Module.ControlGroups.assign_control_group_remote(player_index, control_group_index, unit)
  if not (player_index and control_group_index and unit and unit.valid) then
    log("ERM Unit Control: assign_control_group called with invalid arguments.")
    return
  end
  
  local unit_number = unit.unit_number
  if not unit_number then
    log("ERM Unit Control: assign_control_group called on unit with no unit_number.")
    return
  end

  -- Ensure unit is registered in our mod's data
  local script_data = storage.unit_control
  if not script_data.units[unit_number] then
    local unit_data = {
        entity = unit,
        command_queue = {},
        idle = true
    }
    script_data.units[unit_number] = unit_data
  end
  control_group_index = tonumber(control_group_index)
  -- Get/Initialize Control Group table
  script_data.control_groups[player_index] = script_data.control_groups[player_index] or {}
  local player_groups = script_data.control_groups[player_index]

  player_groups[control_group_index] = player_groups[control_group_index] or {}
  local group_list = player_groups[control_group_index]

  -- Add unit to group (if not already there)
  local found = false
  if group_list[unit_number] then
    found = true
  end

  if not found then
      group_list[unit_number] = true
  end
  
  if script_data.open_frames[player_index] and script_data.open_frames[player_index].valid then
      script_data.marked_for_refresh[player_index] = true
  end
end

-- ===================================================================
-- ## GUI FUNCTIONS ##
-- (From uc_gui.lua)
-- ===================================================================

-- Gets the player's main unit control GUI frame
local get_frame = function(player_index)
  local script_data = storage.unit_control
  local frame = script_data.open_frames[player_index]
  if not (frame and frame.valid) then
    script_data.open_frames[player_index] = nil
    return
  end
  return frame
end

-- This table maps all GUI button clicks to their functions
local gui_actions =
{
  move_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_move_tool}
  end,
  patrol_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_patrol_tool}
  end,
  attack_move_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_attack_move_tool}
  end,
  attack_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_attack_tool}
  end,
  force_attack_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_force_attack_tool}
  end,
  follow_button = function(event)
    local player = game.players[event.player_index]
    if not (player and player.valid) then return end
    player.clear_cursor()
    if not player.cursor_stack then return end
    player.cursor_stack.set_stack{name = tool_names.unit_follow_tool}
  end,
  hold_position_button = function(event)
    local group = Module.Selection.get_selected_units(event.player_index)
    if not group then
      return
    end
    SharedMovement.hold_position_group(game.get_player(event.player_index), event.shift, group)
  end,
  stop_button = function(event)
    local group = Module.Selection.get_selected_units(event.player_index)
    if not group then
      return
    end
    SharedMovement.stop_group(game.get_player(event.player_index), event.shift, group)
  end,
  scout_button = function(event)
    local group = Module.Selection.get_selected_units(event.player_index)
    if not group then
      return
    end
    local append = event.shift
    local scout_queue = {command_type = next_command_type.scout}
    local script_data = storage.unit_control
    local units = script_data.units
    for unit_number, unit in pairs (group) do
      local unit_data = units[unit_number]
      if append and not unit_data.idle then
        table.insert(unit_data.command_queue, scout_queue)
      else
        Commands.set_scout_command(unit_data, false, unit_number % 120)
        Commands.set_unit_not_idle(unit_data)
      end
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,
  
  -- Button to activate 'Hunt' mode
  hunt_button = function(event)
    local group = Module.Selection.get_selected_units(event.player_index)
    if not group then return end
    
    local hunt_queue = {command_type = next_command_type.hunt}
    local script_data = storage.unit_control
    local units = script_data.units
    for unit_number, unit in pairs(group) do
      local unit_data = units[unit_number]
      unit_data.mode = "hunt"
      unit_data.original_position = nil
      unit_data.aggro_target = nil
      unit_data.command_queue = {hunt_queue}
      Commands.set_unit_not_idle(unit_data)
      Commands.process_command_queue(unit_data) -- Start the command immediately
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,

  -- Button to activate 'Perimeter' mode
  perimeter_button = function(event)
    local group = Module.Selection.get_selected_units(event.player_index)
    if not group then return end
    
    local perimeter_queue = {command_type = next_command_type.perimeter}
    local script_data = storage.unit_control
    local units = script_data.units
    for unit_number, unit in pairs(group) do
      local unit_data = units[unit_number]
      unit_data.mode = "perimeter"
      unit_data.original_position = unit.position -- Store current pos
      unit_data.command_queue = {perimeter_queue}
      Commands.set_unit_not_idle(unit_data)
      Commands.process_command_queue(unit_data) -- Start the command immediately
    end
    game.get_player(event.player_index).play_sound({path = tool_names.unit_move_sound})
  end,

  -- Button for selecting a control group from the GUI
  control_group_button = function(event, action)
    local player = game.get_player(event.player_index)
    if not player then return end
    
    local group_number = tonumber(action.group_number)

    if event.shift then
      -- Additive selection (Shift-click)
      local player_index = player.index
      local script_data = storage.unit_control
      local group_units_list = script_data.control_groups[player_index] and script_data.control_groups[player_index][group_number]
      if not group_units_list then return end 

      local current_selection_map = Module.Selection.get_selected_units(player_index) or {}
      local all_units = script_data.units
      local valid_units_to_select_map = {}

      -- Add currently selected units
      for unit_number, entity in pairs(current_selection_map) do
        if entity and entity.valid then
          valid_units_to_select_map[unit_number] = entity
        end
      end

      -- Add new group's units
      for unit_number, _ in pairs(group_units_list) do
        local unit_data = all_units[unit_number]
        if unit_data and unit_data.entity and unit_data.entity.valid then
          valid_units_to_select_map[unit_number] = unit_data.entity
        end
      end

      -- Convert map back to a list
      local entities_list = {}
      for unit_number, entity in pairs(valid_units_to_select_map) do
        table.insert(entities_list, entity)
      end
      
      Module.Selection.clear_selected_units(player) 
      
      if table_size(entities_list) > 0 then
        Module.Selection.process_unit_selection(entities_list, player)
      end

    else
      -- Regular selection (Left-click)
      Module.ControlGroups.select_control_group({player_index = player.index}, group_number)
    end
  end,

  -- Button to close the GUI
  exit_button = function(event)
    -- FIX: Removed the 'if not group then return end' check.
    -- The GUI should close even if no units are selected.
    local group = Module.Selection.get_selected_units(event.player_index)
    
    local script_data = storage.unit_control
    if group then
      local units = script_data.units
      for unit_number, entity in pairs (group) do
        Module.Selection.deselect_units(units[unit_number])
        group[unit_number] = nil
      end
      script_data.selected_units[event.player_index] = nil
    end
    
    -- Force GUI to destroy
    local frame = get_frame(event.player_index)
    if not (frame and frame.valid) then return end
    util.deregister_gui(frame, script_data.button_actions)
    frame.destroy()
    script_data.open_frames[event.player_index] = nil -- FIX: Clear the frame reference
  end,
  
  -- Button for a specific unit type inside the GUI
  selected_units_button = function(event, action)
    local unit_name = action.unit
    local group = Module.Selection.get_selected_units(event.player_index)
    if not group then return end
    local right = (event.button == defines.mouse_button_type.right)
    local left = (event.button == defines.mouse_button_type.left)
    local script_data = storage.unit_control
    local units = script_data.units

    if right then
      if event.shift then
        -- Right-shift-click: Deselect half
        local count = 0
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            count = count + 1
          end
        end
        local to_leave = math.ceil(count / 2)
        count = 0
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            if count > to_leave then
              Module.Selection.deselect_units(units[unit_number])
              group[unit_number] = nil
            end
            count = count + 1
          end
        end
      else
        -- Right-click: Deselect one
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            Module.Selection.deselect_units(units[unit_number])
            group[unit_number] = nil
            break
          end
        end
      end
    end

    if left then
      if event.shift then
        -- Left-shift-click: Deselect all of this type
        for unit_number, entity in pairs (group) do
          if entity.name == unit_name then
            Module.Selection.deselect_units(units[unit_number])
            group[unit_number] = nil
          end
        end
      else
        -- Left-click: Select *only* this type
        for unit_number, entity in pairs (group) do
          if entity.name ~= unit_name then
            Module.Selection.deselect_units(units[unit_number])
            group[unit_number] = nil
          end
        end
      end
    end
  end
}

-- Defines the visual properties (sprite, tooltip) for the buttons
local button_map =
{
  move_button = {sprite = "utility/mod_dependency_arrow", tooltip = {"tooltip." .. tool_names.unit_move_tool}, style = "shortcut_bar_button_small_green"},
  patrol_button = {sprite = "utility/refresh", tooltip = {"tooltip." .. tool_names.unit_patrol_tool}, style = "shortcut_bar_button_small_blue"},
  attack_move_button = {sprite = "utility/center", tooltip = {"tooltip." .. tool_names.unit_attack_move_tool}},
  hold_position_button = {sprite = "utility/downloading", tooltip = {"controls.hold-position"}},
  follow_button = {sprite = "item/"..tool_names.unit_follow_tool, tooltip = {"tooltip."..tool_names.unit_follow_tool}},
  stop_button = {sprite = "utility/close_black", tooltip = {"controls.stop"}, style = "shortcut_bar_button_small_red"},
  scout_button = {sprite = "utility/map", tooltip = {"controls.scout"}},
  hunt_button = {sprite = "utility/center", tooltip = {"gui.hunt-mode"}, style = "shortcut_bar_button_small_red"},
  perimeter_button = {sprite = "utility/refresh", tooltip = {"gui.perimeter-mode"}, style = "shortcut_bar_button_small_green"}
}

local check_disabled = {
  hunt_button = function(script_data) return script_data.hunting_mode_enabled == false  end,
  --- If you need to use perimeter button, swap it with the commented out code.
  perimeter_button = function(script_data) return true end -- return script_data.perimeter_mode_enabled == false end
}

-- Creates or updates the main unit control GUI for a player
function Module.GUI.make_unit_gui(player)
  local index = player.index
  local frame = get_frame(index)
  if not (frame and frame.valid) then return end
  local script_data = storage.unit_control
  util.deregister_gui(frame, script_data.button_actions)

  local group = Module.Selection.get_selected_units(index)

  -- If no units are selected, destroy the GUI
  if not group then
    script_data.last_location[index] = frame.location
    frame.destroy()
    script_data.open_frames[index] = nil -- FIX: Clear the frame reference
    return
  end

  frame.clear()
  local header_flow = frame.add{type = "flow", direction = "horizontal"}
  local label = header_flow.add{type = "label", caption = {"gui.unit-control"}}
  label.drag_target = frame
  local pusher = header_flow.add{type = "empty-widget", direction = "horizontal", style = "draggable_space_header"}
  pusher.style.horizontally_stretchable = true
  pusher.style.height = 16 * player.display_scale
  pusher.drag_target = frame
  local exit_button = header_flow.add{type = "sprite-button", style = "frame_action_button", sprite = "utility/close"}
  exit_button.style.height = 24
  exit_button.style.width = 24

  util.register_gui(script_data.button_actions, exit_button, {type = "exit_button"})

  -- Draw the control group buttons
  local player_control_groups = script_data.control_groups[index] or {}
  local all_units_data = script_data.units
  local has_control_groups = false
  local control_group_data_for_gui = {}

  -- Check groups 1-10 (10 is bound to '0')
  for i = 1, 10 do
    local unit_list = player_control_groups[i]
    if unit_list and table_size(unit_list) > 0 then
      local valid_count = 0
      -- Clean the group to get an accurate count of valid units
      for unit_number, _ in pairs(unit_list) do
        local unit_data = all_units_data[unit_number]
        if unit_data and unit_data.entity and unit_data.entity.valid then
          valid_count = valid_count + 1
        end
      end
      
      if valid_count > 0 then
        has_control_groups = true
        table.insert(control_group_data_for_gui, {number = i, count = valid_count})
      end
    end
  end

  -- Add the control group button bar to the GUI
  if has_control_groups then
    local cg_frame = frame.add{type="frame", style="inside_deep_frame", direction="vertical"}
    local cg_table = cg_frame.add{type="table", column_count=10, style="filter_slot_table"}
    
    for _, data in pairs(control_group_data_for_gui) do
      local group_number = data.number
      local group_count = data.count
      
      local signal_number = (group_number == 10) and 0 or group_number 
      local signal_sprite = "virtual-signal/signal-" .. signal_number
      local signal_tooltip = {"controls.erm-unit-control-select_control_group_" .. signal_number}

      local button = cg_table.add{
        type = "sprite-button",
        sprite = signal_sprite,
        number = group_count,
        tooltip = signal_tooltip,
        style = "slot_button"
      }
      if script_data.selected_control_groups[player.index] == group_number then
        button["style"] = "yellow_slot_button"
        script_data.selected_control_groups[player.index] = nil
      end
      util.register_gui(script_data.button_actions, button, {type = "control_group_button", group_number = group_number})
    end
  end

  -- Draw the icons for currently selected units
  local map = {}
  for unit_number, ent in pairs (group) do
    local name = ent.name
    map[name] = (map[name] or 0) + 1
  end
  local inner = frame.add{type = "frame", style = "inside_deep_frame", direction = "vertical"}
  local spam = inner.add{type = "frame"}
  local subfooter = inner.add{type = "frame", style = "subfooter_frame"}
  subfooter.style.horizontally_stretchable = true
  spam.style.minimal_height = 0
  spam.style.width = 400 * player.display_scale
  local tab = spam.add{type = "table", column_count = 10, style = "filter_slot_table"}
  local pro = prototypes.entity
  for name, count in pairs (map) do
    local ent = pro[name]
    local unit_button = tab.add{type = "sprite-button", sprite = "entity/"..name, tooltip = ent.localised_name, number = count, style = "slot_button"}
    util.register_gui(script_data.button_actions, unit_button, {type = "selected_units_button", unit = name})
  end

  -- Draw the command buttons (Move, Patrol, Hunt, etc.)
  subfooter.add{type = "empty-widget"}.style.horizontally_stretchable = true
  local butts = subfooter.add{type = "table", column_count = 10}
  
  for action, param in pairs (button_map) do
    local pass = true
    if check_disabled[action] and check_disabled[action](script_data)  then
      pass = false
    end

    if pass then
      local button = butts.add{type = "sprite-button", sprite = param.sprite, tooltip = param.tooltip, style = param.style or "shortcut_bar_button_small"}
      button.style.height = 24 * player.display_scale
      button.style.width = 24 * player.display_scale
      util.register_gui(script_data.button_actions, button, {type = action})
    end
  end
end

-- Checks if any GUIs are marked for refresh and updates them
function Module.GUI.check_refresh_gui()
  local script_data = storage.unit_control
  if not next(script_data.marked_for_refresh) then return end
  for player_index, bool in pairs (script_data.marked_for_refresh) do
    -- FIX: Check that player is valid before getting GUI
    local player = game.get_player(player_index)
    if player and player.valid then
      -- FIX: Only refresh if the frame is valid (Bug #3)
      local frame = get_frame(player_index)
      if frame and frame.valid then
        Module.GUI.make_unit_gui(player)
      end
    end
  end
  script_data.marked_for_refresh = {}
end

-- Opens the GUI for a player, creating it if it doesn't exist
function Module.GUI.open_or_update_gui(player, types)
  local player_index = player.index
  local script_data = storage.unit_control
  -- FIX: Handle deselection (Bug #1 & #2)
  if not next(types) and table_size(Module.Selection.get_selected_units(player_index) or {}) == 0 then
    -- No types and no units selected, so close the GUI.
    local frame = get_frame(player_index)
    if frame then
      script_data.last_location[player_index] = frame.location
      frame.destroy()
      script_data.open_frames[player_index] = nil
    end
    return
  end
  
  local frame = get_frame(player_index)
  
  if not frame then
    -- FIX: Check for and destroy old invalid frames
    local old_frame = script_data.open_frames[player_index]
    if old_frame and not old_frame.valid then
        old_frame.destroy()
    end
    
    -- FIX: Give the frame a name
    frame = player.gui.screen.add{type = "frame", name = "erm_unit_control_main_frame", direction = "vertical"}
    local width = (12 + 400 + 12) * player.display_scale
    local size = player.display_resolution

    -- Check if player has groups to determine extra height for the GUI
    local extra_height = 0
    local player_control_groups = script_data.control_groups[player_index]
    if player_control_groups and next(player_control_groups) then
      for i = 1, 10 do
         if player_control_groups[i] and table_size(player_control_groups[i]) > 0 then
            local has_valid_unit = false
            for unit_num, _ in pairs(player_control_groups[i]) do
              if script_data.units[unit_num] and script_data.units[unit_num].entity and script_data.units[unit_num].entity.valid then
                has_valid_unit = true
                break
              end
            end
            if has_valid_unit then
              extra_height = 40 -- Add height for one row of control group buttons
              break
            end
         end
      end
    end

    local x_position = (size.width / 2) -  (width / 2)
    local y_position = size.height  - ((200 + extra_height + (math.ceil(table_size(types) / 10) * 40)) * player.display_scale)
    if script_data.last_location[player_index] then
      frame.location = script_data.last_location[player_index]
    else
      frame.location = {x_position, y_position}
      script_data.last_location[player_index] = {x_position, y_position}
    end
    script_data.open_frames[player_index] = frame
    player.opened = frame
  end
  script_data.marked_for_refresh[player_index] = true
  Module.GUI.check_refresh_gui()
end

-- Main event handler for all GUI clicks
function Module.GUI.on_gui_click(event)
  local element = event.element
  if not (element and element.valid) then return end
  local script_data = storage.unit_control
  local player_data = script_data.button_actions[event.player_index]
  if not player_data then return end
  local action = player_data[element.index]
  if action then
    gui_actions[action.type](event, action)
    return true
  end
end

-- Main event handler for closing the GUI
function Module.GUI.on_gui_closed(event)
   -- FIX: Check if the closed GUI is ours before processing (Bug #1)
   if event.element and event.element.name == "erm_unit_control_main_frame" then
     gui_actions.exit_button(event)
   end
end


return Module