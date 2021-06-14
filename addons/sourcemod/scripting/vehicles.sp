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

#define PLUGIN_VERSION	"2.0.0"
#define PLUGIN_AUTHOR	"Mikusch"
#define PLUGIN_URL		"https://github.com/Mikusch/source-vehicles"

#define VEHICLE_CLASSNAME	"prop_vehicle_driveable"

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

enum struct VehicleConfig
{
	char id[256];						/**< Unique identifier of the vehicle */
	char name[256];						/**< Display name of the vehicle */
	char model[PLATFORM_MAX_PATH];		/**< Vehicle model */
	char script[PLATFORM_MAX_PATH];		/**< Vehicle script path */
	VehicleType type;					/**< The type of vehicle */
	ArrayList skins;					/**< Model skins */
	char key_hint[256];					/**< Vehicle key hint */
	float lock_speed;					/**< Vehicle lock speed */
	bool is_passenger_visible;			/**< Whether the passenger is visible */
	char horn_sound[PLATFORM_MAX_PATH];	/**< Custom horn sound */
	
	void ReadConfig(KeyValues kv)
	{
		kv.GetString("id", this.id, 256, this.id);
		kv.GetString("name", this.name, 256, this.name);
		kv.GetString("model", this.model, PLATFORM_MAX_PATH, this.model);
		kv.GetString("script", this.script, PLATFORM_MAX_PATH, this.script);
		
		char type[32];
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
		
		this.skins = new ArrayList();
		
		char skins[128];
		kv.GetString("skins", skins, sizeof(skins), "0");
		
		char split[32][4];
		int retrieved = ExplodeString(skins, ",", split, sizeof(split), sizeof(split[]));
		for (int i = 0; i < retrieved; i++)
		{
			int skin;
			if (TrimString(split[i]) > 0 && StringToIntEx(split[i], skin) > 0)
				this.skins.Push(skin);
		}
		
		this.lock_speed = kv.GetFloat("lock_speed", 10.0);
		kv.GetString("key_hint", this.key_hint, 256);
		this.is_passenger_visible = view_as<bool>(kv.GetNum("is_passenger_visible", true));
		
		kv.GetString("horn_sound", this.horn_sound, PLATFORM_MAX_PATH);
		if (this.horn_sound[0] != '\0')
		{
			char filepath[PLATFORM_MAX_PATH];
			Format(filepath, sizeof(filepath), "sound/%s", this.horn_sound);
			if (FileExists(filepath, true))
			{
				AddFileToDownloadsTable(filepath);
				Format(this.horn_sound, PLATFORM_MAX_PATH, ")%s", this.horn_sound);
				PrecacheSound(this.horn_sound);
			}
			else
			{
				LogError("The file '%s' does not exist!", filepath);
				this.horn_sound[0] = '\0';
			}
		}
		
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

enum struct VehicleProperties
{
	int entity;
	int owner;
	
	void Initialize(int entity)
	{
		this.entity = entity;
	}
}

ConVar vehicle_config_path;
ConVar vehicle_physics_damage_modifier;
ConVar vehicle_passenger_damage_modifier;
ConVar vehicle_enable_entry_exit_anims;
ConVar vehicle_enable_horns;

GlobalForward g_ForwardOnVehicleSpawned;
GlobalForward g_ForwardOnVehicleDestroyed;

DynamicHook g_DHookSetPassenger;
DynamicHook g_DHookIsPassengerVisible;
DynamicHook g_DHookHandlePassengerEntry;
DynamicHook g_DHookGetExitAnimToUse;
DynamicHook g_DHookGetInVehicle;
DynamicHook g_DHookLeaveVehicle;

Handle g_SDKCallVehicleSetupMove;
Handle g_SDKCallCanEnterVehicle;
Handle g_SDKCallGetAttachmentLocal;
Handle g_SDKCallGetVehicleEnt;
Handle g_SDKCallHandlePassengerEntry;
Handle g_SDKCallHandlePassengerExit;
Handle g_SDKCallHandleEntryExitFinish;
Handle g_SDKCallStudioFrameAdvance;
Handle g_SDKCallGetInVehicle;

ArrayList g_AllVehicles;
ArrayList g_VehicleProperties;

char g_OldAllowPlayerUse[8];
char g_OldTurboPhysics[8];

bool g_ClientIsUsingHorn[MAXPLAYERS + 1];

methodmap Vehicle
{
	public Vehicle(int entity)
	{
		if (!IsValidEntity(entity))
			return view_as<Vehicle>(INVALID_ENT_REFERENCE);
		
		entity = EntIndexToEntRef(entity);
		
		if (g_VehicleProperties.FindValue(entity, VehicleProperties::entity) == -1)
		{
			VehicleProperties properties;
			properties.Initialize(entity);
			
			g_VehicleProperties.PushArray(properties);
		}
		
		return view_as<Vehicle>(entity);
	}
	
	property int Owner
	{
		public get()
		{
			int index = g_VehicleProperties.FindValue(view_as<int>(this), VehicleProperties::entity);
			return g_VehicleProperties.Get(index, VehicleProperties::owner);
		}
		public set(int value)
		{
			int index = g_VehicleProperties.FindValue(view_as<int>(this), VehicleProperties::entity);
			g_VehicleProperties.Set(index, value, VehicleProperties::owner);
		}
	}
	
	public void Destroy()
	{
		int index = g_VehicleProperties.FindValue(view_as<int>(this), VehicleProperties::entity);
		g_VehicleProperties.Erase(index);
	}
	
	public static void InitializePropertyList()
	{
		g_VehicleProperties = new ArrayList(sizeof(VehicleProperties));
	}
}

public Plugin myinfo = 
{
	name = "Driveable Vehicles", 
	author = PLUGIN_AUTHOR, 
	description = "Fully functioning driveable vehicles", 
	version = PLUGIN_VERSION, 
	url = PLUGIN_URL
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
	{
#if defined _loadsoundscript_included
		LoadSoundScript("scripts/game_sounds_vehicles.txt");
#else
		LogMessage("LoadSoundscript extension was found but plugin was compiled without support for it, vehicles won't have sounds");
#endif
	} 
	else
	{
		LogMessage("LoadSoundScript extension could not be found, vehicles won't have sounds");
	}
	
	//Create plugin convars
	vehicle_config_path = CreateConVar("vehicle_config_path", "configs/vehicles/vehicles.cfg", "Path to vehicle configuration file, relative to the SourceMod folder");
	vehicle_config_path.AddChangeHook(ConVarChanged_RefreshVehicleConfig);
	vehicle_physics_damage_modifier = CreateConVar("vehicle_physics_damage_modifier", "1.0", "Modifier of impact-based physics damage against other players", _, true, 0.0);
	vehicle_passenger_damage_modifier = CreateConVar("vehicle_passenger_damage_modifier", "1.0", "Modifier of damage dealt to vehicle passengers", _, true, 0.0);
	vehicle_enable_entry_exit_anims = CreateConVar("vehicle_enable_entry_exit_anims", "0", "If set to 1, enables entry and exit animations (experimental)");
	vehicle_enable_horns = CreateConVar("vehicle_enable_horns", "1", "If set to 1, enables vehicle horns");
	
	RegAdminCmd("sm_vehicle", ConCmd_OpenVehicleMenu, ADMFLAG_GENERIC);
	RegAdminCmd("sm_vehicles", ConCmd_OpenVehicleMenu, ADMFLAG_GENERIC);
	RegAdminCmd("sm_createvehicle", ConCmd_CreateVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_spawnvehicle", ConCmd_CreateVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_destroyvehicle", ConCmd_DestroyVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_removevehicle", ConCmd_DestroyVehicle, ADMFLAG_GENERIC);
	RegAdminCmd("sm_destroyallvehicles", ConCmd_DestroyAllVehicles, ADMFLAG_GENERIC);
	RegAdminCmd("sm_removeallvehicles", ConCmd_DestroyAllVehicles, ADMFLAG_GENERIC);
	
	Vehicle.InitializePropertyList();
	
	g_AllVehicles = new ArrayList(sizeof(VehicleConfig));
	
	GameData gamedata = new GameData("vehicles");
	if (gamedata == null)
		SetFailState("Could not find vehicles gamedata");
	
	CreateDynamicDetour(gamedata, "CPlayerMove::SetupMove", DHookCallback_SetupMovePre);
	g_DHookSetPassenger = CreateDynamicHook(gamedata, "CBaseServerVehicle::SetPassenger");
	g_DHookIsPassengerVisible = CreateDynamicHook(gamedata, "CBaseServerVehicle::IsPassengerVisible");
	g_DHookHandlePassengerEntry = CreateDynamicHook(gamedata, "CBaseServerVehicle::HandlePassengerEntry");
	g_DHookGetExitAnimToUse = CreateDynamicHook(gamedata, "CBaseServerVehicle::GetExitAnimToUse");
	g_DHookGetInVehicle = CreateDynamicHook(gamedata, "CBasePlayer::GetInVehicle");
	g_DHookLeaveVehicle = CreateDynamicHook(gamedata, "CBasePlayer::LeaveVehicle");
	
	g_SDKCallVehicleSetupMove = PrepSDKCall_VehicleSetupMove(gamedata);
	g_SDKCallCanEnterVehicle = PrepSDKCall_CanEnterVehicle(gamedata);
	g_SDKCallGetAttachmentLocal = PrepSDKCall_GetAttachmentLocal(gamedata);
	g_SDKCallGetVehicleEnt = PrepSDKCall_GetVehicleEnt(gamedata);
	g_SDKCallHandlePassengerEntry = PrepSDKCall_HandlePassengerEntry(gamedata);
	g_SDKCallHandlePassengerExit = PrepSDKCall_HandlePassengerExit(gamedata);
	g_SDKCallHandleEntryExitFinish = PrepSDKCall_HandleEntryExitFinish(gamedata);
	g_SDKCallStudioFrameAdvance = PrepSDKCall_StudioFrameAdvance(gamedata);
	g_SDKCallGetInVehicle = PrepSDKCall_GetInVehicle(gamedata);
	
	delete gamedata;
	
	//Hook all clients
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
			OnClientPutInServer(client);
	}
}

public void OnPluginEnd()
{
	RestoreConVar("tf_allow_player_use", g_OldAllowPlayerUse);
	RestoreConVar("sv_turbophysics", g_OldTurboPhysics);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("vehicles");
	
	CreateNative("Vehicle.Owner.get", NativeCall_VehicleOwnerGet);
	CreateNative("Vehicle.Owner.set", NativeCall_VehicleOwnerSet);
	CreateNative("Vehicle.Create", NativeCall_VehicleCreate);
	CreateNative("Vehicle.ForcePlayerIn", NativeCall_VehicleForcePlayerIn);
	CreateNative("Vehicle.ForcePlayerOut", NativeCall_VehicleForcePlayerOut);
	
	g_ForwardOnVehicleSpawned = new GlobalForward("OnVehicleSpawned", ET_Ignore, Param_Cell);
	g_ForwardOnVehicleDestroyed = new GlobalForward("OnVehicleDestroyed", ET_Ignore, Param_Cell);
	
	MarkNativeAsOptional("LoadSoundScript");
}

public void OnMapStart()
{
	SetupConVar("tf_allow_player_use", g_OldAllowPlayerUse, sizeof(g_OldAllowPlayerUse), "1");
	SetupConVar("sv_turbophysics", g_OldTurboPhysics, sizeof(g_OldTurboPhysics), "0");
	
	//Hook all vehicles
	int vehicle;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		SDKHook(vehicle, SDKHook_Think, PropVehicleDriveable_Think);
		SDKHook(vehicle, SDKHook_Use, PropVehicleDriveable_Use);
		SDKHook(vehicle, SDKHook_OnTakeDamage, PropVehicleDriveable_OnTakeDamage);
		
		DHookVehicle(GetServerVehicle(vehicle));
	}
}

public void OnConfigsExecuted()
{
	ReadVehicleConfig();
}

public void OnClientPutInServer(int client)
{
	DHookClient(client);
	SDKHook(client, SDKHook_OnTakeDamage, Client_OnTakeDamage);
	g_ClientIsUsingHorn[client] = false;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (vehicle_enable_horns.BoolValue)
	{
		int vehicle = GetEntPropEnt(client, Prop_Data, "m_hVehicle");
		if (vehicle != -1)
		{
			VehicleConfig config;
			if (GetConfigByVehicleEnt(vehicle, config) && config.horn_sound[0] != '\0')
			{
				if (buttons & IN_ATTACK3)
				{
					if (!g_ClientIsUsingHorn[client])
					{
						g_ClientIsUsingHorn[client] = !g_ClientIsUsingHorn[client];
						EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT);
					}
				}
				else if (g_ClientIsUsingHorn[client])
				{
					g_ClientIsUsingHorn[client] = !g_ClientIsUsingHorn[client];
					EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT, SND_STOP | SND_STOPLOOPING);
				}
			}
		}
	}
	
	return Plugin_Continue;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, VEHICLE_CLASSNAME))
	{
		SDKHook(entity, SDKHook_Think, PropVehicleDriveable_Think);
		SDKHook(entity, SDKHook_Use, PropVehicleDriveable_Use);
		SDKHook(entity, SDKHook_OnTakeDamage, PropVehicleDriveable_OnTakeDamage);
		SDKHook(entity, SDKHook_Spawn, PropVehicleDriveable_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, PropVehicleDriveable_SpawnPost);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity == -1)
		return;
	
	if (IsEntityVehicle(entity))
	{
		Forward_OnVehicleDestroyed(entity);
		
		Vehicle(entity).Destroy();
		SDKCall_HandleEntryExitFinish(GetServerVehicle(entity), true, true);
	}
}

