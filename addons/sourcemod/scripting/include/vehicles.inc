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

/**
 * Creates a vehicle at the given origin and angles.
 *
 * @param id		Unique identifier of the vehicle, as defined in the vehicle configuration.
 * @param origin	Origin to spawn entity at.
 * @param angles	Angles to spawn entity at.
 * @return			Entity index of the vehicle.
 */
native int TF2Vehicles_CreateVehicle(const char[] id, const float origin[3] = NULL_VECTOR, const float angles[3] = NULL_VECTOR);

/**
 * Forces a player into a specific vehicle.
 *
 * @param vehicle	Entity index of the vehicle.
 * @param client	Client index.
 */
native void TF2Vehicles_ForcePlayerIntoVehicle(int vehicle, int client);

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
