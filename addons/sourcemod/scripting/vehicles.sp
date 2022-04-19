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

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <adminmenu>
#include <dhooks>

#undef REQUIRE_EXTENSIONS
#tryinclude <loadsoundscript>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION	"2.4.0"
#define PLUGIN_AUTHOR	"Mikusch"
#define PLUGIN_URL		"https://github.com/Mikusch/source-vehicles"

#define VEHICLE_CLASSNAME	"prop_vehicle_driveable"

#define COLLISION_GROUP_VEHICLE			7
#define TFCOLLISION_GROUP_RESPAWNROOMS	25

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
	VEHICLE_TYPE_AIRBOAT_RAYCAST = (1 << 3),
}

bool g_LoadSoundscript;

ConVar vehicle_config_path;
ConVar vehicle_physics_damage_modifier;
ConVar vehicle_passenger_damage_modifier;
ConVar vehicle_enable_entry_exit_anims;
ConVar vehicle_enable_horns;

DynamicHook g_DHookShouldCollide;
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

bool g_ClientInUse[MAXPLAYERS + 1];
bool g_ClientIsUsingHorn[MAXPLAYERS + 1];

enum struct VehicleConfig
{
	char id[256];							/**< Unique identifier of the vehicle */
	char name[256];							/**< Display name of the vehicle */
	char model[PLATFORM_MAX_PATH];			/**< Vehicle model */
	char script[PLATFORM_MAX_PATH];			/**< Vehicle script path */
	VehicleType type;						/**< The type of vehicle */
	char soundscript[PLATFORM_MAX_PATH];	/**< Custom soundscript */
	ArrayList skins;						/**< Model skins */
	char key_hint[256];						/**< Vehicle key hint */
	float lock_speed;						/**< Vehicle lock speed */
	bool is_passenger_visible;				/**< Whether the passenger is visible */
	char horn_sound[PLATFORM_MAX_PATH];		/**< Custom horn sound */
	
