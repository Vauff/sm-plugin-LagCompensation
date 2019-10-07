#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <CSSFixes>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name 			= "LagCompensation",
	author 			= "BotoX",
	description 	= "",
	version 		= "0.0",
	url 			= ""
};

bool g_bLateLoad = false;

#define MAX_RECORDS 32
#define MAX_ENTITIES 64
//#define DEBUG

enum struct LagRecord
{
	float vecOrigin[3];
	float vecAngles[3];
	float flSimulationTime;
}

enum struct EntityLagData
{
	int iEntity;
	int iRecordIndex;
	int iNumRecords;
	int iRecordsValid;
	int iDeleted;
	int iNotMoving;
	int iTouchStamp;
	bool bRestore;
	bool bDoPhysics;
	LagRecord RestoreData;
}

LagRecord g_aaLagRecords[MAX_ENTITIES][MAX_RECORDS];
EntityLagData g_aEntityLagData[MAX_ENTITIES];
int g_iNumEntities = 0;
bool g_bCleaningUp = false;

Handle g_hPhysicsTouchTriggers;
Handle g_hGetAbsOrigin;
Handle g_hSetAbsOrigin;
Handle g_hSetLocalAngles;

Handle g_hUTIL_Remove;
Handle g_hRestartRound;

char g_aBlockPhysics[2048] = {0, ...};
char g_aaDeleted[MAXPLAYERS + 1][2048];

public void OnPluginStart()
{
	Handle hGameData = LoadGameConfigFile("LagCompensation.games");
	if(!hGameData)
		SetFailState("Failed to load LagCompensation gamedata.");

	// CBaseEntity::PhysicsTouchTriggers
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CBaseEntity::PhysicsTouchTriggers"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"CBaseEntity::PhysicsTouchTriggers\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	g_hPhysicsTouchTriggers = EndPrepSDKCall();

	// CBaseEntity::GetAbsOrigin
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "GetAbsOrigin"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"GetAbsOrigin\") failed!");
	}
	PrepSDKCall_SetReturnInfo(SDKType_Vector, SDKPass_ByRef);
	g_hGetAbsOrigin = EndPrepSDKCall();

	// CBaseEntity::SetAbsOrigin
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetAbsOrigin"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"SetAbsOrigin\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	g_hSetAbsOrigin = EndPrepSDKCall();

	// CBaseEntity::SetLocalAngles
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetLocalAngles"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"SetLocalAngles\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
	g_hSetLocalAngles = EndPrepSDKCall();


	// ::UTIL_Remove
	g_hUTIL_Remove = DHookCreateFromConf(hGameData, "UTIL_Remove");
	if(!g_hUTIL_Remove)
	{
		delete hGameData;
		SetFailState("Failed to setup detour for UTIL_Remove");
	}

	if(!DHookEnableDetour(g_hUTIL_Remove, false, Detour_OnUTIL_Remove))
	{
		delete hGameData;
		SetFailState("Failed to detour UTIL_Remove.");
	}

	// CCSGameRules::RestartRound
	g_hRestartRound = DHookCreateFromConf(hGameData, "CCSGameRules__RestartRound");
	if(!g_hRestartRound)
	{
		delete hGameData;
		SetFailState("Failed to setup detour for CCSGameRules__RestartRound");
	}

	if(!DHookEnableDetour(g_hRestartRound, false, Detour_OnRestartRound))
	{
		delete hGameData;
		SetFailState("Failed to detour CCSGameRules__RestartRound.");
	}
	delete hGameData;

	RegAdminCmd("sm_unlag", Command_AddLagCompensation, ADMFLAG_RCON, "sm_unlag <entidx> [trigger 0/1]");
	RegAdminCmd("sm_lagged", Command_CheckLagCompensated, ADMFLAG_GENERIC, "sm_lagged");

	FilterClientEntityMap(g_aaDeleted, true);
}

public Action Command_AddLagCompensation(int client, int argc)
{
	if(argc < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_unlag <entidx>");
		return Plugin_Handled;
	}

	char sArgs[32];
	GetCmdArg(1, sArgs, sizeof(sArgs));

	int entity = StringToInt(sArgs);
	int physics = 0;

	if(argc >= 2)
	{
		GetCmdArg(2, sArgs, sizeof(sArgs));
		physics = StringToInt(sArgs);
	}

	AddEntityForLagCompensation(entity, view_as<bool>(physics));
	g_aBlockPhysics[entity] = 1;

	return Plugin_Handled;
}

