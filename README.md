# Driveable Vehicles for Team Fortress 2 
This is a plugin that allows spawning driveable vehicles based on `prop_vehicle_driveable` in Team Fortress 2.

While this has surely been done before, the implementation of this plugin is vastly different.
Instead of simulating user input on the vehicle through the entity I/O system, it forwards your user input directly to the vehicle, making driving feel incredibly smooth.

This plugin bundles the required entity fixes and a few configurable nice-to-have features.

## Features
* Fully functioning driveable vehicles based on `prop_vehicle_driveable`
* Vehicle sounds
* Entry and exit animations
* Physics collisions and damage against other players
* Highly customizable through plugin configuration and ConVars

## Dependencies
* SourceMod 1.10
* [DHooks with Detour Support](https://github.com/peace-maker/DHooks2)
* [LoadSoundScript](https://github.com/haxtonsale/LoadSoundScript) (optional, used for vehicle sounds)

## Installation
1. Download the latest version from the [releases](https://github.com/Mikusch/tf-vehicles/releases) page
2. Extract the contents of the archive into your server directory
3. Restart your server or type `sm plugins load vehicles` into your server console

## Usage
There is a menu combining all of the plugin's features that can be accessed using `sm_vehicle`.

Additionally, you may use `sm_createvehicle` to create and `sm_removevehicle` to remove a vehicle. To remove all vehicles in the map, use `sm_removeallvehicles`.

## Configuration
The vehicle configuration allows you to add your own vehicles. Each vehicle requires at least a name, model, vehicle script, and vehicle type.
More documentation and examples can be found in the [default configuration](/addons/sourcemod/configs/vehicles/vehicles.cfg).

To learn how to create custom vehicle models and scripts, check out the [Vehicle Scripts for Source](https://steamcommunity.com/sharedfiles/filedetails/?id=1373837962) guide on Steam.

**Example:**
```
"Vehicles"
{
	"0"
	{
		"id"			"example_vehicle"
		"name"			"#Vehicle_ExampleVehicle"
		"model"			"models/vehicles/example_vehicle.mdl"
		"skin"			"0"
		"vehiclescript"	"scripts/vehicles/example_vehicle.txt"
		"type"			"car_wheels"
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

## Physics Damage
This plugin will automatically enable physics collisions and damage to allow vehicles to collide with other players.

If you intend to use these vehicles in a friendly environment without any combat aspects, make sure to set `sv_turbophysics` to `1`. It will allow vehicles to pass through other players.