	void ReadConfig(KeyValues kv)
	{
		if (kv.GetSectionName(this.id, sizeof(this.id)))
		{
			kv.GetString("name", this.name, sizeof(this.name));
			kv.GetString("model", this.model, sizeof(this.model));
			kv.GetString("script", this.script, sizeof(this.script));
			
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
				LogError("%s: Invalid vehicle type '%s'", this.id, type);
			
			kv.GetString("soundscript", this.soundscript, sizeof(this.soundscript));
			if (this.soundscript[0] != '\0')
			{
				if (g_LoadSoundscript)
				{
#if defined _loadsoundscript_included
					SoundScript soundscript = LoadSoundScript(this.soundscript);
					for (int i = 0; i < soundscript.Count; i++)
					{
						SoundEntry entry = soundscript.GetSound(i);
						char soundname[256];
						entry.GetName(soundname, sizeof(soundname));
						PrecacheScriptSound(soundname);
					}
#else
					LogMessage("%s: Failed to load vehicle soundscript '%s' because the plugin was compiled without the LoadSoundscript include", this.id, this.soundscript);
#endif
				}
				else
				{
					LogMessage("%s: Failed to load vehicle soundscript '%s' because the LoadSoundscript extension could not be found", this.id, this.soundscript);
				}
			}
			
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
			kv.GetString("key_hint", this.key_hint, sizeof(this.key_hint));
			this.is_passenger_visible = kv.GetNum("is_passenger_visible", true) != 0;
			
			kv.GetString("horn_sound", this.horn_sound, sizeof(this.horn_sound));
			if (this.horn_sound[0] != '\0')
			{
				char filepath[PLATFORM_MAX_PATH];
				Format(filepath, sizeof(filepath), "sound/%s", this.horn_sound);
				if (FileExists(filepath, true))
				{
					AddFileToDownloadsTable(filepath);
					Format(this.horn_sound, sizeof(this.horn_sound), ")%s", this.horn_sound);
					PrecacheSound(this.horn_sound);
				}
				else
				{
					LogError("%s: The file '%s' does not exist", this.id, filepath);
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
}

enum struct VehicleProperties
{
	int entity;
	int owner;
}

methodmap Player
{
	public Player(int client)
	{
		return view_as<Player>(client);
	}
	
	property int _client
	{
		public get()
		{
			return view_as<int>(this);
		}
	}
	
	property bool InUse
	{
		public get()
		{
			return g_ClientInUse[this._client];
		}
		public set(bool value)
		{
			g_ClientInUse[this._client] = value;
		}
	}
	
	property bool IsUsingHorn
	{
		public get()
		{
			return g_ClientIsUsingHorn[this._client];
		}
		public set(bool value)
		{
			g_ClientIsUsingHorn[this._client] = value;
		}
	}
	
	public void Reset()
	{
		this.InUse = false;
		this.IsUsingHorn = false;
	}
}

methodmap Vehicle
{
	public Vehicle(int entity)
	{
		return view_as<Vehicle>(entity);
	}
	
	property int _entityRef
	{
		public get()
		{
			// Doubly convert it to ensure it is an entity reference
			return EntIndexToEntRef(EntRefToEntIndex(view_as<int>(this)));
		}
	}
	
	property int _listIndex
	{
		public get()
		{
			return g_VehicleProperties.FindValue(this._entityRef, VehicleProperties::entity);
		}
	}
	
	property int Owner
	{
		public get()
		{
			if (this._listIndex != -1)
				return g_VehicleProperties.Get(this._listIndex, VehicleProperties::owner);
			
			return -1;
		}
		public set(int value)
		{
			if (this._listIndex != -1)
				g_VehicleProperties.Set(this._listIndex, value, VehicleProperties::owner);
		}
	}
	
	public static bool Register(int entity)
	{
		if (!IsValidEntity(entity))
			return false;
		
		// Doubly convert it to ensure it is an entity reference
		entity = EntIndexToEntRef(EntRefToEntIndex(entity));
		
		if (g_VehicleProperties.FindValue(entity, VehicleProperties::entity) == -1)
		{
			VehicleProperties properties;
			properties.entity = entity;
			
			g_VehicleProperties.PushArray(properties);
		}
		
		return true;
	}
	
	public void Destroy()
	{
		// Delay by one frame to allow subplugins to access data in OnEntityDestroyed
		RequestFrame(RequestFrameCallback_DestroyVehicle, this._entityRef);
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
	
	// Create plugin convars
	vehicle_config_path = CreateConVar("vehicle_config_path", "configs/vehicles/vehicles.cfg", "Path to vehicle configuration file, relative to the SourceMod folder.");
	vehicle_config_path.AddChangeHook(ConVarChanged_ReloadVehicleConfig);
	vehicle_physics_damage_modifier = CreateConVar("vehicle_physics_damage_modifier", "1.0", "Modifier of impact-based physics damage against other players.", _, true, 0.0);
	vehicle_passenger_damage_modifier = CreateConVar("vehicle_passenger_damage_modifier", "1.0", "Modifier of damage dealt to vehicle passengers.", _, true, 0.0);
	vehicle_enable_entry_exit_anims = CreateConVar("vehicle_enable_entry_exit_anims", "0", "If set to 1, enables entry and exit animations.");
	vehicle_enable_horns = CreateConVar("vehicle_enable_horns", "1", "If set to 1, enables vehicle horns.");
	
	RegAdminCmd("sm_vehicle", ConCmd_OpenVehicleMenu, ADMFLAG_GENERIC, "Open vehicle menu");
	RegAdminCmd("sm_vehicle_create", ConCmd_CreateVehicle, ADMFLAG_GENERIC, "Create new vehicle");
	RegAdminCmd("sm_vehicle_removeaim", ConCmd_RemoveAimTargetVehicle, ADMFLAG_GENERIC, "Remove vehicle at crosshair");
	RegAdminCmd("sm_vehicle_remove", ConCmd_RemovePlayerVehicles, ADMFLAG_GENERIC, "Remove player vehicles");
	RegAdminCmd("sm_vehicle_removeall", ConCmd_RemoveAllVehicles, ADMFLAG_BAN, "Remove all vehicles");
	RegAdminCmd("sm_vehicle_reload", ConCmd_ReloadVehicleConfig, ADMFLAG_CONFIG, "Reload vehicle configuration");
	
	AddCommandListener(CommandListener_VoiceMenu, "voicemenu");
	
	g_VehicleProperties = new ArrayList(sizeof(VehicleProperties));
	g_AllVehicles = new ArrayList(sizeof(VehicleConfig));
	
	GameData gamedata = new GameData("vehicles");
	if (!gamedata)
		SetFailState("Could not find vehicles gamedata");
	
	CreateDynamicDetour(gamedata, "CPlayerMove::SetupMove", DHookCallback_SetupMovePre);
	g_DHookShouldCollide = CreateDynamicHook(gamedata, "CGameRules::ShouldCollide");
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
	
	// Hook all clients
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
	
	CreateNative("Vehicle.Create", NativeCall_VehicleCreate);
	CreateNative("Vehicle.Owner.get", NativeCall_VehicleOwnerGet);
	CreateNative("Vehicle.Owner.set", NativeCall_VehicleOwnerSet);
	CreateNative("Vehicle.GetId", NativeCall_VehicleGetId);
	CreateNative("Vehicle.ForcePlayerIn", NativeCall_VehicleForcePlayerIn);
	CreateNative("Vehicle.ForcePlayerOut", NativeCall_VehicleForcePlayerOut);
	CreateNative("GetVehicleName", NativeCall_GetVehicleName);
	
	MarkNativeAsOptional("LoadSoundScript");
	
	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	g_LoadSoundscript = LibraryExists("LoadSoundscript");
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "LoadSoundscript"))
	{
		g_LoadSoundscript = true;
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "LoadSoundscript"))
	{
		g_LoadSoundscript = false;
	}
}

public void OnMapStart()
{
	SetupConVar("tf_allow_player_use", g_OldAllowPlayerUse, sizeof(g_OldAllowPlayerUse), "1");
	SetupConVar("sv_turbophysics", g_OldTurboPhysics, sizeof(g_OldTurboPhysics), "0");
	
	DHookGamerulesObject();
	
	// Hook all vehicles
	int vehicle = MaxClients + 1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		Vehicle.Register(vehicle);
		
		SDKHook(vehicle, SDKHook_Think, SDKHookCB_PropVehicleDriveable_Think);
		SDKHook(vehicle, SDKHook_Use, SDKHookCB_PropVehicleDriveable_Use);
		SDKHook(vehicle, SDKHook_OnTakeDamage, SDKHookCB_PropVehicleDriveable_OnTakeDamage);
		
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
	SDKHook(client, SDKHook_OnTakeDamage, SDKHookCB_Client_OnTakeDamage);
	Player(client).Reset();
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (Player(client).InUse)
	{
		Player(client).InUse = false;
		buttons |= IN_USE;
		return Plugin_Changed;
	}
	
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
					if (!Player(client).IsUsingHorn)
					{
						Player(client).IsUsingHorn = true;
						EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT);
					}
				}
				else if (g_ClientIsUsingHorn[client])
				{
					Player(client).IsUsingHorn = false;
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
		Vehicle.Register(entity);
		
		SDKHook(entity, SDKHook_Think, SDKHookCB_PropVehicleDriveable_Think);
		SDKHook(entity, SDKHook_Use, SDKHookCB_PropVehicleDriveable_Use);
		SDKHook(entity, SDKHook_OnTakeDamage, SDKHookCB_PropVehicleDriveable_OnTakeDamage);
		SDKHook(entity, SDKHook_Spawn, SDKHookCB_PropVehicleDriveable_Spawn);
		SDKHook(entity, SDKHook_SpawnPost, SDKHookCB_PropVehicleDriveable_SpawnPost);
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity == -1)
		return;
	
