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

#define PLUGIN_VERSION	"v1.1"
#define PLUGIN_AUTHOR	"Mikusch"
#define PLUGIN_URL		"https://github.com/Mikusch/tf-vehicles"

#define VEHICLE_CLASSNAME	"prop_vehicle_driveable"
#define CONFIG_FILEPATH		"configs/vehicles/vehicles.cfg"

enum VehicleType
{
	VEHICLE_TYPE_CAR_WHEELS = (1 << 0), 
	VEHICLE_TYPE_CAR_RAYCAST = (1 << 1), 
	VEHICLE_TYPE_JETSKI_RAYCAST = (1 << 2), 
	VEHICLE_TYPE_AIRBOAT_RAYCAST = (1 << 3)
}

enum struct Vehicle
{
	char name[256];							/**< Unique identifier of the vehicle */
	char displayName[256];					/**< Display name of the vehicle */
	char model[PLATFORM_MAX_PATH];			/**< Vehicle model */
	int skin;								/**< Model skin */
	char vehiclescript[PLATFORM_MAX_PATH];	/**< Vehicle script path */
	VehicleType type;						/**< The type of vehicle */
	
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
ConVar tf_vehicle_physics_damage_multiplier;
ConVar tf_vehicle_voicemenu_use;

Handle g_SDKCallStudioFrameAdvance;
Handle g_SDKCallVehicleSetupMove;
Handle g_SDKCallHandleEntryExitFinish;

ArrayList g_AllVehicles;

char g_OldAllowPlayerUse[8];
char g_OldTurboPhysics[8];

bool g_ClientInUse[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "Team Fortress 2 Vehicles", 
	author = "Mikusch", 
	description = "Fully functioning Team Fortress 2 vehicles", 
	version = "1.0", 
	url = "https://github.com/Mikusch/tf-vehicles"
}

//-----------------------------------------------------------------------------
// SourceMod Forwards
//-----------------------------------------------------------------------------

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("vehicles.phrases");
	
	//Load common vehicle sounds
	if (LibraryExists("LoadSoundscript"))
		LoadSoundScript("scripts/game_sounds_vehicles.txt");
	
	//Create plugin convars
	tf_vehicle_lock_speed = CreateConVar("tf_vehicle_lock_speed", "10.0", "Vehicle must be going slower than this for player to enter or exit, in in/sec", _, true, 0.0);
	tf_vehicle_physics_damage_multiplier = CreateConVar("tf_vehicle_physics_damage_multiplier", "1.0", "Multiplier of impact-based physics damage against other players", _, true, 0.0);
	tf_vehicle_voicemenu_use = CreateConVar("tf_vehicle_voicemenu_use", "1", "Whether \"MEDIC!\" voice menu commands should call +use", _, true, 0.0, true, 1.0);
	
	RegAdminCmd("sm_vehicle", ConCmd_OpenVehicleMenu, ADMFLAG_GENERIC);
	RegAdminCmd("sm_vehicles", ConCmd_OpenVehicleMenu, ADMFLAG_GENERIC);
	RegAdminCmd("sm_createvehicle", ConCmd_CreateVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_spawnvehicle", ConCmd_CreateVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_destroyvehicle", ConCmd_DestroyVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_removevehicle", ConCmd_DestroyVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_destroyallvehicles", ConCmd_DestroyAllVehicles, ADMFLAG_GENERIC);
	RegAdminCmd("sm_removeallvehicles", ConCmd_DestroyAllVehicles, ADMFLAG_GENERIC);
	
	AddCommandListener(CommandListener_VoiceMenu, "voicemenu");
	
	//Hook all clients
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			OnClientPutInServer(client);
	}
	
	//Hook all vehicles
	int vehicle = MaxClients + 1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		SDKHook(vehicle, SDKHook_Think, PropVehicleDriveable_Think);
	}
	
	g_AllVehicles = new ArrayList(sizeof(Vehicle));
	
	char filePath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, filePath, sizeof(filePath), CONFIG_FILEPATH);
	
	//Read the vehicle configuration
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
	
	SetupConVar("tf_allow_player_use", g_OldAllowPlayerUse, sizeof(g_OldAllowPlayerUse), "1");
	SetupConVar("sv_turbophysics", g_OldTurboPhysics, sizeof(g_OldTurboPhysics), "0");
	
	GameData gamedata = new GameData("vehicles");
	if (gamedata == null)
		SetFailState("Could not find vehicles gamedata");
	
	CreateDynamicDetour(gamedata, "CTFPlayerMove::SetupMove", DHookCallback_SetupMovePre);
	
	g_SDKCallStudioFrameAdvance = PrepSDKCall_StudioFrameAdvance(gamedata);
	g_SDKCallVehicleSetupMove = PrepSDKCall_VehicleSetupMove(gamedata);
	g_SDKCallHandleEntryExitFinish = PrepSDKCall_HandleEntryExitFinish(gamedata);
}

