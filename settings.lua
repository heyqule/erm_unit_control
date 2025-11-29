-- This adds the new map setting for the selection limit
data:extend({
  {
    type = "int-setting",
    name = "erm-unit-control-selection-limit",
    setting_type = "runtime-global", -- "map" is not a valid type, "runtime-global" is what we want
    default_value = 100,
    allowed_values = { 20, 30, 40, 50, 70, 100, 150, 200, 250, 300},
    order = "a-erm-a" -- Puts it near the top of the mod settings list
  },
  {
    type = "int-setting",
    name = "erm-unit-control-selection-radius",
    setting_type = "runtime-global",
    default_value = 100,
    allowed_values = { 64, 100, 160, 200, 320},
    order = "a-erm-a1"
  },
  {
    type = "int-setting",
    name = "erm-unit-control-follow-command-wait",
    setting_type = "runtime-global",
    default_value = 180,
    allowed_values = {60, 90, 120, 150, 180},
    order = "a-erm-a2"
  },
  {
    type = "int-setting",
    name = "erm-unit-control-patrol-command-wait",
    setting_type = "runtime-global",
    default_value = 600,
    allowed_values = {180, 300, 480, 600, 720, 900},
    order = "a-erm-a3"
  },
  {
    type = "bool-setting",
    name = "erm-unit-control-enable-suicide-gui",
    setting_type = "runtime-global",
    default_value = true,
    order = "a-erm-b"
  },
  {
    type = "bool-setting",
    name = "erm-unit-control-hunting-mode",
    setting_type = "runtime-global",
    default_value = false,
    order = "a-erm-c"
  },
  {
    type = "bool-setting",
    name = "erm-unit-control-reactive-defense-mode",
    setting_type = "runtime-global",
    default_value = false,
    order = "a-erm-d"
  },
  {
    type = "int-setting",
    name = "erm-unit-control-reactive-defense-unit-search-range",
    setting_type = "runtime-global",
    default_value = 160,
    allowed_values = {96, 160, 224, 320, 480, 640},
    order = "a-erm-d1"
  },
  {
    type = "int-setting",
    name = "erm-unit-control-reactive-defense-cooldown",
    setting_type = "runtime-global",
    default_value = 5,
    allowed_values = {1, 2, 3, 5},
    order = "a-erm-d2"
  },
  {
    type = "bool-setting",
    name = "erm-unit-control-perimeter-mode",
    setting_type = "runtime-global",
    default_value = false,
    order = "a-erm-e"
  },
})