//-----------------------------------------------------------------------------
// Plugin Functions
//-----------------------------------------------------------------------------

int CreateVehicle(VehicleConfig config, float origin[3], float angles[3], int owner = 0)
{
	int vehicle = CreateEntityByName(VEHICLE_CLASSNAME);
	if (vehicle != -1)
	{
		char targetname[256];
		Format(targetname, sizeof(targetname), "%s_%d", config.id, vehicle);
		
		DispatchKeyValue(vehicle, "targetname", targetname);
		DispatchKeyValue(vehicle, "model", config.model);
		DispatchKeyValue(vehicle, "vehiclescript", config.script);
		DispatchKeyValue(vehicle, "spawnflags", "1");	//SF_PROP_VEHICLE_ALWAYSTHINK
		DispatchKeyValueVector(vehicle, "origin", origin);
		DispatchKeyValueVector(vehicle, "angles", angles);
		
		SetEntProp(vehicle, Prop_Data, "m_nSkin", config.skins.Get(GetRandomInt(0, config.skins.Length - 1)));
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
		
		Vehicle(vehicle).Owner = owner;
		
		if (DispatchSpawn(vehicle))
		{
			AcceptEntityInput(vehicle, "HandBrakeOn");
			
			return EntIndexToEntRef(vehicle);
		}
	}
	
	return INVALID_ENT_REFERENCE;
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
	char classname[32];
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

bool IsOverturned(int vehicle)
{
	float angles[3];
	GetEntPropVector(vehicle, Prop_Data, "m_angAbsRotation", angles);
	
	float up[3];
	GetAngleVectors(angles, NULL_VECTOR, NULL_VECTOR, up);
	
	float upDot = GetVectorDotProduct(view_as<float>( { 0.0, 0.0, 1.0 } ), up);
	
	//Tweak this number to adjust what's considered "overturned"
	if (upDot < 0.0)
		return true;
	
	return false;
}

//This is pretty much an exact copy of CPropVehicleDriveable::CanEnterVehicle
bool CanEnterVehicle(int client, int vehicle)
{
	//Prevent entering if the vehicle's being driven by another player
	int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	if (driver != -1 && driver != client)
		return false;
	
	if (IsOverturned(vehicle))
		return false;
	
	//Prevent entering if the vehicle's locked, or if it's moving too fast.
	return !GetEntProp(vehicle, Prop_Data, "m_bLocked") && GetEntProp(vehicle, Prop_Data, "m_nSpeed") <= GetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit");
}

void ReadVehicleConfig()
{
	//Clear previously loaded vehicles
	g_AllVehicles.Clear();
	
	//Build path to config file
	char file[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	vehicle_config_path.GetString(file, sizeof(file));
	BuildPath(Path_SM, path, sizeof(path), file);
	
	//Read the vehicle configuration
	KeyValues kv = new KeyValues("Vehicles");
	if (kv.ImportFromFile(path))
	{
		//Read through every Vehicle
		if (kv.GotoFirstSubKey(false))
		{
			do
			{
				VehicleConfig config;
				config.ReadConfig(kv);
				g_AllVehicles.PushArray(config);
			}
			while (kv.GotoNextKey(false));
			kv.GoBack();
		}
		kv.GoBack();
		delete kv;
		
		LogMessage("Successfully loaded %d vehicles from configuration", g_AllVehicles.Length);
	}
	else
	{
		LogError("Failed to import configuration file: %s", file);
	}
}

bool GetConfigById(const char[] id, VehicleConfig buffer)
{
	int index = g_AllVehicles.FindString(id);
	if (index != -1)
		return g_AllVehicles.GetArray(index, buffer, sizeof(buffer)) > 0;
	
	return false;
}

bool GetConfigByModel(const char[] model, VehicleConfig buffer)
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

bool GetConfigByModelAndVehicleScript(const char[] model, const char[] vehiclescript, VehicleConfig buffer)
{
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		if (g_AllVehicles.GetArray(i, buffer, sizeof(buffer)) > 0)
		{
			if (StrEqual(model, buffer.model) && StrEqual(vehiclescript, buffer.script))
				return true;
		}
	}
	
	return false;
}

bool GetConfigByVehicleEnt(int vehicle, VehicleConfig buffer)
{
	char model[PLATFORM_MAX_PATH], vehiclescript[PLATFORM_MAX_PATH];
	GetEntPropString(vehicle, Prop_Data, "m_ModelName", model, sizeof(model));
	GetEntPropString(vehicle, Prop_Data, "m_vehicleScript", vehiclescript, sizeof(vehiclescript));
	
	return GetConfigByModelAndVehicleScript(model, vehiclescript, buffer);
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
// ConVars
//-----------------------------------------------------------------------------

public void ConVarChanged_RefreshVehicleConfig(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadVehicleConfig();
}

//-----------------------------------------------------------------------------
// Natives
//-----------------------------------------------------------------------------

public int NativeCall_VehicleOwnerGet(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	return Vehicle(vehicle).Owner;
}

public int NativeCall_VehicleOwnerSet(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int owner = GetNativeCell(2);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	return Vehicle(vehicle).Owner = owner;
}

public int NativeCall_VehicleCreate(Handle plugin, int numParams)
{
	VehicleConfig config;
	
	char id[256];
	if (GetNativeString(1, id, sizeof(id)) == SP_ERROR_NONE && GetConfigById(id, config))
	{
		float origin[3], angles[3];
		GetNativeArray(2, origin, sizeof(origin));
		GetNativeArray(3, angles, sizeof(angles));
		int owner = GetNativeCell(4);
		
		int vehicle = CreateVehicle(config, origin, angles, owner);
		if (vehicle != INVALID_ENT_REFERENCE)
		{
			return EntRefToEntIndex(vehicle);
		}
		else
		{
			return ThrowNativeError(SP_ERROR_NATIVE, "Failed to create vehicle: %s", id);
		}
	}
	else
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid or unknown vehicle: %s", id);
	}
}

public int NativeCall_VehicleForcePlayerIn(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int client = GetNativeCell(2);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	if (client < 1 || client > MaxClients)
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if (!IsClientInGame(client))
		ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	SDKCall_HandlePassengerEntry(GetServerVehicle(vehicle), client, true);
}

public int NativeCall_VehicleForcePlayerOut(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	
	if (client == -1)
		return;
	
	SDKCall_HandlePassengerExit(GetServerVehicle(vehicle), client);
}

//-----------------------------------------------------------------------------
// Forwards
//-----------------------------------------------------------------------------

void Forward_OnVehicleSpawned(int vehicle)
{
	Call_StartForward(g_ForwardOnVehicleSpawned);
	Call_PushCell(vehicle);
	Call_Finish();
}

void Forward_OnVehicleDestroyed(int vehicle)
{
	Call_StartForward(g_ForwardOnVehicleDestroyed);
	Call_PushCell(vehicle);
	Call_Finish();
}

//-----------------------------------------------------------------------------
// Timers
//-----------------------------------------------------------------------------

public Action Timer_ShowVehicleKeyHint(Handle timer, int vehicleRef)
{
	int vehicle = EntRefToEntIndex(vehicleRef);
	if (vehicle != -1)
	{
		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != -1)
		{
			//Show different key hints based on vehicle
			VehicleConfig config;
			if (GetConfigByVehicleEnt(vehicle, config) && config.key_hint[0] != '\0')
			{
				ShowKeyHintText(client, "%t", config.key_hint);
			}
		}
	}
}