public void OnPluginEnd()
{
	RestoreConVar("tf_allow_player_use", g_OldAllowPlayerUse);
	RestoreConVar("sv_turbophysics", g_OldTurboPhysics);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	MarkNativeAsOptional("LoadSoundScript");
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PostThink, Client_PostThink);
	SDKHook(client, SDKHook_OnTakeDamage, Client_OnTakeDamage);
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

public void OnEntityCreated(int entity)
{
	if (IsEntityVehicle(entity))
	{
		SDKHook(entity, SDKHook_Think, PropVehicleDriveable_Think);
		SDKHook(entity, SDKHook_Spawn, PropVehicleDriveable_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, PropVehicleDriveable_SpawnPost);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (IsEntityVehicle(entity))
	{
		int client = GetEntPropEnt(entity, Prop_Send, "m_hPlayer");
		if (0 < client <= MaxClients)
		{
			AcceptEntityInput(client, "ClearParent");
		}
	}
}

//-----------------------------------------------------------------------------
// Plugin Functions
//-----------------------------------------------------------------------------

void CreateVehicle(int client, Vehicle config)
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
			AcceptEntityInput(vehicle, "HandBrakeOn");
			
			MoveEntityToClientEye(vehicle, client, MASK_SOLID | MASK_WATER);
		}
	}
}

bool MoveEntityToClientEye(int entity, int client, int mask = MASK_PLAYERSOLID)
{
	float posStart[3], posEnd[3], angles[3], mins[3], maxs[3];
	
	GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
	GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
	
	GetClientEyePosition(client, posStart);
	GetClientEyeAngles(client, angles);
	
	if (TR_PointOutsideWorld(posStart))
		return false;
	
	//Get end position for hull
	Handle trace = TR_TraceRayFilterEx(posStart, angles, mask, RayType_Infinite, TraceEntityFilter_DontHitEntity, client);
	TR_GetEndPosition(posEnd, trace);
	delete trace;
	
	//Get new end position
	trace = TR_TraceHullFilterEx(posStart, posEnd, mins, maxs, mask, TraceEntityFilter_DontHitEntity, client);
	TR_GetEndPosition(posEnd, trace);
	delete trace;
	
	//Don't want entity angle consider up/down eye
	angles[0] = 0.0;
	TeleportEntity(entity, posEnd, angles, NULL_VECTOR);
	return true;
}

public bool TraceEntityFilter_DontHitEntity(int entity, int mask, any data)
{
	return entity != data;
}

void ShowKeyHintText(int client, const char[] format, any...)
{
	char buffer[256];
	SetGlobalTransTarget(client);
	VFormat(buffer, sizeof(buffer), format, 3);
	
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("KeyHintText", client));
	bf.WriteByte(1);	//One message
	bf.WriteString(buffer);
	EndMessage();
}

bool IsEntityVehicle(int entity)
{
	char classname[256];
	return GetEntityClassname(entity, classname, sizeof(classname)) && StrEqual(classname, VEHICLE_CLASSNAME);
}

Address GetServerVehicle(int vehicle)
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

bool GetConfigByName(const char[] name, Vehicle buffer)
{
	int index = g_AllVehicles.FindString(name);
	if (index != -1)
		return g_AllVehicles.GetArray(index, buffer, sizeof(buffer)) > 0;
	
	return false;
}

void SetupConVar(const char[] name, char[] oldValue, int maxlength, const char[] newValue)
{
	ConVar convar = FindConVar(name);
	if (convar != null)
	{
		convar.GetString(oldValue, maxlength);
		convar.SetString(newValue);
	}
}

void RestoreConVar(const char[] name, const char[] oldValue)
{
	ConVar convar = FindConVar(name);
	if (convar != null)
	{
		convar.SetString(oldValue);
	}
}

