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
	 * Creates a new vehicle and spawns it.
	 *
	 * @param id		The identifier of the vehicle to spawn, as defined in the configuration.
	 * @param origin	Origin to spawn vehicle at.
	 * @param angles	Angles to spawn vehicle at.
	 *
	 * @return			The vehicle.
	 */
	public static native Vehicle Create(const char[] id, const float origin[3], const float angles[3]);
	
	/**
	 * Forces a client into this vehicle.
	 *
	 * @param	Client index.
	 */
	public native void ForcePlayerIn(int client);
}

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
	MarkNativeAsOptional("Vehicle.ForcePlayerIn");
}
#endif