//-----------------------------------------------------------------------------
// Commands
//-----------------------------------------------------------------------------

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
	
	VehicleConfig config;
	if (!GetConfigById(id, config))
	{
		ReplyToCommand(client, "%t", "#Command_CreateVehicle_Invalid", id);
		return Plugin_Handled;
	}
	
	int vehicle = CreateVehicle(config, NULL_VECTOR, NULL_VECTOR, client);
	if (vehicle == INVALID_ENT_REFERENCE)
	{
		LogError("Failed to create vehicle: %s", id);
		return Plugin_Handled;
	}
	
	if (!TeleportEntityToClientViewPos(vehicle, client, MASK_SOLID | MASK_WATER))
	{
		RemoveEntity(vehicle);
		LogError("Failed to teleport vehicle: %s", id);
		return Plugin_Handled;
	}
	
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

public Action Client_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if (damagetype & DMG_VEHICLE && IsEntityVehicle(inflictor))
	{
		int driver = GetEntPropEnt(inflictor, Prop_Data, "m_hPlayer");
		if (driver != -1 && victim != driver)
		{
			damage *= vehicle_physics_damage_modifier.FloatValue;
			attacker = driver;
			return Plugin_Changed;
		}
	}
	
	return Plugin_Continue;
}

public void PropVehicleDriveable_Think(int vehicle)
{
	int sequence = GetEntProp(vehicle, Prop_Data, "m_nSequence");
	bool sequenceFinished = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bSequenceFinished"));
	bool enterAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bEnterAnimOn"));
	bool exitAnimOn = view_as<bool>(GetEntProp(vehicle, Prop_Data, "m_bExitAnimOn"));
	
	SDKCall_StudioFrameAdvance(vehicle);
	
	if ((sequence == 0 || sequenceFinished) && (enterAnimOn || exitAnimOn))
	{
		if (enterAnimOn)
		{
			AcceptEntityInput(vehicle, "TurnOn");
			
			CreateTimer(1.5, Timer_ShowVehicleKeyHint, EntIndexToEntRef(vehicle));
		}
		
		SDKCall_HandleEntryExitFinish(GetServerVehicle(vehicle), exitAnimOn, true);
	}
}