	if (IsEntityVehicle(entity))
	{
		Vehicle(entity).Destroy();
		SDKCall_HandleEntryExitFinish(GetServerVehicle(entity), true, true);
	}
}

//-----------------------------------------------------------------------------
// Plugin Functions
//-----------------------------------------------------------------------------

int CreateVehicle(VehicleConfig config, float origin[3], float angles[3], int owner)
{
	int vehicle = CreateVehicleNoSpawn(config, origin, angles, owner);
	
	DispatchSpawn(vehicle);
	AcceptEntityInput(vehicle, "HandBrakeOn");
	
	return vehicle;
}

int CreateVehicleNoSpawn(VehicleConfig config, float origin[3], float angles[3], int owner)
{
	int vehicle = CreateEntityByName(VEHICLE_CLASSNAME);
	
	char targetname[256];
	Format(targetname, sizeof(targetname), "%s_%d", config.id, vehicle);
	
	DispatchKeyValue(vehicle, "targetname", targetname);
	DispatchKeyValue(vehicle, "model", config.model);
	DispatchKeyValue(vehicle, "vehiclescript", config.script);
	DispatchKeyValue(vehicle, "spawnflags", "1"); // SF_PROP_VEHICLE_ALWAYSTHINK
	DispatchKeyValueVector(vehicle, "origin", origin);
	DispatchKeyValueVector(vehicle, "angles", angles);
	
	SetEntProp(vehicle, Prop_Data, "m_nSkin", config.skins.Get(GetRandomInt(0, config.skins.Length - 1)));
	SetEntProp(vehicle, Prop_Data, "m_nVehicleType", config.type);
	
	Vehicle(vehicle).Owner = owner;
	
	return vehicle;
}

bool GetClientViewPos(int client, int entity, int mask, float position[3], float angles[3])
{
	GetClientEyePosition(client, position);
	GetClientEyeAngles(client, angles);
	
	if (TR_PointOutsideWorld(position))
		return false;
	
	// Get end position
	TR_TraceRayFilter(position, angles, mask, RayType_Infinite, TraceEntityFilter_DontHitEntity, client);
	TR_GetEndPosition(position);
	
	// Adjust for hull of passed in entity
	if (entity != -1)
	{
		float mins[3], maxs[3];
		GetEntPropVector(entity, Prop_Data, "m_vecMins", mins);
		GetEntPropVector(entity, Prop_Data, "m_vecMaxs", maxs);
		
		TR_TraceHullFilter(position, position, mins, maxs, mask, TraceEntityFilter_DontHitEntity, client);
		TR_GetEndPosition(position);
	}
	
	// Ignore angle on the x-axis
	angles[0] = 0.0;
	
	return true;
}

