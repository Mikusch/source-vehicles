# Driveable Vehicles for Team Fortress 2

This is a plugin that allows spawning driveable vehicles based on `prop_vehicle_driveable` in Team Fortress 2.

While this has surely been done before, the implementation of this plugin is vastly different. Instead of simulating user input on
the vehicle through the entity inputs, it forwards your user input directly to the vehicle, making driving feel incredibly smooth.

This plugin bundles the required entity fixes and a few configurable nice-to-have features.

## Features

* Fully functioning driveable vehicles based on `prop_vehicle_driveable`
* Vehicle sounds
* Entry and exit animations (experimental)
* Physics collisions and damage against other players
* High customizability through plugin configuration and ConVars

## Dependencies

* SourceMod 1.10
* [DHooks with Detour Support](https://github.com/peace-maker/DHooks2)
* [LoadSoundScript](https://github.com/haxtonsale/LoadSoundScript) (optional, used for vehicle sounds)

## Installation

1. Download the latest version from the [releases](https://github.com/Mikusch/tf-vehicles/releases) page
2. Extract the contents of the ZIP file into your server's `tf` directory
3. Restart your server or type `sm plugins load vehicles` into your server console

## Usage

There is a menu combining all of the plugin's features that can be accessed using `sm_vehicle`.

Additionally, you may use `sm_createvehicle` to create and `sm_removevehicle` to remove a vehicle. To remove all vehicles in the
map, use `sm_removeallvehicles`.

## Configuration

The vehicle configuration allows you to add custom vehicles. Each vehicle requires at least a name, model, vehicle script, and
vehicle type. More documentation and examples can be found in
the [default configuration](/addons/sourcemod/configs/vehicles/vehicles.cfg).

To learn how to create custom vehicle models and scripts, check out
the [Vehicle Scripts for Source](https://steamcommunity.com/sharedfiles/filedetails/?id=1373837962) guide on Steam.

### Example Configuration

```
"Vehicles"
{
	"0"
	{
		"id"		"example_vehicle"
		"name"		"#Vehicle_ExampleVehicle"
		"model"		"models/vehicles/example_vehicle.mdl"
		"skin"		"0"
		"vehiclescript"	"scripts/vehicles/example_vehicle.txt"
		"type"		"car_wheels"
		"downloads"
		{
			"0"	"models/vehicles/example_vehicle.dx80.vtx"
			"1"	"models/vehicles/example_vehicle.dx90.vtx"
			"2"	"models/vehicles/example_vehicle.mdl"
			"3"	"models/vehicles/example_vehicle.phy"
			"4"	"models/vehicles/example_vehicle.sw.vtx"
			"5"	"models/vehicles/example_vehicle.vvd"
			"6"	"materials/models/vehicles/example_vehicle.vmt"
			"7"	"materials/models/vehicles/example_vehicle.vtf"
		}
	}
}
```

### ConVars

The plugin creates the following console variables:

* `tf_vehicle_config ( def. "configs/vehicles/vehicles.cfg" )` - Configuration file to read all vehicles from, relative to addons/sourcemod/
* `tf_vehicle_physics_damage_modifier ( def. "1.0" )` - Modifier of impact-based physics damage against other players
* `tf_vehicle_passenger_damage_modifier ( def. "1.0" )` - Modifier of damage dealt to vehicle passengers
* `tf_vehicle_voicemenu_use ( def. "1" )` - Allow the 'MEDIC!' voice menu command to call +use
* `tf_vehicle_enable_entry_exit_anims ( def. "0" )` - Enable entry and exit animations (experimental!)

## Physics Damage

This plugin will automatically enable physics collisions and damage to allow vehicles to collide with other players.

If you intend to use these vehicles in a friendly environment without any combat aspects, set `sv_turbophysics` to `1`. It will
allow vehicles to pass through other players.

## Entry and Exit Animations

Most vehicles have entry and exit animations that make the player transition between the vehicle and the entry/exit points. The plugin
fully supports these animations.

However, since Valve never intended `prop_vehicle_driveable` to be used outside of Half-Life 2, there is code that does not
function properly in a multiplayer environment and can even cause client crashes.

Because of that, entry and exit animations on all vehicles are disabled by default and have to be manually enabled by
setting `tf_vehicle_enable_entry_exit_anims` to `1`. If you intend to use this plugin on a public server, it is **highly
recommended** to keep the animations disabled.
