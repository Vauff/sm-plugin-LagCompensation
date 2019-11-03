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
	version 		= "0.1",
	url 			= ""
};

bool g_bLateLoad = false;

// Don't change this.
#define MAX_EDICTS 2048

#define MAX_RECORDS 32
#define MAX_ENTITIES 128
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
	int iSpawned;
	int iDeleted;
	int iNotMoving;
	int iTouchStamp;
	bool bRestore;
	bool bLateKill;
	LagRecord RestoreData;
}

LagRecord g_aaLagRecords[MAX_ENTITIES][MAX_RECORDS];
EntityLagData g_aEntityLagData[MAX_ENTITIES];
int g_iNumEntities = 0;
bool g_bCleaningUp = false;

Handle g_hGetAbsOrigin;
Handle g_hSetAbsOrigin;
Handle g_hSetLocalAngles;

Handle g_hUTIL_Remove;
Handle g_hRestartRound;
Handle g_hSetTarget;
Handle g_hSetTargetPost;

char g_aBlockTriggerTouch[MAX_EDICTS] = {0, ...};
char g_aaBlockTouch[MAXPLAYERS + 1][MAX_EDICTS];

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

	// CLogicMeasureMovement::SetTarget
	g_hSetTarget = DHookCreateFromConf(hGameData, "CLogicMeasureMovement__SetTarget");
	if(!g_hSetTarget)
	{
		delete hGameData;
		SetFailState("Failed to setup detour for CLogicMeasureMovement__SetTarget");
	}

	if(!DHookEnableDetour(g_hSetTarget, false, Detour_OnSetTargetPre))
	{
		delete hGameData;
		SetFailState("Failed to detour CLogicMeasureMovement__SetTarget.");
	}

	// CLogicMeasureMovement::SetTarget (fix post hook crashing due to this pointer being overwritten)
	g_hSetTargetPost = DHookCreateFromConf(hGameData, "CLogicMeasureMovement__SetTarget_post");
	if(!g_hSetTargetPost)
	{
		delete hGameData;
		SetFailState("Failed to setup detour for CLogicMeasureMovement__SetTarget_post");
	}

	if(!DHookEnableDetour(g_hSetTargetPost, true, Detour_OnSetTargetPost))
	{
		delete hGameData;
		SetFailState("Failed to detour CLogicMeasureMovement__SetTarget_post.");
	}

	delete hGameData;

	RegAdminCmd("sm_unlag", Command_AddLagCompensation, ADMFLAG_RCON, "sm_unlag <entidx>");
	RegAdminCmd("sm_lagged", Command_CheckLagCompensated, ADMFLAG_GENERIC, "sm_lagged");

	FilterClientEntityMap(g_aaBlockTouch, true);
}

public Action Command_AddLagCompensation(int client, int argc)
{
	if(argc < 1)
	{
		ReplyToCommand(client, "[SM] Usage: sm_unlag <entidx> [late]");
		return Plugin_Handled;
	}

	char sArgs[32];
	GetCmdArg(1, sArgs, sizeof(sArgs));

	int entity = StringToInt(sArgs);

	bool late = false;
	if(argc >= 2)
	{
		GetCmdArg(2, sArgs, sizeof(sArgs));
		late = view_as<bool>(StringToInt(sArgs));
	}

	AddEntityForLagCompensation(entity, late);
	g_aBlockTriggerTouch[entity] = 1;

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

	for(int i = 0; i < MAX_EDICTS; i++)
	{
		bool bDeleted = false;
		for(int j = 1; j <= MaxClients; j++)
		{
			if(g_aaBlockTouch[j][i])
			{
				bDeleted = true;
				break;
			}
		}

		if(g_aBlockTriggerTouch[i] || bDeleted)
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

			bool bBlockPhysics = g_aBlockTriggerTouch[i];
			PrintToConsole(client, "%2d. #%d %s \"%s\" (#%d) -> BlockPhysics: %d / Deleted: %d", index, i, sClassname, sTargetname, iHammerID, bBlockPhysics, bDeleted);
		}
	}

	return Plugin_Handled;
}

public void OnPluginEnd()
{
	g_bCleaningUp = true;
	FilterClientEntityMap(g_aaBlockTouch, false);
	FilterTriggerTouchPlayers(g_aBlockTriggerTouch, false);

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
	if(entity < 0 || entity > MAX_EDICTS)
		return MRES_Ignored;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(g_aEntityLagData[i].iEntity != entity)
			continue;

		// let it die
		if(!g_aEntityLagData[i].bLateKill)
			break;

		// ignore sleeping entities
		if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
			break;

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
		g_aBlockTriggerTouch[g_aEntityLagData[i].iEntity] = 0;

		for(int client = 1; client <= MaxClients; client++)
		{
			g_aaBlockTouch[client][g_aEntityLagData[i].iEntity] = 0;
		}

		if(g_aEntityLagData[i].iDeleted)
		{
			if(IsValidEntity(g_aEntityLagData[i].iEntity))
				RemoveEdict(g_aEntityLagData[i].iEntity);
		}

		g_aEntityLagData[i].iEntity = INVALID_ENT_REFERENCE;
	}

	g_iNumEntities = 0;

	g_bCleaningUp = false;
	return MRES_Ignored;
}

