/*
 * Copyright (C) 2021  Mikusch
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

methodmap Vehicle
{
	public Vehicle(int entity)
	{
		return view_as<Vehicle>(entity);
	}
	
	/**
	 * The entity index.
	 */
	property int Entity
	{
		public get()
		{
			return view_as<int>(this);
		}
	}
	
	/**
	 * The owner entity of this vehicle.
	 *
	 * @note You should use this property over m_hOwnerEntity if you want the owner to collide with the vehicle.
	 */
	property int Owner
	{
		public native get();
		public native set(int owner);
	}
	
	/**
	 * Creates a new vehicle and spawns it.
	 *
	 * @param id		The identifier of the vehicle to spawn, as defined in the configuration.
	 * @param origin	Origin to spawn vehicle at.
	 * @param angles	Angles to spawn vehicle at.
	 * @param owner		The owner entity of this vehicle.
	 *
	 * @return			The vehicle.
	 */
	public static native Vehicle Create(const char[] id, const float origin[3], const float angles[3], int owner = 0);
	
	/**
	 * Forces a client into this vehicle.
	 *
	 * @param	Client index.
	 */
	public native void ForcePlayerIn(int client);
	
	/**
	 * Forces the driver out of this vehicle.
	 */
	public native void ForcePlayerOut();
}

/**
 * Called when a vehicle entity has been spawned and fully initialized.
 *
 * @note It is safe to remove the entity in this forward.
 *
 * @param vehicle	The vehicle entity.
 * @error Invalid vehicle index.
 */
forward void OnVehicleSpawned(int vehicle);

/**
 * Called when a vehicle entity is destroyed.
 *
 * @note You should implement this forward over OnEntityDestroyed if you need to access the vehicle's properties.
 *
 * @param vehicle	The vehicle entity.
 * @error Invalid vehicle index.
 */
forward void OnVehicleDestroyed(int vehicle);

public SharedPlugin __pl_vehicles =
{
	name = "vehicles",
	file = "vehicles.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public __pl_vehicles_SetNTVOptional()
{
	MarkNativeAsOptional("Vehicle.Owner.get");
	MarkNativeAsOptional("Vehicle.Owner.set");
	MarkNativeAsOptional("Vehicle.Create");
	MarkNativeAsOptional("Vehicle.ForcePlayerIn");
	MarkNativeAsOptional("Vehicle.ForcePlayerOut");
}
#endif