void PrintKeyHintText(int client, const char[] format, any...)
{
	char buffer[256];
	SetGlobalTransTarget(client);
	VFormat(buffer, sizeof(buffer), format, 3);
	
	BfWrite bf = UserMessageToBfWrite(StartMessageOne("KeyHintText", client));
	bf.WriteByte(1);	// One message
	bf.WriteString(buffer);
	EndMessage();
}

void V_swap(int &x, int &y)
{
	int temp = x;
	x = y;
	y = temp;
}

bool IsEntityClient(int client)
{
	return 0 < client <= MaxClients;
}

bool IsEntityVehicle(int entity)
{
	char classname[32];
	return IsValidEntity(entity) && GetEntityClassname(entity, classname, sizeof(classname)) && StrEqual(classname, VEHICLE_CLASSNAME);
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
	
	float upDot = GetVectorDotProduct({ 0.0, 0.0, 1.0 }, up);
	
	// Tweak this number to adjust what's considered "overturned"
	if (upDot < 0.0)
		return true;
	
	return false;
}

// This is pretty much an exact copy of CPropVehicleDriveable::CanEnterVehicle
bool CanEnterVehicle(int client, int vehicle)
{
	// Prevent entering if the vehicle's being driven by another player
	int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	if (driver != -1 && driver != client)
		return false;
	
	if (IsOverturned(vehicle))
		return false;
	
	// Prevent entering if the vehicle's locked, or if it's moving too fast.
	return !GetEntProp(vehicle, Prop_Data, "m_bLocked") && GetEntProp(vehicle, Prop_Data, "m_nSpeed") <= GetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit");
}

void ReadVehicleConfig()
{
	// Clear previously loaded vehicles
	g_AllVehicles.Clear();
	
	// Build path to config file
	char file[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	vehicle_config_path.GetString(file, sizeof(file));
	BuildPath(Path_SM, path, sizeof(path), file);
	
	// Read the vehicle configuration
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
		
		LogMessage("Successfully loaded %d vehicles from configuration", g_AllVehicles.Length);
	}
	else
	{
		LogError("Failed to import configuration file: %s", file);
	}
	delete kv;
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
	if (!convar)
	{
		convar.GetString(oldValue, maxlength);
		convar.SetString(newValue);
	}
}

void RestoreConVar(const char[] name, const char[] oldValue)
{
	ConVar convar = FindConVar(name);
	if (!convar)
	{
		convar.SetString(oldValue);
	}
}

//-----------------------------------------------------------------------------
// Natives
//-----------------------------------------------------------------------------

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
		if (vehicle != -1)
		{
			return vehicle;
		}
		else
		{
			ThrowNativeError(SP_ERROR_NATIVE, "Failed to create vehicle: %s", id);
		}
	}
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid or unknown vehicle: %s", id);
	}
	
	return -1;
}

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
	
	Vehicle(vehicle).Owner = owner;
	
	return 0;
}

public int NativeCall_VehicleGetId(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int maxlength = GetNativeCell(3);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	VehicleConfig config;
	if (GetConfigByVehicleEnt(vehicle, config))
	{
		return SetNativeString(2, config.id, maxlength) == SP_ERROR_NONE;
	}
	
	return false;
}

public int NativeCall_VehicleForcePlayerIn(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	int client = GetNativeCell(2);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	if (!IsEntityClient(client))
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	
	if (!IsClientInGame(client))
		ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not in game", client);
	
	SDKCall_HandlePassengerEntry(GetServerVehicle(vehicle), client, true);
	
	return 0;
}

public int NativeCall_VehicleForcePlayerOut(Handle plugin, int numParams)
{
	int vehicle = GetNativeCell(1);
	
	if (!IsEntityVehicle(vehicle))
		ThrowNativeError(SP_ERROR_NATIVE, "Entity %d is not a vehicle", vehicle);
	
	int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	
	if (client == -1)
		return 0;
	
	SDKCall_HandlePassengerExit(GetServerVehicle(vehicle), client);
	
	return 0;
}

public int NativeCall_GetVehicleName(Handle plugin, int numParams)
{
	VehicleConfig config;
	
	char id[256];
	if (GetNativeString(1, id, sizeof(id)) == SP_ERROR_NONE && GetConfigById(id, config))
	{
		int maxlength = GetNativeCell(3);
		int bytes;
		return SetNativeString(2, config.name, maxlength, _, bytes) == SP_ERROR_NONE && bytes > 0;
	}
	else
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Invalid or unknown vehicle: %s", id);
	}
	
	return 0;
}

//-----------------------------------------------------------------------------
// Miscellaneous Callbacks
//-----------------------------------------------------------------------------

public void ConVarChanged_ReloadVehicleConfig(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ReadVehicleConfig();
}

