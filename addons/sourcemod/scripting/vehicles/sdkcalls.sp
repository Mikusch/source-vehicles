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

static Handle g_SDKCallStudioFrameAdvance;
static Handle g_SDKCallVehicleSetupMove;
static Handle g_SDKCallHandlePassengerExit;
static Handle g_SDKCallHandleEntryExitFinish;

public void SDKCalls_Initialize(GameData gamedata)
{
	g_SDKCallStudioFrameAdvance = PrepSDKCall_StudioFrameAdvance(gamedata);
	g_SDKCallVehicleSetupMove = PrepSDKCall_VehicleSetupMove(gamedata);
	g_SDKCallHandlePassengerExit = PrepSDKCall_HandlePassengerExit(gamedata);
	g_SDKCallHandleEntryExitFinish = PrepSDKCall_HandleEntryExitFinish(gamedata);
}

static Handle PrepSDKCall_StudioFrameAdvance(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseAnimating::StudioFrameAdvance");
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogError("Failed to create SDKCall: CBaseAnimating::StudioFrameAdvance");
	
	return call;
}

static Handle PrepSDKCall_VehicleSetupMove(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::SetupMove");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::SetupMove");
	
	return call;
}

static Handle PrepSDKCall_HandlePassengerExit(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandlePassengerExit");
	PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::HandlePassengerExit");
	
	return call;
}

static Handle PrepSDKCall_HandleEntryExitFinish(GameData gamedata)
{
	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CBaseServerVehicle::HandleEntryExitFinish");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_ByValue);
	
	Handle call = EndPrepSDKCall();
	if (!call)
		LogMessage("Failed to create SDKCall: CBaseServerVehicle::HandleEntryExitFinish");
	
	return call;
}

public void SDKCall_StudioFrameAdvance(int entity)
{
	SDKCall(g_SDKCallStudioFrameAdvance, entity);
}

public bool SDKCall_HandlePassengerExit(int vehicle, int client)
{
	Address serverVehicle = GetServerVehicle(vehicle);
	if (serverVehicle != Address_Null)
		return SDKCall(g_SDKCallHandlePassengerExit, serverVehicle, client);
	
	return false;
}

public void SDKCall_VehicleSetupMove(int vehicle, int client, Address ucmd, Address helper, Address move)
{
	Address serverVehicle = GetServerVehicle(vehicle);
	if (serverVehicle != Address_Null)
		SDKCall(g_SDKCallVehicleSetupMove, serverVehicle, client, ucmd, helper, move);
}

public void SDKCall_HandleEntryExitFinish(int vehicle, bool exitAnimOn, bool resetAnim)
{
	Address serverVehicle = GetServerVehicle(vehicle);
	if (serverVehicle != Address_Null)
		SDKCall(g_SDKCallHandleEntryExitFinish, serverVehicle, exitAnimOn, resetAnim);
}
