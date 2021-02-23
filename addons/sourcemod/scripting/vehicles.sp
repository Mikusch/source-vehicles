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

#include <sourcemod>
#include <dhooks>
#include <sdkhooks>

#undef REQUIRE_EXTENSIONS
#tryinclude <loadsoundscript>
#define REQUIRE_EXTENSIONS

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION	"1.5.0"
#define PLUGIN_AUTHOR	"Mikusch"
#define PLUGIN_URL		"https://github.com/Mikusch/tf-vehicles"

#define VEHICLE_CLASSNAME	"prop_vehicle_driveable"
#define CONFIG_FILEPATH		"configs/vehicles/vehicles.cfg"

#define ACTIVITY_NOT_AVAILABLE	-1

enum PassengerRole
{
	VEHICLE_ROLE_NONE = -1,
	VEHICLE_ROLE_DRIVER = 0,	// Only one driver
	LAST_SHARED_VEHICLE_ROLE,
}

enum VehicleType
{
	VEHICLE_TYPE_CAR_WHEELS = (1 << 0), 
	VEHICLE_TYPE_CAR_RAYCAST = (1 << 1), 
	VEHICLE_TYPE_JETSKI_RAYCAST = (1 << 2), 
	VEHICLE_TYPE_AIRBOAT_RAYCAST = (1 << 3)
}

enum struct Vehicle
{
	char id[256];							/**< Unique identifier of the vehicle */
	char name[256];							/**< Display name of the vehicle */
	char model[PLATFORM_MAX_PATH];			/**< Vehicle model */
	int skin;								/**< Model skin */
	char vehiclescript[PLATFORM_MAX_PATH];	/**< Vehicle script path */
	VehicleType type;						/**< The type of vehicle */
	
	void ReadConfig(KeyValues kv)
	{
		kv.GetString("id", this.id, 256, this.id);
		kv.GetString("name", this.name, 256, this.name);
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
		
		if (kv.JumpToKey("downloads"))
		{
			if (kv.GotoFirstSubKey(false))
			{
				do
				{
					char filename[PLATFORM_MAX_PATH];
					kv.GetString(NULL_STRING, filename, sizeof(filename));
					AddFileToDownloadsTable(filename);
				}
				while (kv.GotoNextKey(false));
				kv.GoBack();
			}
			kv.GoBack();
		}
	}
}

ConVar tf_vehicle_lock_speed;
ConVar tf_vehicle_physics_damage_modifier;
ConVar tf_vehicle_voicemenu_use;
ConVar tf_vehicle_enable_entry_exit_anims;

DynamicHook g_DHookSetPassenger;
DynamicHook g_DHookHandlePassengerEntry;
DynamicHook g_DHookGetExitAnimToUse;
DynamicHook g_DHookIsPassengerVisible;

Handle g_SDKCallVehicleSetupMove;
Handle g_SDKCallGetVehicleEnt;
Handle g_SDKCallHandleEntryExitFinish;
Handle g_SDKCallGetDriver;
Handle g_SDKCallStudioFrameAdvance;
Handle g_SDKCallGetInVehicle;

ArrayList g_AllVehicles;

char g_OldAllowPlayerUse[8];
char g_OldTurboPhysics[8];

bool g_ClientInUse[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "Driveable Vehicles for Team Fortress 2", 
	author = PLUGIN_AUTHOR, 
	description = "Fully functioning driveable vehicles for Team Fortress 2", 
	version = PLUGIN_VERSION, 
	url = PLUGIN_URL
}

//-----------------------------------------------------------------------------
// SourceMod Forwards
//-----------------------------------------------------------------------------