public Action Timer_PrintVehicleKeyHint(Handle timer, int vehicleRef)
{
	int vehicle = EntRefToEntIndex(vehicleRef);
	if (vehicle != -1)
	{
		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != -1)
		{
			// Show different key hints based on vehicle
			VehicleConfig config;
			if (GetConfigByVehicleEnt(vehicle, config) && config.key_hint[0] != '\0')
			{
				PrintKeyHintText(client, "%t", config.key_hint);
			}
		}
	}
	
	return Plugin_Continue;
}

public void RequestFrameCallback_DestroyVehicle(int entity)
{
	int index = g_VehicleProperties.FindValue(entity, VehicleProperties::entity);
	if (index != -1)
		g_VehicleProperties.Erase(index);
}

public bool TraceEntityFilter_DontHitEntity(int entity, int mask, any data)
{
	return entity != data;
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
	if (vehicle == -1)
	{
		LogError("Failed to create vehicle: %s", id);
		return Plugin_Handled;
	}
	
	float position[3], angles[3];
	if (GetClientViewPos(client, vehicle, (MASK_SOLID | MASK_WATER), position, angles))
	{
		TeleportEntity(vehicle, position, angles);
	}
	else
	{
		RemoveEntity(vehicle);
		LogError("Failed to teleport vehicle: %s", id);
	}
	
	return Plugin_Handled;
}

public Action ConCmd_RemoveAimTargetVehicle(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%t", "Command is in-game only");
		return Plugin_Handled;
	}
	
	int entity = GetClientAimTarget(client, false);
	if (IsEntityVehicle(entity))
	{
		int owner = Vehicle(entity).Owner;
		if (!IsEntityClient(owner) || CanUserTarget(client, owner))
		{
			RemoveEntity(entity);
			ShowActivity2(client, "[SM] ", "%t", "#Command_RemoveVehicle_Success");
		}
		else
		{
			ReplyToCommand(client, "%t", "Unable to target");
		}
	}
	
	return Plugin_Handled;
}

public Action ConCmd_RemovePlayerVehicles(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_vehicle_remove <#userid|name>");
		return Plugin_Handled;
	}
	
	char arg[MAX_TARGET_LENGTH];
	GetCmdArg(1, arg, sizeof(arg));
	
	char target_name[MAX_TARGET_LENGTH];
	int target_list[MAXPLAYERS], target_count;
	bool tn_is_ml;
	
	if ((target_count = ProcessTargetString(arg, client, target_list, MaxClients + 1, COMMAND_TARGET_NONE, target_name, sizeof(target_name), tn_is_ml)) <= 0)
	{
		ReplyToTargetError(client, target_count);
		return Plugin_Handled;
	}
	
	int vehicle = MaxClients + 1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		int owner = Vehicle(vehicle).Owner;
		if (!IsEntityClient(owner))
			continue;
		
		for (int i = 0; i < target_count; i++)
		{
			int target = target_list[i];
			if (owner == target)
				RemoveEntity(vehicle);
		}
	}
	
	if (tn_is_ml)
	{
		ShowActivity2(client, "[SM] ", "%t", "#Command_RemovePlayerVehicles_Success", target_name);
	}
	else
	{
		ShowActivity2(client, "[SM] ", "%t", "#Command_RemovePlayerVehicles_Success", "_s", target_name);
	}
	
	return Plugin_Handled;
}

public Action ConCmd_RemoveAllVehicles(int client, int args)
{
	int vehicle = MaxClients + 1;
	while ((vehicle = FindEntityByClassname(vehicle, VEHICLE_CLASSNAME)) != -1)
	{
		RemoveEntity(vehicle);
	}
	
	ShowActivity2(client, "[SM] ", "%t", "#Command_RemoveAllVehicles_Success");
	
	return Plugin_Handled;
}

public Action ConCmd_ReloadVehicleConfig(int client, int args)
{
	ReadVehicleConfig();
	
	ShowActivity2(client, "[SM] ", "%t", "#Command_ReloadVehicleConfig_Success");
	
	return Plugin_Handled;
}

public Action CommandListener_VoiceMenu(int client, const char[] command, int args)
{
	char arg1[2], arg2[2];
	GetCmdArg(1, arg1, sizeof(arg1));
	GetCmdArg(2, arg2, sizeof(arg2));
	
	if (GetEngineVersion() == Engine_TF2)
	{
		if (arg1[0] == '0' && arg2[0] == '0')	// MEDIC!
		{
			Player(client).InUse = true;
		}
	}
	
	return Plugin_Continue;
}

//-----------------------------------------------------------------------------
// SDKHooks
//-----------------------------------------------------------------------------

public Action SDKHookCB_Client_OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
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

public void SDKHookCB_PropVehicleDriveable_Think(int vehicle)
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
			
			CreateTimer(1.5, Timer_PrintVehicleKeyHint, EntIndexToEntRef(vehicle));
		}
		
		SDKCall_HandleEntryExitFinish(GetServerVehicle(vehicle), exitAnimOn, true);
	}
}

