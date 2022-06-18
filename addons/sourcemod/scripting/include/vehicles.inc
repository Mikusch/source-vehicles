/**
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
	 * @param id			Identifier of the vehicle.
	 * @param origin		Spawn origin, or NULL_VECTOR for none.
	 * @param angles		Spawn angles, or NULL_VECTOR for none.
	 * @param owner			Owner entity, or -1 for none.
	 * @return				Entity index.
	 * @error				Invalid identifier.
	 */
	public static native int Create(const char[] id, const float origin[3] = NULL_VECTOR, const float angles[3] = NULL_VECTOR, int owner = -1);
	
	/**
	 * The owner entity of this vehicle. In most cases this will be the client that spawned it.
	 *
	 * Note: This is NOT the same as the m_hOwnerEntity entity property.
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
 * Retrieves the name of the vehicle with the given identifier.
 * 
 * @param id			Identifier of the vehicle.
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
