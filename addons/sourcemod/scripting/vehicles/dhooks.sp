/*
 * Copyright (C) 2020  Mikusch
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

public void DHooks_Initialize(GameData gamedata)
{
	DHooks_CreateDynamicDetour(gamedata, "CTFPlayerMove::SetupMove", DHook_SetupMovePre, _);
}

static void DHooks_CreateDynamicDetour(GameData gamedata, const char[] name, DHookCallback callbackPre = INVALID_FUNCTION, DHookCallback callbackPost = INVALID_FUNCTION)
{
	DynamicDetour detour = DynamicDetour.FromConf(gamedata, name);
	if (!detour)
	{
		LogError("Failed to create dynamic detour: %s", name);
	}
	else
	{
		if (callbackPre != INVALID_FUNCTION)
			detour.Enable(Hook_Pre, callbackPre);
		
		if (callbackPost != INVALID_FUNCTION)
			detour.Enable(Hook_Post, callbackPost);
	}
}

static DynamicHook DHooks_CreateDynamicHook(GameData gamedata, const char[] name)
{
	DynamicHook hook = DynamicHook.FromConf(gamedata, name);
	if (!hook)
		LogError("Failed to create dynamic hook: %s", name);
	
	return hook;
}

public MRESReturn DHook_SetupMovePre(DHookParam param)
{
	int client = param.Get(1);
	
	int vehicle = GetEntPropEnt(client, Prop_Send, "m_hVehicle");
	if (vehicle != INVALID_ENT_REFERENCE)
	{
		Address ucmd = param.Get(2);
		Address helper = param.Get(3);
		Address move = param.Get(4);
		
		SDKCall_VehicleSetupMove(vehicle, client, ucmd, helper, move);
	}
}