public void OnPluginStart()
{
	if (GetEngineVersion() != Engine_TF2)
		SetFailState("This plugin is only compatible with Team Fortress 2");
	
	LoadTranslations("common.phrases");
	LoadTranslations("vehicles.phrases");
	
	//Load common vehicle sounds
	if (LibraryExists("LoadSoundscript"))
#if defined _loadsoundscript_included
		LoadSoundScript("scripts/game_sounds_vehicles.txt");
#endif
	else
		LogMessage("LoadSoundScript extension could not be found, vehicles won't have sounds.");
	
	//Create plugin convars
	tf_vehicle_lock_speed = CreateConVar("tf_vehicle_lock_speed", "10.0", "Vehicle must be going slower than this for player to enter or exit, in in/sec", _, true, 0.0);
	tf_vehicle_physics_damage_modifier = CreateConVar("tf_vehicle_physics_damage_modifier", "1.0", "Modifier of impact-based physics damage against other players", _, true, 0.0);
	tf_vehicle_voicemenu_use = CreateConVar("tf_vehicle_voicemenu_use", "1", "Allow the 'MEDIC!' voice menu command to call +use");
	tf_vehicle_enable_entry_exit_anims = CreateConVar("tf_vehicle_enable_entry_exit_anims", "0", "Enable entry and exit animations (experimental, use at your own risk!)");
	
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
	g_DHookSetPassenger = CreateDynamicHook(gamedata, "CBaseServerVehicle::SetPassenger");
	g_DHookHandlePassengerEntry = CreateDynamicHook(gamedata, "CBaseServerVehicle::HandlePassengerEntry");
	g_DHookGetExitAnimToUse = CreateDynamicHook(gamedata, "CBaseServerVehicle::GetExitAnimToUse");
	g_DHookIsPassengerVisible = CreateDynamicHook(gamedata, "CBaseServerVehicle::IsPassengerVisible");
	
	g_SDKCallVehicleSetupMove = PrepSDKCall_VehicleSetupMove(gamedata);
	g_SDKCallGetVehicleEnt = PrepSDKCall_GetVehicleEnt(gamedata);
	g_SDKCallHandleEntryExitFinish = PrepSDKCall_HandleEntryExitFinish(gamedata);
	g_SDKCallGetDriver = PrepSDKCall_GetDriver(gamedata);
	g_SDKCallStudioFrameAdvance = PrepSDKCall_StudioFrameAdvance(gamedata);
	g_SDKCallGetInVehicle = PrepSDKCall_GetInVehicle(gamedata);
	
	delete gamedata;
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

public void OnMapStart()
{
	//Hook all vehicles
	int vehicle;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		SDKHook(vehicle, SDKHook_Think, PropVehicleDriveable_Think);
		
		DHookVehicle(vehicle);
	}
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
	if (entity == -1)
		return;
	
	if (IsEntityVehicle(entity))
		SDKCall_HandleEntryExitFinish(entity, true, true);
}

//-----------------------------------------------------------------------------
// Plugin Functions
//-----------------------------------------------------------------------------

void CreateVehicle(int client, Vehicle config)
{
	int vehicle = CreateEntityByName(VEHICLE_CLASSNAME);
	if (vehicle != -1)
	{
		DispatchKeyValue(vehicle, "targetname", config.id);
		DispatchKeyValue(vehicle, "model", config.model);
		DispatchKeyValue(vehicle, "vehiclescript", config.vehiclescript);
		DispatchKeyValue(vehicle, "spawnflags", "1");	//SF_PROP_VEHICLE_ALWAYSTHINK
		SetEntProp(vehicle, Prop_Data, "m_nSkin", config.skin);
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
		
		if (DispatchSpawn(vehicle))
		{
			AcceptEntityInput(vehicle, "HandBrakeOn");
			
			TeleportEntityToClientViewPos(vehicle, client, MASK_SOLID | MASK_WATER);
		}
	}
}

bool TeleportEntityToClientViewPos(int entity, int client, int mask)
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
	
	//We don't want the entity angle to consider the x-axis
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

bool GetConfigById(const char[] id, Vehicle buffer)
{
	int index = g_AllVehicles.FindString(id);
	if (index != -1)
		return g_AllVehicles.GetArray(index, buffer, sizeof(buffer)) > 0;
	
	return false;
}

bool GetConfigByModel(const char[] model, Vehicle buffer)
{
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		if (g_AllVehicles.GetArray(i, buffer, sizeof(buffer)) > 0)
		{
			if (StrEqual(model, buffer.model))
				return true;
		}
	}
	
	return false;
}

bool GetConfigByModelAndVehicleScript(const char[] model, const char[] vehiclescript, Vehicle buffer)
{
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		if (g_AllVehicles.GetArray(i, buffer, sizeof(buffer)) > 0)
		{
			if (StrEqual(model, buffer.model) && StrEqual(vehiclescript, buffer.vehiclescript))
				return true;
		}
	}
	
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
	
	char id[256];
	GetCmdArgString(id, sizeof(id));
	
	Vehicle config;
	if (!GetConfigById(id, config))
	{
		ReplyToCommand(client, "%t", "#Command_CreateVehicle_InvalidName", id);
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
	if (GetEntPropEnt(client, Prop_Send, "m_hVehicle") != -1 && GetClientButtons(client) & IN_USE)
	{
		SetEntProp(client, Prop_Data, "m_afButtonPressed", GetEntProp(client, Prop_Data, "m_afButtonPressed") | IN_USE);
	}
}

