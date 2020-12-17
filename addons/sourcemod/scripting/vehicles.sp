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

#include <sourcemod>
#include <dhooks>
#include <sdkhooks>

#undef REQUIRE_EXTENSIONS
#tryinclude <loadsoundscript>
#define REQUIRE_EXTENSIONS

#pragma semicolon 1
#pragma newdecls required

#define VEHICLE_CLASSNAME	"prop_vehicle_driveable"

enum VehicleType
{
	VEHICLE_TYPE_CAR_WHEELS = (1 << 0), 
	VEHICLE_TYPE_CAR_RAYCAST = (1 << 1), 
	VEHICLE_TYPE_JETSKI_RAYCAST = (1 << 2), 
	VEHICLE_TYPE_AIRBOAT_RAYCAST = (1 << 3)
}

enum struct Vehicle
{
	char name[256]; /**< Name of vehicle */
	char displayName[256];
	char model[PLATFORM_MAX_PATH]; /**< Vehicle model */
	int skin; /**< Model skin */
	char vehiclescript[PLATFORM_MAX_PATH]; /**< Vehicle script path */
	VehicleType type; /**< The type of vehicle */
	
	void ReadConfig(KeyValues kv)
	{
		kv.GetString("name", this.name, 256, this.name);
		kv.GetString("display_name", this.displayName, 256, this.displayName);
		kv.GetString("model", this.model, PLATFORM_MAX_PATH, this.model);
		this.skin = kv.GetNum("skin", this.skin);
		kv.GetString("vehiclescript", this.vehiclescript, PLATFORM_MAX_PATH, this.vehiclescript);
		
		char type[256];
		kv.GetString("type", type, sizeof(type));
		if (StrEqual(type, "car_wheels"))
			this.type = VEHICLE_TYPE_CAR_WHEELS;
		else if (StrEqual(type, "car_raycast"))
			this.type = VEHICLE_TYPE_CAR_RAYCAST;
		else if (StrEqual(type, "jetski_raycast"))
			this.type = VEHICLE_TYPE_JETSKI_RAYCAST;
		else if (StrEqual(type, "airboat_raycast"))
			this.type = VEHICLE_TYPE_AIRBOAT_RAYCAST;
		else if (type[0] != '\0')
			LogError("Invalid vehicle type '%s'", type);
	}
}

ConVar tf_vehicle_lock_speed;

ArrayList g_AllVehicles;

bool g_ClientInUse[MAXPLAYERS + 1];

#include "vehicles/dhooks.sp"
#include "vehicles/sdkcalls.sp"

public Plugin myinfo = 
{
	name = "Team Fortress 2 Vehicles", 
	author = "Mikusch", 
	description = "Fully functioning Team Fortress 2 vehicles", 
	version = "1.0", 
	url = "https://github.com/Mikusch/tf-vehicles"
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("vehicles.phrases");
	
	//Load common vehicle sounds
	if (LibraryExists("LoadSoundscript"))
		LoadSoundScript("scripts/game_sounds_vehicles.txt");
	
	GameData gamedata = new GameData("vehicles");
	if (gamedata == null)
		SetFailState("Could not find vehicles gamedata");
	
	tf_vehicle_lock_speed = CreateConVar("tf_vehicle_lock_speed", "10.0", "Vehicle must be going slower than this for player to enter or exit, in in/sec", _, true, 0.0);
	
	RegConsoleCmd("sm_vehicle", ConCmd_VehicleMenu);
	
	g_AllVehicles = new ArrayList(sizeof(Vehicle));
	
	char filePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, filePath, sizeof(filePath), "configs/vehicles/vehicles.cfg");
	
	AddCommandListener(Console_VoiceMenu, "voicemenu");
	
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			OnClientPutInServer(client);
	}
	
	KeyValues kv = new KeyValues("Vehicles");
	if (kv.ImportFromFile(filePath))
	{
		//Read through every Vehicle
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				Vehicle config;
				config.ReadConfig(kv);
				g_AllVehicles.PushArray(config);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
	}
	
	DHooks_Initialize(gamedata);
	SDKCalls_Initialize(gamedata);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("LoadSoundScript");
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PostThink, Client_PostThink);
	g_ClientInUse[client] = false;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (g_ClientInUse[client])
	{
		g_ClientInUse[client] = !g_ClientInUse[client];
		buttons |= IN_USE;
		return Plugin_Changed;
	}
	
	return Plugin_Continue;
}

public Action Console_VoiceMenu(int client, const char[] command, int args)
{
	char arg1[2];
	char arg2[2];
	GetCmdArg(1, arg1, sizeof(arg1));
	GetCmdArg(2, arg2, sizeof(arg2));
	
	if (arg1[0] == '0' && arg2[0] == '0')	//MEDIC!
		g_ClientInUse[client] = true;
}

public void Client_PostThink(int client)
{
	//For some reason IN_USE never gets assigned to m_afButtonPressed inside vehicles, preventing exiting, so let's add it ourselves
	if (GetEntPropEnt(client, Prop_Send, "m_hVehicle") && GetClientButtons(client) & IN_USE)
	{
		SetEntProp(client, Prop_Data, "m_afButtonPressed", GetEntProp(client, Prop_Data, "m_afButtonPressed") | IN_USE);
	}
}