public Action PropVehicleDriveable_OnTakeDamage(int vehicle, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
	//Make the driver take the damage
	int client = GetEntPropEnt(vehicle, Prop_Send, "m_hPlayer");
	if (client != -1)
	{
		//Never take crush damage
		if (damagetype & DMG_CRUSH)
			return Plugin_Continue;
		
		//Scale the damage
		SDKHooks_TakeDamage(client, inflictor, attacker, damage * vehicle_passenger_damage_modifier.FloatValue, damagetype | DMG_VEHICLE, weapon, damageForce, damagePosition);
	}
	
	return Plugin_Continue;
}

public void PropVehicleDriveable_Spawn(int vehicle)
{
	char model[PLATFORM_MAX_PATH], vehiclescript[PLATFORM_MAX_PATH];
	GetEntPropString(vehicle, Prop_Data, "m_ModelName", model, sizeof(model));
	GetEntPropString(vehicle, Prop_Data, "m_vehicleScript", vehiclescript, sizeof(vehiclescript));
	
	VehicleConfig config;
	
	//If no script is set, try to find a matching config entry and set it ourselves
	if (vehiclescript[0] == '\0' && GetConfigByModel(model, config))
	{
		vehiclescript = config.script;
		DispatchKeyValue(vehicle, "VehicleScript", config.script);
	}
	
	if (GetConfigByModelAndVehicleScript(model, vehiclescript, config))
	{
		SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
	}
}