// https://developer.valvesoftware.com/wiki/Logic_measure_movement
int g_OnSetTarget_pThis;
public MRESReturn Detour_OnSetTargetPre(int pThis, Handle hParams)
{
	g_OnSetTarget_pThis = pThis;
	return MRES_Ignored;
}
public MRESReturn Detour_OnSetTargetPost(Handle hParams)
{
	int entity = GetEntPropEnt(g_OnSetTarget_pThis, Prop_Data, "m_hTarget");
	if(!IsValidEntity(entity))
		return MRES_Ignored;

	char sClassname[64];
	if(!GetEntityClassname(entity, sClassname, sizeof(sClassname)))
		return MRES_Ignored;

	if(!StrEqual(sClassname, "trigger_hurt", false))
		return MRES_Ignored;

	if(AddEntityForLagCompensation(entity, true))
	{
		// Filter the trigger from being touched outside of the lag compensation
		g_aBlockTriggerTouch[entity] = 1;
	}

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
		// The touchStamp doesn't increase when the entity is idle, however it also doesn't check untouch so we're fine.
		touchStamp++;
		SetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "touchStamp", touchStamp);

		if(g_aEntityLagData[i].iDeleted)
		{
			if(g_aEntityLagData[i].iDeleted + MAX_RECORDS <= GetGameTickCount())
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

	int iGameTick = GetGameTickCount();

	int iDelta = iGameTick - tickcount;
	if(iDelta < 0)
		iDelta = 0;

	if(iDelta > MAX_RECORDS)
		iDelta = MAX_RECORDS;

	int iPlayerSimTick = iGameTick - iDelta;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		int iEntity = g_aEntityLagData[i].iEntity;

		// Entity too new, the client couldn't even see it yet.
		if(g_aEntityLagData[i].iSpawned > iPlayerSimTick)
		{
			g_aaBlockTouch[client][iEntity] = 1;
			continue;
		}
		else if(g_aEntityLagData[i].iSpawned == iPlayerSimTick)
		{
			g_aaBlockTouch[client][iEntity] = 0;
		}

		if(g_aEntityLagData[i].iDeleted)
		{
			if(g_aEntityLagData[i].iDeleted <= iPlayerSimTick)
			{
				g_aaBlockTouch[client][iEntity] = 1;
				continue;
			}
		}

		if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
			continue;

		if(iDelta >= g_aEntityLagData[i].iNumRecords)
			iDelta = g_aEntityLagData[i].iNumRecords - 1;

		// +1 because the newest record in the list is one tick old
		// this is because we simulate players first
		// hence no new entity record was inserted on the current tick
		int iRecordIndex = g_aEntityLagData[i].iRecordIndex - iDelta + 1;
		if(iRecordIndex < 0)
			iRecordIndex += MAX_RECORDS;

		RestoreEntityFromRecord(iEntity, g_aaLagRecords[i][iRecordIndex]);
		g_aEntityLagData[i].bRestore = !g_aEntityLagData[i].iDeleted;

#if defined DEBUG
		LogMessage("2 [%d] index %d, Entity %d -> iDelta = %d | Record = %d", iGameTick, i, iEntity, iDelta, iRecordIndex);
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

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, g_aEntityLagData[i].RestoreData);
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

	FilterTriggerTouchPlayers(g_aBlockTriggerTouch, true);
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

#if defined DEBUG
				if(g_aEntityLagData[i].iNotMoving == MAX_RECORDS)
				{
					char sClassname[64];
					GetEntityClassname(g_aEntityLagData[i].iEntity, sClassname, sizeof(sClassname));

					char sTargetname[64];
					GetEntPropString(g_aEntityLagData[i].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

					int iHammerID = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "m_iHammerID");

					PrintToBoth("[%d] entity %d (%s)\"%s\"(#%d) index %d GOING TO SLEEP", GetGameTickCount(), g_aEntityLagData[i].iEntity, sClassname, sTargetname, iHammerID, i);
				}
