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
}

enum struct EntityLagData
{
	int iEntity;
	int iRecordIndex;
	int iNumRecords;
	int iRecordsValid;
	int iDeleted;
	int iNotMoving;
	bool bRestore;
	LagRecord RestoreData;
}

LagRecord g_aaLagRecords[MAX_ENTITIES][MAX_RECORDS];
EntityLagData g_aEntityLagData[MAX_ENTITIES];
int g_iNumEntities = 0;

Handle g_hGetAbsOrigin;
Handle g_hSetAbsOrigin;
Handle g_hGetAbsAngles;
Handle g_hSetAbsAngles;

bool g_bBlockPhysics = false;
bool g_bNoPhysics[2048];
Handle g_hPhysicsTouchTriggers;
Handle g_hUTIL_Remove;
Handle g_hRestartRound;


public void OnPluginStart()
{
	Handle hGameData = LoadGameConfigFile("LagCompensation.games");
	if(!hGameData)
		SetFailState("Failed to load LagCompensation gamedata.");


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


	// CBaseEntity::GetAbsAngles
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "GetAbsAngles"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"GetAbsAngles\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
	g_hGetAbsAngles = EndPrepSDKCall();

	// CBaseEntity::SetAbsAngles
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetAbsAngles"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"SetAbsAngles\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
	g_hSetAbsAngles = EndPrepSDKCall();


	// CBaseEntity::PhysicsTouchTriggers
	g_hPhysicsTouchTriggers = DHookCreateFromConf(hGameData, "CBaseEntity__PhysicsTouchTriggers");
	if(!g_hPhysicsTouchTriggers)
	{
		delete hGameData;
		SetFailState("Failed to setup detour for CBaseEntity__PhysicsTouchTriggers");
	}

	if(!DHookEnableDetour(g_hPhysicsTouchTriggers, false, Detour_OnPhysicsTouchTriggers))
	{
		delete hGameData;
		SetFailState("Failed to detour CBaseEntity__PhysicsTouchTriggers.");
	}

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
	delete hGameData;

	if(!DHookEnableDetour(g_hRestartRound, false, Detour_OnRestartRound))
		SetFailState("Failed to detour CCSGameRules__RestartRound.");
}


public void OnPluginEnd()
{
	FilterSolidMoved(g_bNoPhysics, 0);

	DHookDisableDetour(g_hUTIL_Remove, false, Detour_OnUTIL_Remove);

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
			continue;

		if(g_aEntityLagData[i].iDeleted)
		{
			PrintToBoth("[%d] !!!!!!!!!!! RemoveEdict: %d / ent: %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity);
			// calls OnEntityDestroyed right away
			// which calls RemoveRecord
			// which moves the next element to our current position
			RemoveEdict(g_aEntityLagData[i].iEntity);
			i--; continue;
		}
	}
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public MRESReturn Detour_OnPhysicsTouchTriggers(int entity, Handle hReturn, Handle hParams)
{
	if(!g_bBlockPhysics)
		return MRES_Ignored;

	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return MRES_Ignored;

	if(g_bNoPhysics[entity])
	{
		//LogMessage("blocked physics on %d", entity);
		return MRES_Supercede;
	}
	return MRES_Ignored;
}

public MRESReturn Detour_OnUTIL_Remove(Handle hParams)
{
	int entity = DHookGetParam(hParams, 1);
	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return MRES_Ignored;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iEntity != entity)
			continue;

		SetEntPropEnt(entity, Prop_Data, "m_pParent", 0);

		if(!g_aEntityLagData[i].iDeleted)
			g_aEntityLagData[i].iDeleted = GetGameTickCount();

		PrintToBoth("[%d] !!!!!!!!!!! Detour_OnUTIL_Remove: %d / ent: %d", GetGameTickCount(), i, entity);
		return MRES_Supercede;
	}

	return MRES_Ignored;
}

public MRESReturn Detour_OnRestartRound()
{
	PrintToBoth("Detour_OnRestartRound with %d entries.", g_iNumEntities);
	for(int i = 0; i < g_iNumEntities; i++)
	{
		g_aEntityLagData[i].iEntity = -1;
	}

	g_iNumEntities = 0;

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
		if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
			continue;

		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			PrintToBoth("!!!!!!!!!!! OnRunThinkFunctions SHIT deleted: %d / %d", i, g_aEntityLagData[i].iEntity);
			RemoveRecord(i);
			i--; continue;
		}

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

	FilterSolidMoved(g_bNoPhysics, sizeof(g_bNoPhysics));
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
				continue;
		}

		int iRecordIndex = g_aEntityLagData[i].iRecordIndex - delta;
		if(iRecordIndex < 0)
			iRecordIndex += MAX_RECORDS;

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, client, g_aaLagRecords[i][iRecordIndex]);
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
	FilterSolidMoved(g_bNoPhysics, 0);

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(!g_aEntityLagData[i].bRestore)
			continue;

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, 0, g_aEntityLagData[i].RestoreData);
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

	g_bBlockPhysics = true;
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

	g_bBlockPhysics = false;
}

void RecordDataIntoRecord(int iEntity, LagRecord Record)
{
	SDKCall(g_hGetAbsOrigin, iEntity, Record.vecOrigin);
	SDKCall(g_hGetAbsAngles, iEntity, Record.vecAngles);
}

void RestoreEntityFromRecord(int iEntity, int iFilter, LagRecord Record)
{
	FilterTriggerMoved(iFilter);
	BlockSolidMoved(iFilter);

	SDKCall(g_hSetAbsAngles, iEntity, Record.vecAngles);
	SDKCall(g_hSetAbsOrigin, iEntity, Record.vecOrigin);

	BlockSolidMoved(-1);
	FilterTriggerMoved(-1);
}

bool AddEntityForLagCompensation(int iEntity)
{
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
	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return;

	if(!strncmp(classname, "func_physbox", 12))
	{
		AddEntityForLagCompensation(entity);
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
		if(iParent == -1)
			break;

		GetEntityClassname(iParent, sParentClassname, sizeof(sParentClassname));
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

	if(iParent == -1)
		return;

	if(!bGoodParents)
		return;

	if(!AddEntityForLagCompensation(entity))
		return;

	g_bNoPhysics[entity] = true;

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
	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return;

	g_bNoPhysics[entity] = false;

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
	{
		char sClassname[64];
		GetEntityClassname(g_aEntityLagData[index].iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(g_aEntityLagData[index].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(g_aEntityLagData[index].iEntity, Prop_Data, "m_iHammerID");

		PrintToBoth("[%d] RemoveRecord %d / %d (%s)\"%s\"(#%d), num: %d", GetGameTickCount(), index, g_aEntityLagData[index].iEntity, sClassname, sTargetname, iHammerID, g_iNumEntities);
	}

	g_aEntityLagData[index].iEntity = -1;

	for(int src = index + 1; src < g_iNumEntities; src++)
	{
		int dest = src - 1;

		EntityLagData_Copy(g_aEntityLagData[dest], g_aEntityLagData[src]);
		g_aEntityLagData[src].iEntity = -1;

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
	obj.bRestore = other.bRestore;
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