public void PropVehicleDriveable_SpawnPost(int vehicle)
{
	//m_pServerVehicle is initialized in Spawn so we hook it in SpawnPost
	DHookVehicle(GetServerVehicle(vehicle));
	
	VehicleConfig config;
	if (GetConfigByVehicleEnt(vehicle, config))
	{
		SetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit", config.lock_speed);
	}
	
	Forward_OnVehicleSpawned(vehicle);
}

public Action PropVehicleDriveable_Use(int vehicle, int activator, int caller, UseType type, float value)
{
	//Prevent call to ResetUseKey and HandlePassengerEntry for the driving player
	int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	if (0 < activator <= MaxClients && driver != -1 && driver == activator)
		return Plugin_Handled;
	
	return Plugin_Continue;
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
		VehicleConfig config;
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
			VehicleConfig config;
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)) && GetConfigById(info, config) && TranslationPhraseExists(config.name))
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
		LogError("Failed to create detour setup handle for %s", name);
	}
}

DynamicHook CreateDynamicHook(GameData gamedata, const char[] name)
{
	DynamicHook hook = DynamicHook.FromConf(gamedata, name);
	if (hook == null)
		LogError("Failed to create hook setup handle for %s", name);
	
	return hook;
}

void DHookClient(int client)
{
	if (g_DHookGetInVehicle != null)
		g_DHookGetInVehicle.HookEntity(Hook_Pre, client, DHookCallback_GetInVehiclePre);
	
	if (g_DHookLeaveVehicle != null)
		g_DHookLeaveVehicle.HookEntity(Hook_Pre, client, DHookCallback_LeaveVehiclePre);
}