//-----------------------------------------------------------------------------
// Commands
//-----------------------------------------------------------------------------

public Action CommandListener_VoiceMenu(int client, const char[] command, int args)
{
	char arg1[2];
	char arg2[2];
	GetCmdArg(1, arg1, sizeof(arg1));
	GetCmdArg(2, arg2, sizeof(arg2));
	
	if (tf_vehicle_voicemenu_use.BoolValue)
	{
		if (arg1[0] == '0' && arg2[0] == '0')	//MEDIC!
		{
			g_ClientInUse[client] = true;
		}
	}
}

public Action ConCmd_OpenVehicleMenu(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	DisplayMainVehicleMenu(client);
	return Plugin_Handled;
}

public Action ConCmd_CreateVehicle(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	if (args == 0)
	{
		DisplayVehicleCreateMenu(client);
		return Plugin_Handled;
	}
	
	char name[256];
	GetCmdArgString(name, sizeof(name));
	
	Vehicle config;
	if (!GetConfigByName(name, config))
	{
		ReplyToCommand(client, "%t", "#Command_CreateVehicle_InvalidName", name);
		return Plugin_Handled;
	}
	
	CreateVehicle(client, config);
	return Plugin_Handled;
}

public Action ConCmd_DestroyVehicle(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	float origin[3], angles[3], end[3];
	GetClientEyePosition(client, origin);
	GetClientEyeAngles(client, angles);
	
	Handle trace = TR_TraceRayFilterEx(origin, angles, MASK_SOLID, RayType_Infinite, TraceEntityFilter_DontHitEntity, client);
	TR_GetEndPosition(end, trace);
	
	int entity = TR_GetEntityIndex(trace);
	
	delete trace;
	
	if (IsEntityVehicle(entity))
	{
		RemoveEntity(entity);
		ReplyToCommand(client, "%t", "#Command_DestroyVehicle_Success");
	}
	else
	{
		ReplyToCommand(client, "%t", "#Command_DestroyVehicle_NoVehicleFound");
	}
	
	return Plugin_Handled;
}

public Action ConCmd_DestroyAllVehicles(int client, int args)
{
	int vehicle = MaxClients + 1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		RemoveEntity(vehicle);
	}
	
	ReplyToCommand(client, "%t", "#Command_DestroyAllVehicles_Success");
	return Plugin_Handled;
}

//-----------------------------------------------------------------------------
// SDKHooks
//-----------------------------------------------------------------------------

public void Client_PostThink(int client)
{
	//For some reason IN_USE never gets assigned to m_afButtonPressed inside vehicles, preventing exiting, so let's add it ourselves
	if (GetEntPropEnt(client, Prop_Send, "m_hVehicle") && GetClientButtons(client) & IN_USE)
	{
		SetEntProp(client, Prop_Data, "m_afButtonPressed", GetEntProp(client, Prop_Data, "m_afButtonPressed") | IN_USE);
	}
}

public Action Client_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (damagetype & DMG_VEHICLE && IsEntityVehicle(inflictor))
	{
		int driver = GetEntPropEnt(inflictor, Prop_Send, "m_hPlayer");
		if (0 < driver <= MaxClients && victim != driver)
		{
			damage *= tf_vehicle_physics_damage_multiplier.FloatValue;
			attacker = driver;
			return Plugin_Changed;
		}
	}
	
	return Plugin_Continue;
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

public void PropVehicleDriveable_Spawn(int vehicle)
{
	char targetname[256];
	GetEntPropString(vehicle, Prop_Data, "m_iName", targetname, sizeof(targetname));
	
	Vehicle config;
	if (GetConfigByName(targetname, config))
	{
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
	}
}

public void PropVehicleDriveable_SpawnPost(int vehicle)
{
	SetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit", tf_vehicle_lock_speed.FloatValue);
}

//-----------------------------------------------------------------------------
// Menus
//-----------------------------------------------------------------------------

