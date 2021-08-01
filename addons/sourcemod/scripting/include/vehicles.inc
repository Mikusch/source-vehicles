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

#if defined _vehicles_included
 #endinput
#endif
#define _vehicles_included

methodmap Vehicle
{
	public Vehicle(int entity)
	{
		return view_as<Vehicle>(entity);
	}
	
	/**
	 * Creates and spawns a new vehicle matching the given identifier.
	 *
	 * @param id			Identifier of the vehicle, as defined in the configuration.
	 * @param origin		Origin to spawn vehicle at.
	 * @param angles		Angles to spawn vehicle at.
	 * @param owner			Owner entity of this vehicle.
	 * @return				Entity index of the vehicle.
	 */
	public static native int Create(const char[] id, const float origin[3], const float angles[3], int owner = 0);
	
	/**
	 * The owner entity of this vehicle.
	 *
	 * This property is an alternative to m_hOwnerEntity that still allows the owner to collide with the vehicle.
	 */
	property int Owner
	{
		public native get();
		public native set(int owner);
	}
	
	/**
	 * Retrieves the identifier of this vehicle.
	 *
	 * The identifier is retrieved from the vehicle configuration using the vehicle model and the vehicle script.
	 *
	 * @param buffer		Buffer to store the identifier in.
	 * @param maxlength		Maximum size of the buffer.
	 * @return				True on success, false on failure.
	 */
	public native bool GetId(char[] buffer, int maxlength);
	
	/**
	 * Forces a client into this vehicle.
	 *
	 * @param client		Client index.
	 */
	public native void ForcePlayerIn(int client);
	
	/**
	 * Forces the current driver out of this vehicle.
	 */
	public native void ForcePlayerOut();
}

/**
 * Called when a vehicle entity has spawned.
 *
 * @param vehicle		The vehicle entity.
 */
forward void OnVehicleSpawned(int vehicle);

/**
 * Called when a vehicle entity is being destroyed.
 *
 * The vehicle properties can still be accessed in this forward.
 *
 * @param vehicle		The vehicle entity.
 */
forward void OnVehicleDestroyed(int vehicle);

/**
 * Retrieves the name of the vehicle with the given identifier.
 * 
 * @param id			Identifier of the vehicle, as defined in the configuration.
 * @param buffer		Buffer to store the name in.
 * @param maxlength		Maximum size of the buffer.
 * @return				True on success, false on failure.
 */
native bool GetVehicleName(const char[] id, char[] buffer, int maxlength);

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
	MarkNativeAsOptional("Vehicle.Create");
	MarkNativeAsOptional("Vehicle.Owner.get");
	MarkNativeAsOptional("Vehicle.Owner.set");
	MarkNativeAsOptional("Vehicle.GetId");
	MarkNativeAsOptional("Vehicle.ForcePlayerIn");
	MarkNativeAsOptional("Vehicle.ForcePlayerOut");
	MarkNativeAsOptional("GetVehicleName");
}
#endif