void DHookVehicle(Address serverVehicle)
{
	if (g_DHookSetPassenger != null)
		g_DHookSetPassenger.HookRaw(Hook_Pre, serverVehicle, DHookCallback_SetPassengerPre);
	
	if (g_DHookIsPassengerVisible != null)
		g_DHookIsPassengerVisible.HookRaw(Hook_Post, serverVehicle, DHookCallback_IsPassengerVisiblePost);
	
	if (g_DHookHandlePassengerEntry != null)
		g_DHookHandlePassengerEntry.HookRaw(Hook_Pre, serverVehicle, DHookCallback_HandlePassengerEntryPre);
	
	if (g_DHookGetExitAnimToUse != null)
		g_DHookGetExitAnimToUse.HookRaw(Hook_Post, serverVehicle, DHookCallback_GetExitAnimToUsePost);
}

public MRESReturn DHookCallback_SetupMovePre(DHookParam params)
{
	int client = params.Get(1);
	
	int vehicle = GetEntPropEnt(client, Prop_Data, "m_hVehicle");
	if (vehicle != -1)
	{
		Address ucmd = params.Get(2);
		Address helper = params.Get(3);
		Address move = params.Get(4);
		
		SDKCall_VehicleSetupMove(GetServerVehicle(vehicle), client, ucmd, helper, move);
	}
}

