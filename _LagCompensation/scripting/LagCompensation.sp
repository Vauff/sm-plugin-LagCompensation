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
bool g_bBlockPhysics = false;
bool g_bNoPhysics[2048];

#define MAX_RECORDS 64
#define MAX_ENTITIES 16

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
	bool bRestore;
	LagRecord RestoreData;
}

LagRecord g_aaLagRecords[MAX_ENTITIES][MAX_RECORDS];
EntityLagData g_aEntityLagData[MAX_ENTITIES];
int g_iNumEntities = 0;

Handle g_hPhysicsTouchTriggers;
Handle g_hSetLocalOrigin;
Handle g_hSetLocalAngles;
Handle g_hSetCollisionBounds;

public void OnPluginStart()
{
	Handle hGameData = LoadGameConfigFile("LagCompensation.games");
	if(!hGameData)
		SetFailState("Failed to load LagCompensation gamedata.");

	// CBaseEntity::SetLocalOrigin
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetLocalOrigin"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"SetLocalOrigin\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	g_hSetLocalOrigin = EndPrepSDKCall();

	// CBaseEntity::SetLocalAngles
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetLocalAngles"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"SetLocalAngles\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_QAngle, SDKPass_ByRef);
	g_hSetLocalAngles = EndPrepSDKCall();

	// CBaseEntity::SetCollisionBounds
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "SetCollisionBounds"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"SetCollisionBounds\") failed!");
	}
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	PrepSDKCall_AddParameter(SDKType_Vector, SDKPass_ByRef);
	g_hSetCollisionBounds = EndPrepSDKCall();


	g_hPhysicsTouchTriggers = DHookCreateFromConf(hGameData, "CBaseEntity__PhysicsTouchTriggers");
	if(!g_hPhysicsTouchTriggers)
		SetFailState("Failed to setup detour for CBaseEntity__PhysicsTouchTriggers");
	delete hGameData;

	if(!DHookEnableDetour(g_hPhysicsTouchTriggers, false, Detour_OnPhysicsTouchTriggers))
		SetFailState("Failed to detour CBaseEntity__PhysicsTouchTriggers.");
}

public MRESReturn Detour_OnPhysicsTouchTriggers(int entity, Handle hReturn, Handle hParams)
{
	if(!g_bBlockPhysics)
		return MRES_Ignored;

	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return MRES_Ignored;

	if(g_bNoPhysics[entity])
	{
		//LogMessage("blocked physics on %d", g_iNoPhysics);
		return MRES_Supercede;
	}
	return MRES_Ignored;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
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
	for(int i = 0, j = g_iNumEntities; i < MAX_ENTITIES, j; i++, j--)
	{
		if(g_aEntityLagData[i].iEntity == 0)
			continue;

		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			LogMessage("!!!!!!!!!!! OnRunThinkFunctions SHIT deleted: %d", g_aEntityLagData[i].iEntity);
			g_aEntityLagData[i].iEntity = 0;
			g_iNumEntities--;
			continue;
		}

		RecordDataIntoRecord(g_aEntityLagData[i].iEntity, g_aEntityLagData[i].RestoreData);
	}
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	g_bBlockPhysics = true;
	if(!IsPlayerAlive(client))
		return Plugin_Continue;

	int delta = GetGameTickCount() - tickcount;
	if(delta < 0)
		delta = 0;

	for(int i = 0, j = g_iNumEntities; i < MAX_ENTITIES, j; i++, j--)
	{
		if(g_aEntityLagData[i].iEntity == 0 || g_aEntityLagData[i].iNumRecords == 0)
			continue;

		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			LogMessage("!!!!!!!!!!! OnPlayerRunCmd SHIT deleted: %d", g_aEntityLagData[i].iEntity);
			g_aEntityLagData[i].iEntity = 0;
			g_iNumEntities--;
			continue;
		}

		if(delta >= g_aEntityLagData[i].iNumRecords)
			delta = g_aEntityLagData[i].iNumRecords - 1;

		int iRecordIndex = g_aEntityLagData[i].iRecordIndex - delta;
		if(iRecordIndex < 0)
			iRecordIndex += MAX_RECORDS;

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, client, g_aaLagRecords[i][iRecordIndex]);
		g_aEntityLagData[i].bRestore = true;

#if defined DEBUG
		LogMessage("[%d] index %d, Entity %d -> delta = %d | Record = %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity, delta, iRecordIndex);
		LogMessage("%f %f %f",
			g_aaLagRecords[i][iRecordIndex].vecOrigin[0],
			g_aaLagRecords[i][iRecordIndex].vecOrigin[1],
			g_aaLagRecords[i][iRecordIndex].vecOrigin[2]
		);
#endif
	}

	return Plugin_Continue;
}

public void OnRunThinkFunctions2()
{
	for(int i = 0, j = g_iNumEntities; i < MAX_ENTITIES, j; i++, j--)
	{
		if(g_aEntityLagData[i].iEntity == 0 || !g_aEntityLagData[i].bRestore)
			continue;

		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			LogMessage("!!!!!!!!!!! OnRunThinkFunctions2 SHIT deleted: %d", g_aEntityLagData[i].iEntity);
			g_aEntityLagData[i].iEntity = 0;
			g_iNumEntities--;
			continue;
		}

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, 0, g_aEntityLagData[i].RestoreData);
		g_aEntityLagData[i].bRestore = false;