public Action Client_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (damagetype & DMG_VEHICLE && IsEntityVehicle(inflictor))
	{
		int driver = GetEntPropEnt(inflictor, Prop_Send, "m_hPlayer");
		if (driver != -1 && victim != driver)
		{
			damage *= tf_vehicle_physics_damage_modifier.FloatValue;
			attacker = driver;
			return Plugin_Changed;
		}
	}
	
	return Plugin_Continue;
}

public void PropVehicleDriveable_Think(int vehicle)
{
	int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	int sequence = GetEntProp(vehicle, Prop_Data, "m_nSequence");
	bool sequenceFinished = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bSequenceFinished"));
	bool enterAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bEnterAnimOn"));
	bool exitAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bExitAnimOn"));
	
	if (sequence != 0)
		SDKCall_StudioFrameAdvance(vehicle);
	
	if ((sequence == 0 || sequenceFinished) && (enterAnimOn || exitAnimOn))
	{
		if (enterAnimOn)
		{
			AcceptEntityInput(vehicle, "TurnOn");
			
			//Show different key hints based on vehicle type
			switch (GetEntProp(vehicle, Prop_Data, "m_nVehicleType"))
			{
				case VEHICLE_TYPE_CAR_WHEELS, VEHICLE_TYPE_CAR_RAYCAST:
				{
					ShowKeyHintText(client, "%t", "#Hint_VehicleKeys_Car");
				}
				case VEHICLE_TYPE_JETSKI_RAYCAST, VEHICLE_TYPE_AIRBOAT_RAYCAST:
				{
					ShowKeyHintText(client, "%t", "#Hint_VehicleKeys_Airboat");
				}
			}
		}
		
		SDKCall_HandleEntryExitFinish(vehicle, exitAnimOn, true);
	}
}

public void PropVehicleDriveable_Spawn(int vehicle)
{
	char model[PLATFORM_MAX_PATH], vehiclescript[PLATFORM_MAX_PATH];
	GetEntPropString(vehicle, Prop_Data, "m_ModelName", model, sizeof(model));
	GetEntPropString(vehicle, Prop_Data, "m_vehicleScript", vehiclescript, sizeof(vehiclescript));
	
	Vehicle config;
	
	//If no script is set, try to find a matching config entry and set it ourselves
	if (vehiclescript[0] == '\0' && GetConfigByModel(model, config))
	{
		vehiclescript = config.vehiclescript;
		DispatchKeyValue(vehicle, "VehicleScript", config.vehiclescript);
	}
	
	if (GetConfigByModelAndVehicleScript(model, vehiclescript, config))
	{
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
	}
}

public void PropVehicleDriveable_SpawnPost(int vehicle)
{
	DHookVehicle(vehicle);
	
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
			menu.AddItem(config.id, config.id);
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
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)) && GetConfigById(info, config))
			{
				SetGlobalTransTarget(param1);
				Format(display, sizeof(display), "%t", config.name);
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
	if (detour != null)
	{
		if (callbackPre != INVALID_FUNCTION)
			detour.Enable(Hook_Pre, callbackPre);
		
		if (callbackPost != INVALID_FUNCTION)
			detour.Enable(Hook_Post, callbackPost);
	}
	else
	{
		LogError("Failed to find offset for %s", name);
	}
}

DynamicHook CreateDynamicHook(GameData gamedata, const char[] name)
{
	DynamicHook hook = DynamicHook.FromConf(gamedata, name);
	if (hook == null)
		LogError("Failed to find offset for %s", name);
	
	return hook;
}