void DisplayMainVehicleMenu(int client)
{
	Menu menu = new Menu(MenuHandler_MainVehicleMenu, MenuAction_Select | MenuAction_DisplayItem | MenuAction_End);
	menu.SetTitle("%t", "#Menu_Title_Main", PLUGIN_VERSION, PLUGIN_AUTHOR, PLUGIN_URL);
	
	menu.AddItem("vehicle_create", "#Menu_Item_CreateVehicle");
	menu.AddItem("vehicle_destroy", "#Menu_Item_DestroyVehicle");
	menu.AddItem("vehicle_destroyall", "#Menu_Item_DestroyAllVehicles");
	
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_MainVehicleMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			if (menu.GetItem(param2, info, sizeof(info)))
			{
				if (StrEqual(info, "vehicle_create"))
				{
					DisplayVehicleCreateMenu(param1);
				}
				else if (StrEqual(info, "vehicle_destroy"))
				{
					FakeClientCommand(param1, "sm_destroyvehicle");
					DisplayMainVehicleMenu(param1);
				}
				else if (StrEqual(info, "vehicle_destroyall"))
				{
					FakeClientCommand(param1, "sm_destroyallvehicles");
					DisplayMainVehicleMenu(param1);
				}
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)))
			{
				SetGlobalTransTarget(param1);
				Format(display, sizeof(display), "%t", display);
				return RedrawMenuItem(display);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

void DisplayVehicleCreateMenu(int client)
{
	Menu menu = new Menu(MenuHandler_VehicleCreateMenu, MenuAction_Select | MenuAction_DisplayItem | MenuAction_Cancel | MenuAction_End);
	menu.SetTitle("%t", "#Menu_Title_CreateVehicle");
	
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		Vehicle config;
		if (g_AllVehicles.GetArray(i, config, sizeof(config)) > 0)
		{
			menu.AddItem(config.name, config.displayName);
		}
	}
	
	menu.ExitButton = true;
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_VehicleCreateMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			if (menu.GetItem(param2, info, sizeof(info)))
			{
				FakeClientCommand(param1, "sm_createvehicle %s", info);
				DisplayVehicleCreateMenu(param1);
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			Vehicle config;
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)) && GetConfigByName(info, config))
			{
				SetGlobalTransTarget(param1);
				Format(display, sizeof(display), "%t", config.displayName);
				return RedrawMenuItem(display);
			}
		}
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				DisplayMainVehicleMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}
	
	return 0;
}

//-----------------------------------------------------------------------------
// DHooks
//-----------------------------------------------------------------------------

void CreateDynamicDetour(GameData gamedata, const char[] name, DHookCallback callbackPre = INVALID_FUNCTION, DHookCallback callbackPost = INVALID_FUNCTION)
{
	DynamicDetour detour = DynamicDetour.FromConf(gamedata, name);
	if (!detour)
	{
		LogError("Failed to find offset for %s", name);
	}
	else
	{
		if (callbackPre != INVALID_FUNCTION)
			detour.Enable(Hook_Pre, callbackPre);
		
		if (callbackPost != INVALID_FUNCTION)
			detour.Enable(Hook_Post, callbackPost);
	}
}

public MRESReturn DHookCallback_SetupMovePre(DHookParam param)
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

//-----------------------------------------------------------------------------
// SDK Calls
//-----------------------------------------------------------------------------

Handle PrepSDKCall_StudioFrameAdvance(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseAnimating::StudioFrameAdvance");
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogError("Failed to create SDKCall: CBaseAnimating::StudioFrameAdvance");
	
	return call;
}

Handle PrepSDKCall_VehicleSetupMove(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::SetupMove");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::SetupMove");
	
	return call;
}

Handle PrepSDKCall_HandleEntryExitFinish(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandleEntryExitFinish");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::HandleEntryExitFinish");
	
	return call;
}

void SDKCall_StudioFrameAdvance(int entity)
{
	if (g_SDKCallStudioFrameAdvance != null)
		SDKCall(g_SDKCallStudioFrameAdvance, entity);
}

void SDKCall_VehicleSetupMove(int vehicle, int client, Address ucmd, Address helper, Address move)
{
	if (g_SDKCallVehicleSetupMove != null)
	{
		Address serverVehicle = GetServerVehicle(vehicle);
		if (serverVehicle != Address_Null)
			SDKCall(g_SDKCallVehicleSetupMove, serverVehicle, client, ucmd, helper, move);
	}
}

void SDKCall_HandleEntryExitFinish(int vehicle, bool exitAnimOn, bool resetAnim)
{
	if (g_SDKCallHandleEntryExitFinish != null)
	{
		Address serverVehicle = GetServerVehicle(vehicle);
		if (serverVehicle != Address_Null)
			SDKCall(g_SDKCallHandleEntryExitFinish, serverVehicle, exitAnimOn, resetAnim);
	}
}