public Action SDKHookCB_PropVehicleDriveable_Use(int vehicle, int activator, int caller, UseType type, float value)
{
	// Prevent call to ResetUseKey and HandlePassengerEntry for the driving player
	int driver = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
	if (IsEntityClient(activator) && driver != -1 && driver == activator)
		return Plugin_Handled;
	
	return Plugin_Continue;
}

public Action SDKHookCB_PropVehicleDriveable_OnTakeDamage(int vehicle, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3])
{
	// Make the driver take the damage
	int client = GetEntPropEnt(vehicle, Prop_Send, "m_hPlayer");
	if (client != -1)
	{
		// Never take crush damage
		if (damagetype & DMG_CRUSH)
			return Plugin_Continue;
		
		// Scale the damage
		SDKHooks_TakeDamage(client, inflictor, attacker, damage * vehicle_passenger_damage_modifier.FloatValue, damagetype | DMG_VEHICLE, weapon, damageForce, damagePosition);
	}
	
	return Plugin_Continue;
}

public void SDKHookCB_PropVehicleDriveable_Spawn(int vehicle)
{
	char model[PLATFORM_MAX_PATH], vehiclescript[PLATFORM_MAX_PATH];
	GetEntPropString(vehicle, Prop_Data, "m_ModelName", model, sizeof(model));
	GetEntPropString(vehicle, Prop_Data, "m_vehicleScript", vehiclescript, sizeof(vehiclescript));
	
	VehicleConfig config;
	
	// If no script is set, try to find a matching config entry and set it ourselves
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

public void SDKHookCB_PropVehicleDriveable_SpawnPost(int vehicle)
{
	// m_pServerVehicle is initialized in Spawn so we hook it in SpawnPost
	DHookVehicle(GetServerVehicle(vehicle));
	
	VehicleConfig config;
	if (GetConfigByVehicleEnt(vehicle, config))
	{
		SetEntPropFloat(vehicle, Prop_Data, "m_flMinimumSpeedToEnterExit", config.lock_speed);
	}
}

//-----------------------------------------------------------------------------
// Menus
//-----------------------------------------------------------------------------

void DisplayMainVehicleMenu(int client)
{
	Menu menu = new Menu(MenuHandler_MainVehicleMenu, MenuAction_Select | MenuAction_DisplayItem | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_Main", client, PLUGIN_VERSION, PLUGIN_AUTHOR, PLUGIN_URL);
	
	if (CheckCommandAccess(client, "sm_vehicle_create", ADMFLAG_GENERIC))
		menu.AddItem("vehicle_create", "#Menu_Item_CreateVehicle");
	
	if (CheckCommandAccess(client, "sm_vehicle_removeaim", ADMFLAG_GENERIC))
		menu.AddItem("vehicle_removeaim", "#Menu_Item_RemoveAimTargetVehicle");
	
	if (CheckCommandAccess(client, "sm_vehicle_remove", ADMFLAG_GENERIC))
		menu.AddItem("vehicle_remove", "#Menu_Item_RemovePlayerVehicles");
	
	if (CheckCommandAccess(client, "sm_vehicle_removeall", ADMFLAG_BAN))
		menu.AddItem("vehicle_removeall", "#Menu_Item_RemoveAllVehicles");
	
	if (CheckCommandAccess(client, "sm_vehicle_reload", ADMFLAG_CONFIG))
		menu.AddItem("vehicle_reload", "#Menu_Item_ReloadVehicleConfig");
	
	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayVehicleCreateMenu(int client)
{
	Menu menu = new Menu(MenuHandler_CreateVehicle, MenuAction_Select | MenuAction_DisplayItem | MenuAction_Cancel | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_CreateVehicle", client);
	menu.ExitBackButton = true;
	
	for (int i = 0; i < g_AllVehicles.Length; i++)
	{
		VehicleConfig config;
		if (g_AllVehicles.GetArray(i, config, sizeof(config)) > 0)
			menu.AddItem(config.id, config.id);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

void DisplayRemoveVehicleTargetMenu(int client)
{
	Menu menu = new Menu(MenuHandler_RemovePlayerVehicles, MenuAction_Select | MenuAction_End);
	menu.SetTitle("%T", "#Menu_Title_RemovePlayerVehicles", client);
	menu.ExitBackButton = CheckCommandAccess(client, "sm_vehicle", ADMFLAG_GENERIC);
	
	AddTargetsToMenu2(menu, client, COMMAND_FILTER_CONNECTED);
	
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
				else if (StrEqual(info, "vehicle_removeaim"))
				{
					FakeClientCommand(param1, "sm_vehicle_removeaim");
					DisplayMainVehicleMenu(param1);
				}
				else if (StrEqual(info, "vehicle_remove"))
				{
					DisplayRemoveVehicleTargetMenu(param1);
				}
				else if (StrEqual(info, "vehicle_removeall"))
				{
					FakeClientCommand(param1, "sm_vehicle_removeall");
					DisplayMainVehicleMenu(param1);
				}
				else if (StrEqual(info, "vehicle_reload"))
				{
					FakeClientCommand(param1, "sm_vehicle_reload");
					DisplayMainVehicleMenu(param1);
				}
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)))
			{
				Format(display, sizeof(display), "%T", display, param1);
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

public int MenuHandler_CreateVehicle(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[32];
			if (menu.GetItem(param2, info, sizeof(info)))
			{
				FakeClientCommand(param1, "sm_vehicle_create %s", info);
				DisplayVehicleCreateMenu(param1);
			}
		}
		case MenuAction_DisplayItem:
		{
			char info[32], display[128];
			VehicleConfig config;
			if (menu.GetItem(param2, info, sizeof(info), _, display, sizeof(display)) && GetConfigById(info, config) && TranslationPhraseExists(config.name))
			{
				Format(display, sizeof(display), "%T", config.name, param1);
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

public int MenuHandler_RemovePlayerVehicles(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Cancel:
		{
			if (param2 == MenuCancel_ExitBack)
			{
				DisplayMainVehicleMenu(param1);
			}
		}
		case MenuAction_Select:
		{
			char info[32];
			int userid, target;
			
			menu.GetItem(param2, info, sizeof(info));
			userid = StringToInt(info);
			
			if ((target = GetClientOfUserId(userid)) == 0)
			{
				PrintToChat(param1, "[SM] %t", "Player no longer available");
			}
			else if (!CanUserTarget(param1, target))
			{
				PrintToChat(param1, "[SM] %t", "Unable to target");
			}
			else
			{
				FakeClientCommand(param1, "sm_vehicle_remove #%d", userid);
			}
			
			DisplayRemoveVehicleTargetMenu(param1);
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
	if (detour)
	{
		if (callbackPre != INVALID_FUNCTION)
			detour.Enable(Hook_Pre, callbackPre);
		
		if (callbackPost != INVALID_FUNCTION)
			detour.Enable(Hook_Post, callbackPost);
	}
	else
	{
		LogError("Failed to create detour setup handle: %s", name);
	}
}

DynamicHook CreateDynamicHook(GameData gamedata, const char[] name)
{
	DynamicHook hook = DynamicHook.FromConf(gamedata, name);
	if (!hook)
		LogError("Failed to create hook setup handle: %s", name);
	
	return hook;
}

void DHookGamerulesObject()
{
	if (g_DHookShouldCollide)
		g_DHookShouldCollide.HookGamerules(Hook_Post, DHookCallback_ShouldCollide);
}

void DHookClient(int client)
{
	if (g_DHookGetInVehicle)
		g_DHookGetInVehicle.HookEntity(Hook_Pre, client, DHookCallback_GetInVehiclePre);
	
	if (g_DHookLeaveVehicle)
		g_DHookLeaveVehicle.HookEntity(Hook_Pre, client, DHookCallback_LeaveVehiclePre);
}

void DHookVehicle(Address serverVehicle)
{
	if (g_DHookSetPassenger)
		g_DHookSetPassenger.HookRaw(Hook_Pre, serverVehicle, DHookCallback_SetPassengerPre);
	
	if (g_DHookIsPassengerVisible)
		g_DHookIsPassengerVisible.HookRaw(Hook_Post, serverVehicle, DHookCallback_IsPassengerVisiblePost);
	
	if (g_DHookHandlePassengerEntry)
		g_DHookHandlePassengerEntry.HookRaw(Hook_Pre, serverVehicle, DHookCallback_HandlePassengerEntryPre);
	
	if (g_DHookGetExitAnimToUse)
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
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_ShouldCollide(DHookReturn ret, DHookParam params)
{
	int collisionGroup0 = params.Get(1);
	int collisionGroup1 = params.Get(2);
	
	if (collisionGroup0 > collisionGroup1)
	{
		// Swap so that lowest is always first
		V_swap(collisionGroup0, collisionGroup1);
	}
	
	if (GetEngineVersion() == Engine_TF2)
	{
		// Prevent vehicles from entering respawn rooms
		if (collisionGroup1 == TFCOLLISION_GROUP_RESPAWNROOMS)
		{
			ret.Value = ret.Value || (collisionGroup0 == COLLISION_GROUP_VEHICLE);
			return MRES_Supercede;
		}
	}
	
	return MRES_Ignored;
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
		// Stop any horn sounds when the player leaves the vehicle
		VehicleConfig config;
		if (GetConfigByVehicleEnt(vehicle, config) && config.horn_sound[0] != '\0')
		{
			EmitSoundToAll(config.horn_sound, vehicle, SNDCHAN_STATIC, SNDLEVEL_AIRCRAFT, SND_STOP | SND_STOPLOOPING);
		}
		
		int client = GetEntPropEnt(vehicle, Prop_Data, "m_hPlayer");
		if (client != -1)
		{
			Player(client).IsUsingHorn = false;
			SetEntProp(client, Prop_Send, "m_bDrawViewmodel", true);
		}
	}
	
	return MRES_Ignored;
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
		
		if (CanEnterVehicle(client, vehicle))	// CPropVehicleDriveable::CanEnterVehicle
		{
			if (SDKCall_CanEnterVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER))	//CBasePlayer::CanEnterVehicle
			{
				SDKCall_GetInVehicle(client, serverVehicle, VEHICLE_ROLE_DRIVER);
				
				// Snap the driver's view where the vehicle is facing
				float origin[3], angles[3];
				if (SDKCall_GetAttachmentLocal(vehicle, LookupEntityAttachment(vehicle, "vehicle_driver_eyes"), origin, angles))
					TeleportEntity(client, .angles = angles);
				
				CreateTimer(1.5, Timer_PrintVehicleKeyHint, EntIndexToEntRef(vehicle));
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
	// Disable client prediction for less jittery movement
	if (!IsFakeClient(client))
		SendConVarValue(client, FindConVar("sv_client_predict"), "0");
	
	return MRES_Ignored;
}

public MRESReturn DHookCallback_LeaveVehiclePre(int client)
{
	// Re-enable client prediction
	if (!IsFakeClient(client))
		SendConVarValue(client, FindConVar("sv_client_predict"), "1");
	
	return MRES_Ignored;
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
	if (!call)
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
	if (!call)
		LogMessage("Failed to create SDK call: CBasePlayer::CanEnterVehicle");
	
	return call;
}

Handle PrepSDKCall_GetAttachmentLocal(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CBaseAnimating::GetAttachmentLocal");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef, _, VENCODE_FLAG_COPYBACK);
	PrepSDKCall_SetReturnInfo(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDK call: CBaseAnimating::GetAttachmentLocal");
	
	return call;
}

Handle PrepSDKCall_GetVehicleEnt(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::GetVehicleEnt");
	PrepSDKCall_SetReturnInfo(SDKType_CBaseEntity, SDKPass_Pointer);
	
	Handle call = EndPrepSDKCall();
	if (!call)
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
	if (!call)
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
	if (!call)
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
	if (!call)
		LogMessage("Failed to create SDK call: CBaseServerVehicle::HandleEntryExitFinish");
	
	return call;
}

Handle PrepSDKCall_StudioFrameAdvance(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseAnimating::StudioFrameAdvance");
	
	Handle call = EndPrepSDKCall();
	if (!call)
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
	if (!call)
		LogError("Failed to create SDK call: CBasePlayer::GetInVehicle");
	
	return call;
}

void SDKCall_VehicleSetupMove(Address serverVehicle, int client, Address ucmd, Address helper, Address move)
{
	if (g_SDKCallVehicleSetupMove)
		SDKCall(g_SDKCallVehicleSetupMove, serverVehicle, client, ucmd, helper, move);
}

bool SDKCall_CanEnterVehicle(int client, Address serverVehicle, PassengerRole role)
{
	if (g_SDKCallCanEnterVehicle)
		return SDKCall(g_SDKCallCanEnterVehicle, client, serverVehicle, role);
	
	return false;
}

bool SDKCall_GetAttachmentLocal(int entity, int attachment, float origin[3], float angles[3])
{
	if (g_SDKCallGetAttachmentLocal)
		return SDKCall(g_SDKCallGetAttachmentLocal, entity, attachment, origin, angles);
	
	return false;
}

int SDKCall_GetVehicleEnt(Address serverVehicle)
{
	if (g_SDKCallGetVehicleEnt)
		return SDKCall(g_SDKCallGetVehicleEnt, serverVehicle);
	
	return -1;
}

void SDKCall_HandlePassengerEntry(Address serverVehicle, int passenger, bool allowEntryOutsideZone)
{
	if (g_SDKCallHandlePassengerEntry)
		SDKCall(g_SDKCallHandlePassengerEntry, serverVehicle, passenger, allowEntryOutsideZone);
}

bool SDKCall_HandlePassengerExit(Address serverVehicle, int passenger)
{
	if (g_SDKCallHandlePassengerExit)
		return SDKCall(g_SDKCallHandlePassengerExit, serverVehicle, passenger);
	
	return false;
}

void SDKCall_HandleEntryExitFinish(Address serverVehicle, bool exitAnimOn, bool resetAnim)
{
	if (g_SDKCallHandleEntryExitFinish)
		SDKCall(g_SDKCallHandleEntryExitFinish, serverVehicle, exitAnimOn, resetAnim);
}

void SDKCall_StudioFrameAdvance(int entity)
{
	if (g_SDKCallStudioFrameAdvance)
		SDKCall(g_SDKCallStudioFrameAdvance, entity);
}

bool SDKCall_GetInVehicle(int client, Address serverVehicle, PassengerRole role)
{
	if (g_SDKCallGetInVehicle)
		return SDKCall(g_SDKCallGetInVehicle, client, serverVehicle, role);
	
	return false;
}