public MRESReturn DHookCallback_SetPassengerPre(Address serverVehicle, DHookParam params)
{
	int vehicle = SDKCall_GetVehicleEnt(serverVehicle);
	
	if (!params.IsNull(2))
	{
		SetEntProp(params.Get(2), Prop_Send, "m_bDrawViewmodel", false);
	}
	else
	{
		//Stop any horn sounds when the player leaves the vehicle
		VehicleConfig config;
		if (GetConfigByVehicleEnt(vehicle, config) && config.horn_sound[0] != '\0')
		{
			EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT, SND_STOP | SND_STOPLOOPING);
		}
		
		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != -1)
		{
			g_ClientIsUsingHorn[client] = false;
			SetEntProp(client, Prop_Send, "m_bDrawViewmodel", true);
		}
	}
}

public MRESReturn DHookCallback_IsPassengerVisiblePost(Address serverVehicle, DHookReturn ret)
{
	VehicleConfig config;
	if (GetConfigByVehicleEnt(SDKCall_GetVehicleEnt(serverVehicle), config))
	{
		ret.Value = config.is_passenger_visible;
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_HandlePassengerEntryPre(Address serverVehicle, DHookParam params)
{
	if (!vehicle_enable_entry_exit_anims.BoolValue)
	{
		int client = params.Get(1);
		int vehicle = SDKCall_GetVehicleEnt(serverVehicle);
		
		if (CanEnterVehicle(client, vehicle))	//CPropVehicleDriveable::CanEnterVehicle
		{
			if (SDKCall_CanEnterVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER))	//CBasePlayer::CanEnterVehicle
			{
				SDKCall_GetInVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER);
				
				//Snap the driver's view where the vehicle is facing
				float origin[3], angles[3];
				if (SDKCall_GetAttachmentLocal(vehicle, "vehicle_driver_eyes", origin, angles))
					TeleportEntity(client, NULL_VECTOR, angles, NULL_VECTOR);
				
				CreateTimer(1.5, Timer_ShowVehicleKeyHint, EntIndexToEntRef(vehicle));
			}
		}
		
		return MRES_Supercede;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetExitAnimToUsePost(Address serverVehicle, DHookReturn ret)
{
	if (!vehicle_enable_entry_exit_anims.BoolValue)
	{
		ret.Value = ACTIVITY_NOT_AVAILABLE;
		return MRES_Override;
	}
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_GetInVehiclePre(int client)
{
	//Disable client prediction for less jittery movement
	if (!IsFakeClient(client))
		SendConVarValue(client, FindConVar("sv_client_predict"), "0");
}

public MRESReturn DHookCallback_LeaveVehiclePre(int client)
{
	//Re-enable client prediction
	if (!IsFakeClient(client))
		SendConVarValue(client, FindConVar("sv_client_predict"), "1");
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
		LogMessage("Failed to create SDK call: CBaseServerVehicle::SetupMove");
	
	return call;
}

Handle PrepSDKCall_CanEnterVehicle(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBasePlayer::CanEnterVehicle");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDK call: CBasePlayer::CanEnterVehicle");
	
	return call;
}

Handle PrepSDKCall_GetAttachmentLocal(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBaseAnimating::GetAttachmentLocal");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDK call: CBaseAnimating::GetAttachmentLocal");
	
	return call;
}

Handle PrepSDKCall_GetVehicleEnt(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::GetVehicleEnt");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::GetVehicleEnt");
	
	return call;
}

