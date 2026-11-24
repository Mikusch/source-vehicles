# Driveable Vehicles for Source Engine Multiplayer

This is a SourceMod plugin that allows spawning driveable vehicles based on `prop_vehicle_driveable` in Source engine
multiplayer games.

**List of supported games:**

* Team Fortress 2
* Counter-Strike: Source
* Black Mesa
* Half-life 2: Deathmatch
* Left 4 Dead 2 (Windows, see [notes](#left-4-dead-2))

This plugin bundles the required entity fixes, and a few configurable nice-to-have features.

## Features

* Fully functioning driveable vehicles based on `prop_vehicle_driveable`
* Vehicle sounds
* Entry and exit animations (experimental)
* Physics collisions and damage against other players
* High customizability through plugin configuration and ConVars

## Dependencies

* SourceMod 1.12
* [LoadSoundScript](https://github.com/haxtonsale/LoadSoundScript) (optional, used for vehicle sounds)

## Installation

1. Download the latest version from the [releases](https://github.com/Mikusch/source-vehicles/releases) page
2. Extract the contents of the ZIP file into your server's game directory
3. Restart your server or type `sm plugins load vehicles` into your server console

## Usage

The easiest way to spawn vehicles is using the `sm_vehicle` command.
This requires vehicles to be added to the [vehicle configuration](/addons/sourcemod/configs/vehicles/vehicles.cfg).

If you have access to `ent_create`, you can spawn vehicle entities without having to add them to the configuration.
The plugin automatically detects and hooks any vehicle spawned into the map.
If a configuration entry matches both the vehicle model and vehicle script, its properties will be applied accordingly.

**Example:**

`ent_create prop_vehicle_driveable model "models/buggy.mdl" VehicleScript "scripts/vehicles/jeep_test.txt"`

To enter a vehicle, look at it and use the `+use` console command.

## Configuration

The vehicle configuration allows you to add custom vehicles. Each vehicle requires at least a name, model, vehicle
script, and vehicle type. More documentation and examples can be found in
the [default configuration](/addons/sourcemod/configs/vehicles/vehicles.cfg).

To learn how to create custom vehicle models and scripts, check out
the [Vehicle Scripts for Source](https://steamcommunity.com/sharedfiles/filedetails/?id=1373837962) guide on Steam.

### Example Configuration

```
"Vehicles"
{
	"example_vehicle"
	{
		"name"					"#Vehicle_ExampleVehicle"
		"model"					"models/vehicles/example_vehicle.mdl"
		"script"				"scripts/vehicles/example_vehicle.txt"
		"type"					"car_wheels"
		"soundscript"				"scripts/example_soundscript.txt"
		"skins"					"0,1,2"
		"key_hint"				"#Hint_VehicleKeys_Car"
		"lock_speed"				"10.0"
		"is_passenger_visible"			"1"
		"horn_sound"				"sounds/vehicles/example_horn.wav"
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

### Left 4 Dead 2

L4D2 does not ship the Half-Life 2 vehicle assets, so you must install them on the server and (optionally) on a
FastDL host. The default configuration can be adapted like this:

```
"hl2_jeep"
{
	"name"			"#Vehicle_HL2_Jeep"
	"model"			"models/buggy.mdl"
	"script"		"scripts/vehicles/jeep_test.txt"
	"type"			"car_wheels"
	"downloads"
	{
		"0"	"models/buggy.mdl"
		"1"	"models/buggy.vvd"
		"2"	"models/buggy.phy"
		"3"	"models/buggy.dx80.vtx"
		"4"	"models/buggy.dx90.vtx"
		"5"	"models/buggy.sw.vtx"
		"6"	"scripts/vehicles/jeep_test.txt"
	}
}
```

Use an HL2 `jeep_test.txt`/`buggy.mdl` set whose **internal model name** matches the file name, otherwise clients
show an error model. Vehicle scripts and materials must be present on clients; with FastDL, remember L4D2 requests
`.bz2`-compressed copies (`sv_downloadurl` must point at the folder containing `models/`, `materials/` and
`scripts/`).

Notes specific to L4D2:

* `vehicle_enable_entry_exit_anims` should remain `0` (the default).
* The `CPlayerMove::SetupMove` detour, `CGameRules::ShouldCollide` hook, and the `CanEnterVehicle` /
  `GetAttachmentLocal` SDK calls are skipped because no verified signatures exist; driving still works.
* The supplied offsets are for Windows. Linux offsets are not verified yet.

### ConVars

The plugin creates the following console variables:

* `vehicle_config_path ( def. "configs/vehicles/vehicles.cfg" )` - Path to vehicle configuration file, relative to the SourceMod folder
* `vehicle_physics_damage_modifier ( def. "1.0" )` - Modifier of impact-based physics damage against other players
* `vehicle_passenger_damage_modifier ( def. "1.0" )` - Modifier of damage dealt to vehicle passengers
* `vehicle_enable_entry_exit_anims ( def. "0" )` - If set to 1, enables entry and exit animations (experimental)
* `vehicle_enable_horns ( def. "1" )` - If set to 1, enables vehicle horns

## Entry and Exit Animations

Most vehicles have entry and exit animations that make the player transition between the vehicle and the entry/exit
points. The plugin fully supports these animations.

However, since Valve never intended `prop_vehicle_driveable` to be used outside Half-Life 2, there is code that does not
function properly in a multiplayer environment and can even cause client crashes.

Because of that, entry and exit animations on all vehicles are disabled by default and have to be manually enabled by
setting `vehicle_enable_entry_exit_anims` to `1`. If you intend to use this plugin on a public server, it is **highly
recommended** to keep the animations disabled.
