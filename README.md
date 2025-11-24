This is a fork of Klonan's Unit Control.  It has updated for 2.0.  New features have been added in 1.1 build.

It primary targets ERM controllable units.  But it should work for 3rd party unit that support original unit control.

### New Features: (Developed by [Hawke] & heyqule)
- Manage up to 9 control groups with hotkeys.
- Configurable max group selection size, default 100 units, up to 300. (configurable in map settings)
- Configurable max group selection radius, default 100 tiles, up to 320. (configurable in map settings)
- Hunting Strategy - command a group to perform search and destroy operation
- Reactive Defensive Strategy - When a player entity killed, the nearby units will come to aid, then return to original location once the operation is completed.
- Perimeter Defending Strategy - When radar scan an chunk with enemy buildings, The nearby units will go attack that enemy base, then return to radar.

### How to use:
- **Select all unit in X radius:** Shift+Alt+left click
- **Select all unit of same type in X radius:** Double left click on a unit.
- **Attack Move:**  Select unit > right click on destination. (orange dotted line indicator)
- **Go to destination(non-attack move):**  Select unit > double right click on destination. (green dotted line indicator)
- **Multiple Waypoints attack move:** Select unit > hold shift and right click on destinations.
- **Patrol:** Select units > click add patrol waypoint button > right click destination. (shift and right click for multiple destinations).
- **Scout:** select unit, click scout button and they will move in all directions
- **Follow Target** select unit, click follow target button, click on any friendly entity with health and they will follow.  Alt: Shift + right-click on the follow target.
- **Hunting Mode** select unit, click hunting mode button, they will search nearby enemy entity to kill.
- **Reactive Defense** Move units to an active warzone. When certain building type dies nearby, they'll march to that location, then return to original location (with small offset) after mission completed.
- **Perimeter Defense** WIP.


Additional Asset Credit:
https://www.flaticon.com/free-icon/shield_861377  Shield Icon


Fun recommendation:
https://mods.factorio.com/mod/kittycat  