public Action Command_CheckLagCompensated(int client, int argc)
{
	for(int i = 0; i < g_iNumEntities; i++)
	{
		char sClassname[64];
		GetEntityClassname(g_aEntityLagData[i].iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(g_aEntityLagData[i].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "m_iHammerID");

		PrintToConsole(client, "%2d. #%d %s \"%s\" (#%d)", i, g_aEntityLagData[i].iEntity, sClassname, sTargetname, iHammerID);
	}

	for(int i = 0; i < 2048; i++)
	{
		bool bDeleted = false;
		for(int j = 1; j <= MaxClients; j++)
		{
			if(g_aaDeleted[j][i])
			{
				bDeleted = true;
				break;
			}
		}

		if(g_aBlockPhysics[i] || bDeleted)
		{
			int index = -1;
			for(int j = 0; j < g_iNumEntities; j++)
			{
				if(g_aEntityLagData[j].iEntity == i)
				{
					index = j;
					break;
				}
			}

			char sClassname[64] = "INVALID";
			char sTargetname[64] = "INVALID";
			int iHammerID = -1;

			if(IsValidEntity(i))
			{
				GetEntityClassname(i, sClassname, sizeof(sClassname));
				GetEntPropString(i, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));
				iHammerID = GetEntProp(i, Prop_Data, "m_iHammerID");
			}

			bool bBlockPhysics = g_aBlockPhysics[i];
			PrintToConsole(client, "%2d. #%d %s \"%s\" (#%d) -> BlockPhysics: %d / Deleted: %d", index, i, sClassname, sTargetname, iHammerID, bBlockPhysics, bDeleted);
		}
	}

	return Plugin_Handled;
}

public void OnPluginEnd()
{
	g_bCleaningUp = true;
	FilterClientEntityMap(g_aaDeleted, false);
	FilterTriggerTouchPlayers(g_aBlockPhysics, false);

	DHookDisableDetour(g_hUTIL_Remove, false, Detour_OnUTIL_Remove);

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
			continue;

		if(g_aEntityLagData[i].iDeleted)
		{
			RemoveEdict(g_aEntityLagData[i].iEntity);
		}
	}
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public MRESReturn Detour_OnUTIL_Remove(Handle hParams)
{
	if(g_bCleaningUp)
		return MRES_Ignored;

	int entity = DHookGetParam(hParams, 1);
	if(entity < 0 || entity > sizeof(g_aBlockPhysics))
		return MRES_Ignored;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iEntity != entity)
			continue;

		if(!g_aEntityLagData[i].iDeleted)
		{
			g_aEntityLagData[i].iDeleted = GetGameTickCount();
			PrintToBoth("[%d] !!!!!!!!!!! Detour_OnUTIL_Remove: %d / ent: %d", GetGameTickCount(), i, entity);
		}

		return MRES_Supercede;
	}

	return MRES_Ignored;
}

public MRESReturn Detour_OnRestartRound()
{
	g_bCleaningUp = true;
	PrintToBoth("Detour_OnRestartRound with %d entries.", g_iNumEntities);
	for(int i = 0; i < g_iNumEntities; i++)
	{
		g_aBlockPhysics[g_aEntityLagData[i].iEntity] = 0;

		if(g_aEntityLagData[i].iDeleted)
		{
			for(int client = 1; client <= MaxClients; client++)
			{
				g_aaDeleted[client][g_aEntityLagData[i].iEntity] = 0;
			}

			if(IsValidEntity(g_aEntityLagData[i].iEntity))
				RemoveEdict(g_aEntityLagData[i].iEntity);
		}

		g_aEntityLagData[i].iEntity = INVALID_ENT_REFERENCE;
	}

	g_iNumEntities = 0;

	g_bCleaningUp = false;
	return MRES_Ignored;
}