#if defined DEBUG
		LogMessage("[%d] index %d, restore entity %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity, g_aEntityLagData[i].iRecordIndex);
		LogMessage("%f %f %f",
			g_aEntityLagData[i].RestoreData.vecOrigin[0],
			g_aEntityLagData[i].RestoreData.vecOrigin[1],
			g_aEntityLagData[i].RestoreData.vecOrigin[2]
		);
#endif
	}
	g_bBlockPhysics = false;
}

public void OnRunThinkFunctionsPost(bool simulating)
{
	for(int i = 0, j = g_iNumEntities; i < MAX_ENTITIES, j; i++, j--)
	{
		if(g_aEntityLagData[i].iEntity == 0)
			continue;

		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			LogMessage("!!!!!!!!!!! OnRunThinkFunctionsPost SHIT deleted: %d", g_aEntityLagData[i].iEntity);
			g_aEntityLagData[i].iEntity = 0;
			g_iNumEntities--;
			continue;
		}

		g_aEntityLagData[i].iRecordIndex++;

		if(g_aEntityLagData[i].iRecordIndex >= MAX_RECORDS)
			g_aEntityLagData[i].iRecordIndex = 0;

		if(g_aEntityLagData[i].iNumRecords < MAX_RECORDS)
			g_aEntityLagData[i].iNumRecords++;

		RecordDataIntoRecord(g_aEntityLagData[i].iEntity, g_aaLagRecords[i][g_aEntityLagData[i].iRecordIndex]);

#if defined DEBUG
		LogMessage("[%d] index %d, record entity %d into %d", GetGameTickCount(), i, g_aEntityLagData[i].iEntity, g_aEntityLagData[i].iRecordIndex);
		LogMessage("%f %f %f",
			g_aaLagRecords[i][g_aEntityLagData[i].iRecordIndex].vecOrigin[0],
			g_aaLagRecords[i][g_aEntityLagData[i].iRecordIndex].vecOrigin[1],
			g_aaLagRecords[i][g_aEntityLagData[i].iRecordIndex].vecOrigin[2]
		);
#endif
	}
}

void RecordDataIntoRecord(int iEntity, LagRecord Record)
{
	GetEntPropVector(iEntity, Prop_Data, "m_vecAbsOrigin", Record.vecOrigin);
	GetEntPropVector(iEntity, Prop_Data, "m_angAbsRotation", Record.vecAngles);
	Record.flSimulationTime = GetEntPropFloat(iEntity, Prop_Data, "m_flSimulationTime");
}

void RestoreEntityFromRecord(int iEntity, int iFilter, LagRecord Record)
{
	FilterTriggerMoved(iFilter);
	SetEntPropFloat(iEntity, Prop_Data, "m_flSimulationTime", Record.flSimulationTime);
	TeleportEntity(iEntity, Record.vecOrigin, Record.vecAngles, NULL_VECTOR);
	FilterTriggerMoved(-1);
}

bool AddEntityForLagCompensation(int iEntity)
{
	for(int i = 0, j = g_iNumEntities; i < MAX_ENTITIES, j; i++, j--)
	{
		if(g_aEntityLagData[i].iEntity == iEntity)
			return true;
	}

	for(int i = 0; i < MAX_ENTITIES; i++)
	{
		if(g_aEntityLagData[i].iEntity != 0)
			continue;

		g_iNumEntities++;

		g_aEntityLagData[i].iEntity = iEntity;
		g_aEntityLagData[i].iRecordIndex = -1;
		g_aEntityLagData[i].iNumRecords = 0;

		LogMessage("[%d] added %d under index %d", GetGameTickCount(), iEntity, i);

		float vecOrigin[3];
		GetEntPropVector(iEntity, Prop_Data, "m_vecAbsOrigin", vecOrigin);
		LogMessage("%f %f %f",
			vecOrigin[0],
			vecOrigin[1],
			vecOrigin[2]
		);
		return true;
	}
	return false;
}

public void OnEntitySpawned(int entity, const char[] classname)
{
	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return;

	if(!StrEqual(classname, "trigger_hurt"))
		return;

	int iParent = GetEntPropEnt(entity, Prop_Data, "m_pParent");
	if(iParent == -1)
		return;

	char sParentClassname[64];
	GetEntityClassname(iParent, sParentClassname, sizeof(sParentClassname));


	char sTargetname[64];
	GetEntPropString(entity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

	char sParentTargetname[64];
	GetEntPropString(iParent, Prop_Data, "m_iName", sParentTargetname, sizeof(sParentTargetname));

	if(StrEqual(sParentTargetname, "Airship_Ending_Killwall"))
		return;


	bool result = false;
	if(StrEqual(sParentClassname, "func_movelinear") || StrEqual(sParentClassname, "func_door") || StrEqual(sParentClassname, "func_tracktrain"))
		result = AddEntityForLagCompensation(iParent);

	if(!result)
		return;

	g_bNoPhysics[entity] = true;

	LogMessage("added %s %s | parent: %s %s", classname, sTargetname, sParentClassname, sParentTargetname);
}

public void OnEntityDestroyed(int entity)
{
	if(entity < 0 || entity > sizeof(g_bNoPhysics))
		return;

	g_bNoPhysics[entity] = false;

	for(int i = 0, j = g_iNumEntities; i < MAX_ENTITIES, j; i++, j--)
	{
		if(g_aEntityLagData[i].iEntity == entity)
		{
			LogMessage("normal deleted: %d", entity);
			g_aEntityLagData[i].iEntity = 0;
			g_iNumEntities--;
			return;
		}
	}
}