public void OnEntityDestroyed(int entity)
{
	char classname[256];
	GetEntityClassname(entity, classname, sizeof(classname));
	if (StrEqual(classname, VEHICLE_CLASSNAME))
	{
		int client = GetEntPropEnt(entity, Prop_Send, "m_hPlayer");
		if (0 < client <= MaxClients)
			SDKCall_HandlePassengerExit(entity, client);
	}
}

public int CreateVehicle(int client, Vehicle config)
{
	int vehicle = CreateEntityByName(VEHICLE_CLASSNAME);
	if (vehicle != INVALID_ENT_REFERENCE)
	{
		DispatchKeyValue(vehicle, "targetname", config.name);
		DispatchKeyValue(vehicle, "model", config.model);
		DispatchKeyValue(vehicle, "vehiclescript", config.vehiclescript);
		DispatchKeyValue(vehicle, "spawnflags", "1");	//SF_PROP_VEHICLE_ALWAYSTHINK
		SetEntProp(vehicle, Prop_Data, "m_nSkin", config.skin);
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
		
		if (DispatchSpawn(vehicle))
		{
			SetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit", tf_vehicle_lock_speed.FloatValue);
			
			AcceptEntityInput(vehicle, "HandBrakeOn");
			
			SDKHook(vehicle, SDKHook_Think, PropVehicleDriveable_Think);
			
			MoveEntityToClientEye(vehicle, client, MASK_SOLID | MASK_WATER);
		}
		
		return EntIndexToEntRef(vehicle);
	}
	
	return INVALID_ENT_REFERENCE;
}

stock bool MoveEntityToClientEye(int entity, int client, int mask = MASK_PLAYERSOLID)
{
	float posStart[3], posEnd[3], angles[3], mins[3], maxs[3];
	
	GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
	GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
	
	GetClientEyePosition(client, posStart);
	GetClientEyeAngles(client, angles);
	
	if (TR_PointOutsideWorld(posStart))
		return false;
	
	//Get end position for hull
	Handle trace = TR_TraceRayFilterEx(posStart, angles, mask, RayType_Infinite, Trace_DontHitEntity, client);
	TR_GetEndPosition(posEnd, trace);
	delete trace;
	
	//Get new end position
	trace = TR_TraceHullFilterEx(posStart, posEnd, mins, maxs, mask, Trace_DontHitEntity, client);
	TR_GetEndPosition(posEnd, trace);
	delete trace;
	
	//Don't want entity angle consider up/down eye
	angles[0] = 0.0;
	TeleportEntity(entity, posEnd, angles, NULL_VECTOR);
	return true;
}

public bool Trace_DontHitEntity(int entity, int mask, any data)
{
	return entity != data;
}

public void PropVehicleDriveable_Think(int vehicle)
{
	SDKCall_StudioFrameAdvance(vehicle);
	
	bool sequenceFinished = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bSequenceFinished"));
	bool enterAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bEnterAnimOn"));
	bool exitAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bExitAnimOn"));
	
	if (sequenceFinished && (enterAnimOn || exitAnimOn))
	{
		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != INVALID_ENT_REFERENCE)
		{
			if (enterAnimOn)
			{
				//Show different key hints based on vehicle type
				switch (GetEntProp(vehicle, Prop_Data, "m_nVehicleType"))
				{
					case VEHICLE_TYPE_CAR_WHEELS, VEHICLE_TYPE_CAR_RAYCAST: ShowKeyHintText(client, "%t", "#Hint_VehicleKeys_Car");
					case VEHICLE_TYPE_JETSKI_RAYCAST, VEHICLE_TYPE_AIRBOAT_RAYCAST: ShowKeyHintText(client, "%t", "#Hint_VehicleKeys_Airboat");
				}
				
				AcceptEntityInput(vehicle, "TurnOn");
			}
			
			SDKCall_HandleEntryExitFinish(vehicle, exitAnimOn, !exitAnimOn);
		}
	}
}

public void ShowKeyHintText(int client, const char[] format, any...)
{
	char buffer[255];
	SetGlobalTransTarget(client);
	VFormat(buffer, sizeof(buffer), format, 3);
	
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("KeyHintText", client));
	bf.WriteByte(1);	//One message
	bf.WriteString(buffer);
	EndMessage();
}

public Address GetServerVehicle(int vehicle)
{
	static int offset = -1;
	if (offset == -1)
		FindDataMapInfo(vehicle, "m_pServerVehicle", _, _, offset);
	
	if (offset == -1)
	{
		LogError("Unable to find offset 'm_pServerVehicle'");
		return Address_Null;
	}
	
	return view_as<Address>(GetEntData(vehicle, offset));
}

public Action ConCmd_VehicleMenu(int client, int args)
{
	Menu menu = new Menu(MenuHandler_SpawnVehicle);
	menu.SetTitle("%t", "#Menu_SpawnVehicle");
	
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		Vehicle config;
		if (g_AllVehicles.GetArray(i, config, sizeof(config)) > 0)
		{
			menu.AddItem(config.name, config.displayName);
		}
	}
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
	
	return Plugin_Handled;
}

public bool GetConfigByName(const char[] name, Vehicle buffer)
{
	int index = g_AllVehicles.FindString(name);
	if (index != -1)
		return g_AllVehicles.GetArray(index, buffer, sizeof(buffer)) > 0;
	
	return false;
}

public int MenuHandler_SpawnVehicle(Menu menu, MenuAction action, int param1, int param2)
{
	//TODO: Translations
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			Vehicle config;
			if (menu.GetItem(param2, info, sizeof(info)) && GetConfigByName(info, config))
				CreateVehicle(param1, config);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
}