public void OnMapStart()
{
	bool bLate = g_bLateLoad;
	g_bLateLoad = false;

	/* Late Load */
	if(bLate)
	{
		for(int client = 1; client <= MaxClients; client++)
		{
			if(IsClientInGame(client))
				OnClientPutInServer(client);
		}

		int entity = INVALID_ENT_REFERENCE;
		while((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_REFERENCE)
		{
			char sClassname[64];
			if(GetEntityClassname(entity, sClassname, sizeof(sClassname)))
				OnEntitySpawned(entity, sClassname);
		}
	}
}

public void OnClientPutInServer(int client)
{
}

public void OnRunThinkFunctions(bool simulating)
{
	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			PrintToBoth("!!!!!!!!!!! OnRunThinkFunctions SHIT deleted: %d / %d", i, g_aEntityLagData[i].iEntity);
			RemoveRecord(i);
			i--; continue;
		}

		// Save old touchStamp
		int touchStamp = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "touchStamp");
		g_aEntityLagData[i].iTouchStamp = touchStamp;
		// We have to increase the touchStamp by 1 here to avoid breaking the touchlink.
		// The touchStamp is incremented by 1 every time an entities physics are simulated.
		// When two entities touch then a touchlink is created on both entities with the touchStamp of either entity.
		// Usually the player would touch the trigger first and then the trigger would touch the player later on in the same frame.
		// The trigger touching the player would fix up the touchStamp (which was increased by 1 by the trigger physics simulate)
		// But since we're blocking the trigger from ever touching a player outside of here we need to manually increase it by 1 up front
		// so the correct +1'd touchStamp is stored in the touchlink.
		// After simulating the players we restore the old touchStamp (-1) and when the entity is simulated it will increase it again by 1
		// Thus both touchlinks will have the correct touchStamp value.
		touchStamp++;
		SetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "touchStamp", touchStamp);

		if(g_aEntityLagData[i].iDeleted)
		{
			if(g_aEntityLagData[i].iDeleted + MAX_RECORDS < GetGameTickCount())
			{
				PrintToBoth("[%d] !!!!!!!!!!! RemoveEdict: %d / ent: %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity);
				// calls OnEntityDestroyed right away
				// which calls RemoveRecord
				// which moves the next element to our current position
				RemoveEdict(g_aEntityLagData[i].iEntity);
				i--; continue;
			}
			continue;
		}

		if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
			continue;

		RecordDataIntoRecord(g_aEntityLagData[i].iEntity, g_aEntityLagData[i].RestoreData);

#if defined DEBUG
		LogMessage("1 [%d] [%d] index %d, RECORD entity %d", GetGameTickCount(), i, simulating, g_aEntityLagData[i].iEntity, g_aEntityLagData[i].iRecordIndex);
		LogMessage("%f %f %f",
			g_aEntityLagData[i].RestoreData.vecOrigin[0],
			g_aEntityLagData[i].RestoreData.vecOrigin[1],
			g_aEntityLagData[i].RestoreData.vecOrigin[2]
		);
#endif
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if(!IsPlayerAlive(client))
		return Plugin_Continue;

	int delta = GetGameTickCount() - tickcount;
	if(delta < 0)
		delta = 0;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
			continue;

		if(delta >= g_aEntityLagData[i].iNumRecords)
			delta = g_aEntityLagData[i].iNumRecords - 1;

		if(g_aEntityLagData[i].iDeleted)
		{
			int simtick = GetGameTickCount() - delta;
			if(simtick > g_aEntityLagData[i].iDeleted)
			{
				g_aaDeleted[client][g_aEntityLagData[i].iEntity] = 1;
				continue;
			}
		}

		int iRecordIndex = g_aEntityLagData[i].iRecordIndex - delta;
		if(iRecordIndex < 0)
			iRecordIndex += MAX_RECORDS;

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, client, g_aEntityLagData[i].bDoPhysics, g_aaLagRecords[i][iRecordIndex]);
		g_aEntityLagData[i].bRestore = !g_aEntityLagData[i].iDeleted;