#endif
			}
			else
			{
#if defined DEBUG
				if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
				{
					char sClassname[64];
					GetEntityClassname(g_aEntityLagData[i].iEntity, sClassname, sizeof(sClassname));

					char sTargetname[64];
					GetEntPropString(g_aEntityLagData[i].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

					int iHammerID = GetEntProp(g_aEntityLagData[i].iEntity, Prop_Data, "m_iHammerID");

					PrintToBoth("[%d] entity %d (%s)\"%s\"(#%d) index %d WAKING UP", GetGameTickCount(), g_aEntityLagData[i].iEntity, sClassname, sTargetname, iHammerID, i);
				}
#endif

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

	FilterTriggerTouchPlayers(g_aBlockTriggerTouch, false);
}

void RecordDataIntoRecord(int iEntity, LagRecord Record)
{
	SDKCall(g_hGetAbsOrigin, iEntity, Record.vecOrigin);
	GetEntPropVector(iEntity, Prop_Data, "m_angRotation", Record.vecAngles);
	Record.flSimulationTime = GetEntPropFloat(iEntity, Prop_Data, "m_flSimulationTime");
}

void RestoreEntityFromRecord(int iEntity, LagRecord Record)
{
	SDKCall(g_hSetLocalAngles, iEntity, Record.vecAngles);
	SDKCall(g_hSetAbsOrigin, iEntity, Record.vecOrigin);
	SetEntPropFloat(iEntity, Prop_Data, "m_flSimulationTime", Record.flSimulationTime);
}

bool AddEntityForLagCompensation(int iEntity, bool bLateKill)
{
	if(g_bCleaningUp)
		return false;

	if(g_iNumEntities == MAX_ENTITIES)
	{
		char sClassname[64];
		GetEntityClassname(iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(iEntity, Prop_Data, "m_iHammerID");

		PrintToBoth("[%d] OUT OF LAGCOMP SLOTS entity %d (%s)\"%s\"(#%d)", GetGameTickCount(), iEntity, sClassname, sTargetname, iHammerID);
		return false;
	}

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
	g_aEntityLagData[i].iSpawned = GetGameTickCount();
	g_aEntityLagData[i].iDeleted = 0;
	g_aEntityLagData[i].iNotMoving = MAX_RECORDS;
	g_aEntityLagData[i].bRestore = false;
	g_aEntityLagData[i].bLateKill = bLateKill;

	RecordDataIntoRecord(iEntity, g_aaLagRecords[i][0]);

	{
		char sClassname[64];
		GetEntityClassname(iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(iEntity, Prop_Data, "m_iHammerID");

		PrintToBoth("[%d] added entity %d (%s)\"%s\"(#%d) under index %d", GetGameTickCount(), iEntity, sClassname, sTargetname, iHammerID, i);
	}

	return true;
}

public void OnEntitySpawned(int entity, const char[] classname)
{
	if(g_bCleaningUp)
		return;

	if(entity < 0 || entity > MAX_EDICTS)
		return;

	if(!IsValidEntity(entity))
		return;

	bool bTriggerHurt = StrEqual(classname, "trigger_hurt");
	bool bPhysBox = !strncmp(classname, "func_physbox", 12);

	if(!bTriggerHurt && !bPhysBox)
		return;

	// Don't lag compensate anything that could be parented to a player
	// The player simulation would usually move the entity,
	// but we would overwrite that position change by restoring the entity to its previous state.
	int iParent = INVALID_ENT_REFERENCE;
	char sParentClassname[64];
	for(int iTmp = entity;;)
	{
		iTmp = GetEntPropEnt(iTmp, Prop_Data, "m_pParent");
		if(iTmp == INVALID_ENT_REFERENCE)
			break;

		iParent = iTmp;
		GetEntityClassname(iParent, sParentClassname, sizeof(sParentClassname));

		if(StrEqual(sParentClassname, "player") ||
			!strncmp(sParentClassname, "weapon_", 7))
		{
			return;
		}
	}

	// Lag compensate all physboxes
	if(bPhysBox)
	{
		AddEntityForLagCompensation(entity, false);
		return;
	}

	// Lag compensate all (non player-) parented hurt triggers
	if(bTriggerHurt && iParent > MaxClients && iParent < MAX_EDICTS)
	{
		if(AddEntityForLagCompensation(entity, true))
		{
			// Filter the trigger from being touched outside of the lag compensation
			g_aBlockTriggerTouch[entity] = 1;
		}
	}
}

public void OnEntityDestroyed(int entity)
{
	if(g_bCleaningUp)
		return;

	if(entity < 0 || entity > MAX_EDICTS)
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

	g_aBlockTriggerTouch[g_aEntityLagData[index].iEntity] = 0;

	for(int client = 1; client <= MaxClients; client++)
	{
		g_aaBlockTouch[client][g_aEntityLagData[index].iEntity] = 0;
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
	obj.iSpawned = other.iSpawned;
	obj.iDeleted = other.iDeleted;
	obj.iNotMoving = other.iNotMoving;
	obj.iTouchStamp = other.iTouchStamp;
	obj.bRestore = other.bRestore;
	obj.bLateKill = other.bLateKill;
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