void DHookVehicle(int vehicle)
{
	Address serverVehicle = GetServerVehicle(vehicle);
	
	//m_pServerVehicle is initialized in CPropVehicleDriveable::Spawn
	if (g_DHookSetPassenger != null)
		g_DHookSetPassenger.HookRaw(Hook_Pre, serverVehicle, DHookCallback_SetPassengerPre);
	
	if (g_DHookHandlePassengerEntry != null)
		g_DHookHandlePassengerEntry.HookRaw(Hook_Pre, serverVehicle, DHookCallback_HandlePassengerEntryPre);
	
	if (g_DHookGetExitAnimToUse != null)
		g_DHookGetExitAnimToUse.HookRaw(Hook_Post, serverVehicle, DHookCallback_GetExitAnimToUsePost);
	
	if (g_DHookIsPassengerVisible != null)
		g_DHookIsPassengerVisible.HookRaw(Hook_Post, serverVehicle, DHookCallback_IsPassengerVisiblePost);
}

public MRESReturn DHookCallback_SetupMovePre(DHookParam params)
{
	int client = params.Get(1);
	
	int vehicle = GetEntPropEnt(client, Prop_Send, "m_hVehicle");
	if (vehicle != -1)
	{
		Address ucmd = params.Get(2);
		Address helper = params.Get(3);
		Address move = params.Get(4);
		
		SDKCall_VehicleSetupMove(vehicle, client, ucmd, helper, move);
	}
}

public MRESReturn DHookCallback_SetPassengerPre(Address serverVehicle, DHookParam params)
{
	if (!params.IsNull(2))
	{
		SetEntProp(params.Get(2), Prop_Data, "m_bDrawViewmodel", false);
	}
	else
	{
		int client = SDKCall_GetDriver(serverVehicle);
		if (client != -1)
			SetEntProp(client, Prop_Data, "m_bDrawViewmodel", true);
	}
}

public MRESReturn DHookCallback_HandlePassengerEntryPre(Address serverVehicle, DHookParam params)
{
	if (!tf_vehicle_enable_entry_exit_anims.BoolValue)
	{
		int client = params.Get(1);
		int vehicle = SDKCall_GetVehicleEnt(serverVehicle);
		
		//This saves us an SDKCall to CPropVehicleDriveable::CanEnterVehicle
		if (GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer") == client)
			return MRES_Supercede;
		
		//I don't know why we need to set this but entering vehicles doesn't work if we don't (client-side code?)
		SetEntProp(vehicle, Prop_Data, "m_bEnterAnimOn", true);
		
		SDKCall_GetInVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER);
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetExitAnimToUsePost(Address serverVehicle, DHookReturn ret)
{
	if (!tf_vehicle_enable_entry_exit_anims.BoolValue)
	{
		ret.Value = ACTIVITY_NOT_AVAILABLE;
		return MRES_Override;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_IsPassengerVisiblePost(Address serverVehicle, DHookReturn ret)
{
	ret.Value = true;
	return MRES_Supercede;
}

//-----------------------------------------------------------------------------
// SDK Calls
//-----------------------------------------------------------------------------

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

Handle PrepSDKCall_GetVehicleEnt(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::GetVehicleEnt");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::GetVehicleEnt");
	
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

Handle PrepSDKCall_GetDriver(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::GetDriver");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::GetDriver");
	
	return call;
}

Handle PrepSDKCall_StudioFrameAdvance(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseAnimating::StudioFrameAdvance");
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogError("Failed to create SDKCall: CBaseAnimating::StudioFrameAdvance");
	
	return call;
}

Handle PrepSDKCall_GetInVehicle(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBasePlayer::GetInVehicle");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogError("Failed to create SDKCall: CBasePlayer::GetInVehicle");
	
	return call;
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

int SDKCall_GetVehicleEnt(Address serverVehicle)
{
	if (g_SDKCallGetVehicleEnt != null)
		return SDKCall(g_SDKCallGetVehicleEnt, serverVehicle);
	
	return -1;
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

int SDKCall_GetDriver(Address serverVehicle)
{
	if (g_SDKCallGetDriver != null)
		return SDKCall(g_SDKCallGetDriver, serverVehicle);
	
	return -1;
}

void SDKCall_StudioFrameAdvance(int entity)
{
	if (g_SDKCallStudioFrameAdvance != null)
		SDKCall(g_SDKCallStudioFrameAdvance, entity);
}

bool SDKCall_GetInVehicle(int client, Address serverVehicle, PassengerRole role)
{
	if (g_SDKCallGetInVehicle != null)
		return SDKCall(g_SDKCallGetInVehicle, client, serverVehicle, role);
	
	return false;
}