#if defined DEBUG
		LogMessage("2 [%d] index %d, Entity %d -> delta = %d | Record = %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity, delta, iRecordIndex);
		LogMessage("%f %f %f",
			g_aaLagRecords[i][iRecordIndex].vecOrigin[0],
			g_aaLagRecords[i][iRecordIndex].vecOrigin[1],
			g_aaLagRecords[i][iRecordIndex].vecOrigin[2]
		);
#endif
	}

	return Plugin_Continue;
}

public void OnPostPlayerThinkFunctions()
{
	for(int i = 0; i < g_iNumEntities; i++)
	{
		SetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "touchStamp", g_aEntityLagData[i].iTouchStamp);

		if(!g_aEntityLagData[i].bRestore)
			continue;

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, 0, false, g_aEntityLagData[i].RestoreData);
		g_aEntityLagData[i].bRestore = false;

#if defined DEBUG
		LogMessage("3 [%d] index %d, RESTORE entity %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity, g_aEntityLagData[i].iRecordIndex);
		LogMessage("%f %f %f",
			g_aEntityLagData[i].RestoreData.vecOrigin[0],
			g_aEntityLagData[i].RestoreData.vecOrigin[1],
			g_aEntityLagData[i].RestoreData.vecOrigin[2]
		);
#endif
	}

	FilterTriggerTouchPlayers(g_aBlockPhysics, true);
}

public void OnRunThinkFunctionsPost(bool simulating)
{
	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iDeleted)
		{
			if(g_aEntityLagData[i].iRecordsValid)
			{
				g_aEntityLagData[i].iRecordIndex++;

				if(g_aEntityLagData[i].iRecordIndex >= MAX_RECORDS)
					g_aEntityLagData[i].iRecordIndex = 0;

				g_aEntityLagData[i].iRecordsValid--;
			}

			continue;
		}

		LagRecord TmpRecord;
		RecordDataIntoRecord(g_aEntityLagData[i].iEntity, TmpRecord);

		// sleep detection
		{
			int iOldRecord = g_aEntityLagData[i].iRecordIndex;

			if(g_aaLagRecords[i][iOldRecord].vecOrigin[0] == TmpRecord.vecOrigin[0] &&
				g_aaLagRecords[i][iOldRecord].vecOrigin[1] == TmpRecord.vecOrigin[1] &&
				g_aaLagRecords[i][iOldRecord].vecOrigin[2] == TmpRecord.vecOrigin[2])
			{
				g_aEntityLagData[i].iNotMoving++;
				if(g_aEntityLagData[i].iNotMoving == MAX_RECORDS)
				{
					char sClassname[64];
					GetEntityClassname(g_aEntityLagData[i].iEntity, sClassname, sizeof(sClassname));

					char sTargetname[64];
					GetEntPropString(g_aEntityLagData[i].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

					int iHammerID = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "m_iHammerID");

					PrintToBoth("[%d] entity %d (%s)\"%s\"(#%d) index %d GOING TO SLEEP", GetGameTickCount(), g_aEntityLagData[i].iEntity, sClassname, sTargetname, iHammerID, i);
				}
			}
			else
			{
				if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
				{
					char sClassname[64];
					GetEntityClassname(g_aEntityLagData[i].iEntity, sClassname, sizeof(sClassname));

					char sTargetname[64];
					GetEntPropString(g_aEntityLagData[i].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

					int iHammerID = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "m_iHammerID");

					PrintToBoth("[%d] entity %d (%s)\"%s\"(#%d) index %d WAKING UP", GetGameTickCount(), g_aEntityLagData[i].iEntity, sClassname, sTargetname, iHammerID, i);
				}
				g_aEntityLagData[i].iNotMoving = 0;
			}

			if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
				continue;
		}

		g_aEntityLagData[i].iRecordIndex++;

		if(g_aEntityLagData[i].iRecordIndex >= MAX_RECORDS)
			g_aEntityLagData[i].iRecordIndex = 0;

		if(g_aEntityLagData[i].iNumRecords < MAX_RECORDS)
			g_aEntityLagData[i].iRecordsValid = ++g_aEntityLagData[i].iNumRecords;

		LagRecord_Copy(g_aaLagRecords[i][g_aEntityLagData[i].iRecordIndex], TmpRecord);