Handle PrepSDKCall_HandlePassengerEntry(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandlePassengerEntry");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandlePassengerEntry");
	
	return call;
}

Handle PrepSDKCall_HandlePassengerExit(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandlePassengerExit");
	PrepSDKCall_AddParameter(SDKType_CBaseEntity, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandlePassengerExit");
	
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
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandleEntryExitFinish");
	
	return call;
}

Handle PrepSDKCall_StudioFrameAdvance(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseAnimating::StudioFrameAdvance");
	
	Handle call = EndPrepSDKCall();
	if (call == null)
		LogError("Failed to create SDK call: CBaseAnimating::StudioFrameAdvance");
	
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
		LogError("Failed to create SDK call: CBasePlayer::GetInVehicle");
	
	return call;
}

void SDKCall_VehicleSetupMove(Address serverVehicle, int client, Address ucmd, Address helper, Address move)
{
	if (g_SDKCallVehicleSetupMove != null)
		SDKCall(g_SDKCallVehicleSetupMove, serverVehicle, client, ucmd, helper, move);
}

bool SDKCall_CanEnterVehicle(int client, Address serverVehicle, PassengerRole role)
{
	if (g_SDKCallCanEnterVehicle != null)
		return SDKCall(g_SDKCallCanEnterVehicle, client, serverVehicle, role);
	
	return false;
}

bool SDKCall_GetAttachmentLocal(int entity, const char[] name, float origin[3], float angles[3])
{
	if (g_SDKCallGetAttachmentLocal != null)
		return SDKCall(g_SDKCallGetAttachmentLocal, entity, name, origin, angles);
	
	return false;
}

int SDKCall_GetVehicleEnt(Address serverVehicle)
{
	if (g_SDKCallGetVehicleEnt != null)
		return SDKCall(g_SDKCallGetVehicleEnt, serverVehicle);
	
	return -1;
}

void SDKCall_HandlePassengerEntry(Address serverVehicle, int passenger, bool allowEntryOutsideZone)
{
	if (g_SDKCallHandlePassengerEntry != null)
		SDKCall(g_SDKCallHandlePassengerEntry, serverVehicle, passenger, allowEntryOutsideZone);
}

bool SDKCall_HandlePassengerExit(Address serverVehicle, int passenger)
{
	if (g_SDKCallHandlePassengerExit != null)
		return SDKCall(g_SDKCallHandlePassengerExit, serverVehicle, passenger);
	
	return false;
}

void SDKCall_HandleEntryExitFinish(Address serverVehicle, bool exitAnimOn, bool resetAnim)
{
	if (g_SDKCallHandleEntryExitFinish != null)
		SDKCall(g_SDKCallHandleEntryExitFinish, serverVehicle, exitAnimOn, resetAnim);
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