#if defined DEBUG
		LogMessage("4 [%d] index %d, RECORD entity %d into %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity, g_aEntityLagData[i].iRecordIndex);
		LogMessage("%f %f %f",
			TmpRecord.vecOrigin[0],
			TmpRecord.vecOrigin[1],
			TmpRecord.vecOrigin[2]
		);
#endif
	}

	FilterTriggerTouchPlayers(g_aBlockPhysics, false);
}

void RecordDataIntoRecord(int iEntity, LagRecord Record)
{
	SDKCall(g_hGetAbsOrigin, iEntity, Record.vecOrigin);
	GetEntPropVector(iEntity, Prop_Data, "m_angRotation", Record.vecAngles);
	Record.flSimulationTime = GetEntPropFloat(iEntity, Prop_Data, "m_flSimulationTime");
}

void RestoreEntityFromRecord(int iEntity, int iFilter, bool bDoPhysics, LagRecord Record)
{
	FilterTriggerMoved(iFilter);
	BlockSolidMoved(iEntity);

	SDKCall(g_hSetLocalAngles, iEntity, Record.vecAngles);
	SDKCall(g_hSetAbsOrigin, iEntity, Record.vecOrigin);
	SetEntPropFloat(iEntity, Prop_Data, "m_flSimulationTime", Record.flSimulationTime);
/*
	if(iFilter && bDoPhysics)
	{
		SDKCall(g_hPhysicsTouchTriggers, iEntity, Record.vecOrigin);
	}
*/
	BlockSolidMoved(-1);
	FilterTriggerMoved(-1);
}

bool AddEntityForLagCompensation(int iEntity, bool bDoPhysics)
{
	if(g_bCleaningUp)
		return false;

	if(g_iNumEntities == MAX_ENTITIES)
		return false;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iEntity == iEntity)
			return true;
	}

	int i = g_iNumEntities;
	g_iNumEntities++;

	g_aEntityLagData[i].iEntity = iEntity;
	g_aEntityLagData[i].iRecordIndex = 0;
	g_aEntityLagData[i].iNumRecords = 1;
	g_aEntityLagData[i].iRecordsValid = 1;
	g_aEntityLagData[i].iDeleted = 0;
	g_aEntityLagData[i].iNotMoving = MAX_RECORDS;
	g_aEntityLagData[i].bRestore = false;
	g_aEntityLagData[i].bDoPhysics = bDoPhysics;

	RecordDataIntoRecord(g_aEntityLagData[i].iEntity, g_aaLagRecords[i][0]);

	{
		char sClassname[64];
		GetEntityClassname(g_aEntityLagData[i].iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(g_aEntityLagData[i].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "m_iHammerID");

		PrintToBoth("[%d] added entity %d (%s)\"%s\"(#%d) under index %d", GetGameTickCount(), iEntity, sClassname, sTargetname, iHammerID, i);
	}

	return true;
}

public void OnEntitySpawned(int entity, const char[] classname)
{
	if(g_bCleaningUp)
		return;

	if(entity < 0 || entity > sizeof(g_aBlockPhysics))
		return;

	if(!IsValidEntity(entity))
		return;

	if(!strncmp(classname, "func_physbox", 12))
	{
		int iParent = GetEntPropEnt(entity, Prop_Data, "m_pParent");
		if(iParent != INVALID_ENT_REFERENCE)
		{
			AddEntityForLagCompensation(entity, false);
		}

		return;
	}

	if(!(StrEqual(classname, "trigger_hurt")))
		return;

	int iParent = entity;
	char sParentClassname[64];
	bool bGoodParents = false;
	for(;;)
	{
		iParent = GetEntPropEnt(iParent, Prop_Data, "m_pParent");
		if(iParent == INVALID_ENT_REFERENCE)
			break;

		GetEntityClassname(iParent, sParentClassname, sizeof(sParentClassname));

		if(!strncmp(sParentClassname, "prop_physics", 12))
		{
			bGoodParents = true;
			break;
		}

		if(strncmp(sParentClassname, "func_", 5))
			continue;

		if(StrEqual(sParentClassname[5], "movelinear") ||
			StrEqual(sParentClassname[5], "door") ||
			StrEqual(sParentClassname[5], "tracktrain") ||
			!strncmp(sParentClassname[5], "physbox", 7))
		{
			bGoodParents = true;
			break;
		}
	}

	if(iParent == INVALID_ENT_REFERENCE)
		return;
/*
	{
		char sTargetname[64];
		GetEntPropString(entity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		char sParentTargetname[64];
		GetEntPropString(iParent, Prop_Data, "m_iName", sParentTargetname, sizeof(sParentTargetname));

		PrintToBoth("CHECKING %s %s | parent: %s %s", classname, sTargetname, sParentClassname, sParentTargetname);
	}
*/
	if(!bGoodParents)
		return;

	if(!AddEntityForLagCompensation(entity, true))
		return;

	g_aBlockPhysics[entity] = 1;

	{
		char sTargetname[64];
		GetEntPropString(entity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		char sParentTargetname[64];
		GetEntPropString(iParent, Prop_Data, "m_iName", sParentTargetname, sizeof(sParentTargetname));

		PrintToBoth("added %s %s | parent: %s %s", classname, sTargetname, sParentClassname, sParentTargetname);
	}
}

public void OnEntityDestroyed(int entity)
{
	if(g_bCleaningUp)
		return;

	if(entity < 0 || entity > sizeof(g_aBlockPhysics))
		return;

	if(!IsValidEntity(entity))
		return;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iEntity != entity)
			continue;

		RemoveRecord(i);
		return;
	}
}

void RemoveRecord(int index)
{
	if(g_bCleaningUp)
		return;

	{
		char sClassname[64];
		GetEntityClassname(g_aEntityLagData[index].iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(g_aEntityLagData[index].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(g_aEntityLagData[index].iEntity, Prop_Data, "m_iHammerID");

		PrintToBoth("[%d] RemoveRecord %d / %d (%s)\"%s\"(#%d), num: %d", GetGameTickCount(), index, g_aEntityLagData[index].iEntity, sClassname, sTargetname, iHammerID, g_iNumEntities);
	}

	g_aBlockPhysics[g_aEntityLagData[index].iEntity] = 0;

	if(g_aEntityLagData[index].iDeleted)
	{
		for(int client = 1; client <= MaxClients; client++)
		{
			g_aaDeleted[client][g_aEntityLagData[index].iEntity] = 0;
		}
	}

	g_aEntityLagData[index].iEntity = INVALID_ENT_REFERENCE;

	for(int src = index + 1; src < g_iNumEntities; src++)
	{
		int dest = src - 1;

		EntityLagData_Copy(g_aEntityLagData[dest], g_aEntityLagData[src]);
		g_aEntityLagData[src].iEntity = INVALID_ENT_REFERENCE;

		int iNumRecords = g_aEntityLagData[dest].iNumRecords;
		for(int i = 0; i < iNumRecords; i++)
		{
			LagRecord_Copy(g_aaLagRecords[dest][i], g_aaLagRecords[src][i]);
		}
	}

	g_iNumEntities--;
}

void EntityLagData_Copy(EntityLagData obj, const EntityLagData other)
{
	obj.iEntity = other.iEntity;
	obj.iRecordIndex = other.iRecordIndex;
	obj.iNumRecords = other.iNumRecords;
	obj.iRecordsValid = other.iRecordsValid;
	obj.iDeleted = other.iDeleted;
	obj.iNotMoving = other.iNotMoving;
	obj.iTouchStamp = other.iTouchStamp;
	obj.bRestore = other.bRestore;
	obj.bDoPhysics = other.bDoPhysics;
	LagRecord_Copy(obj.RestoreData, other.RestoreData);
}

void LagRecord_Copy(LagRecord obj, const LagRecord other)
{
	obj.vecOrigin[0] = other.vecOrigin[0];
	obj.vecOrigin[1] = other.vecOrigin[1];
	obj.vecOrigin[2] = other.vecOrigin[2];
	obj.vecAngles[0] = other.vecAngles[0];
	obj.vecAngles[1] = other.vecAngles[1];
	obj.vecAngles[2] = other.vecAngles[2];
	obj.flSimulationTime = other.flSimulationTime;
}


stock void PrintToBoth(const char[] format, any ...)
{
	char buffer[254];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogMessage(buffer);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			PrintToConsole(i, "%s", buffer);
		}
	}
}