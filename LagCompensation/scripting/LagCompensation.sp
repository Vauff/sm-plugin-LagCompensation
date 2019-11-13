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
	version 		= "0.2",
	url 			= ""
};

bool g_bLateLoad = false;

// Don't change this.
#define MAX_EDICTS 2048
#define FSOLID_FORCE_WORLD_ALIGNED 0x0040
#define FSOLID_ROOT_PARENT_ALIGNED 0x0100
#define EFL_DIRTY_ABSTRANSFORM (1<<11)
#define EFL_DIRTY_SURROUNDING_COLLISION_BOUNDS (1<<14)
#define EFL_CHECK_UNTOUCH (1<<24)
#define COORDINATE_FRAME_SIZE 14

enum
{
	USE_OBB_COLLISION_BOUNDS = 0,
	USE_BEST_COLLISION_BOUNDS,
	USE_HITBOXES,
	USE_SPECIFIED_BOUNDS,
	USE_GAME_CODE,
	USE_ROTATION_EXPANDED_BOUNDS,
	USE_COLLISION_BOUNDS_NEVER_VPHYSICS,
}

enum
{
	SOLID_NONE			= 0,	// no solid model
	SOLID_BSP			= 1,	// a BSP tree
	SOLID_BBOX			= 2,	// an AABB
	SOLID_OBB			= 3,	// an OBB (not implemented yet)
	SOLID_OBB_YAW		= 4,	// an OBB, constrained so that it can only yaw
	SOLID_CUSTOM		= 5,	// Always call into the entity for tests
	SOLID_VPHYSICS		= 6,	// solid vphysics object, get vcollide from the model and collide with that
	SOLID_LAST,
};

#define MAX_RECORDS 32
#define MAX_ENTITIES 256
//#define DEBUG

enum struct LagRecord
{
	float vecOrigin[3];
	float vecAbsOrigin[3];
	float angRotation[3];
	float angAbsRotation[3];
	float flSimulationTime;
	float rgflCoordinateFrame[COORDINATE_FRAME_SIZE];
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
bool g_bCleaningUp = true;

Handle g_hCalcAbsolutePosition;
Handle g_hMarkPartitionHandleDirty;

Handle g_hUTIL_Remove;
Handle g_hRestartRound;
Handle g_hSetTarget;
Handle g_hSetTargetPost;
Handle g_hFrameUpdatePostEntityThink;

int g_iTouchStamp;
int g_iCollision;
int g_iSolidFlags;
int g_iSolidType;
int g_iSurroundType;
int g_iEFlags;
int g_iVecOrigin;
int g_iVecAbsOrigin;
int g_iAngRotation;
int g_iAngAbsRotation;
int g_iSimulationTime;
int g_iCoordinateFrame;

char g_aBlockTriggerTouch[MAX_EDICTS] = {0, ...};
char g_aaBlockTouch[MAXPLAYERS + 1][MAX_EDICTS];

public void OnPluginStart()
{
	Handle hGameData = LoadGameConfigFile("LagCompensation.games");
	if(!hGameData)
		SetFailState("Failed to load LagCompensation gamedata.");

	// CBaseEntity::CalcAbsolutePosition
	StartPrepSDKCall(SDKCall_Entity);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CalcAbsolutePosition"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"CalcAbsolutePosition\") failed!");
	}
	g_hCalcAbsolutePosition = EndPrepSDKCall();

	// CCollisionProperty::MarkPartitionHandleDirty
	StartPrepSDKCall(SDKCall_Raw);
	if(!PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "MarkPartitionHandleDirty"))
	{
		delete hGameData;
		SetFailState("PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, \"MarkPartitionHandleDirty\") failed!");
	}
	g_hMarkPartitionHandleDirty = EndPrepSDKCall();


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

	// CEntityTouchManager::FrameUpdatePostEntityThink
	g_hFrameUpdatePostEntityThink = DHookCreateFromConf(hGameData, "CEntityTouchManager__FrameUpdatePostEntityThink");
	if(!g_hFrameUpdatePostEntityThink)
	{
		delete hGameData;
		SetFailState("Failed to setup detour for CEntityTouchManager__FrameUpdatePostEntityThink");
	}

	if(!DHookEnableDetour(g_hFrameUpdatePostEntityThink, false, Detour_OnFrameUpdatePostEntityThink))
	{
		delete hGameData;
		SetFailState("Failed to detour CEntityTouchManager__FrameUpdatePostEntityThink.");
	}

	delete hGameData;

	RegAdminCmd("sm_unlag", Command_AddLagCompensation, ADMFLAG_RCON, "sm_unlag <entidx>");
	RegAdminCmd("sm_lagged", Command_CheckLagCompensated, ADMFLAG_GENERIC, "sm_lagged");

	FilterClientEntityMap(g_aaBlockTouch, true);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
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

public void OnMapStart()
{
	bool bLate = g_bLateLoad;
	g_bLateLoad = false;

	g_bCleaningUp = false;

	g_iTouchStamp = FindDataMapInfo(0, "touchStamp");
	g_iCollision = FindDataMapInfo(0, "m_Collision");
	g_iSolidFlags = FindDataMapInfo(0, "m_usSolidFlags");
	g_iSolidType = FindDataMapInfo(0, "m_nSolidType");
	g_iSurroundType = FindDataMapInfo(0, "m_nSurroundType");
	g_iEFlags = FindDataMapInfo(0, "m_iEFlags");

	g_iVecOrigin = FindDataMapInfo(0, "m_vecOrigin");
	g_iVecAbsOrigin = FindDataMapInfo(0, "m_vecAbsOrigin");
	g_iAngRotation = FindDataMapInfo(0, "m_angRotation");
	g_iAngAbsRotation = FindDataMapInfo(0, "m_angAbsRotation");
	g_iSimulationTime = FindDataMapInfo(0, "m_flSimulationTime");
	g_iCoordinateFrame = FindDataMapInfo(0, "m_rgflCoordinateFrame");

	/* Late Load */
	if(bLate)
	{
		int entity = INVALID_ENT_REFERENCE;
		while((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_REFERENCE)
		{
			char sClassname[64];
			if(GetEntityClassname(entity, sClassname, sizeof(sClassname)))
				OnEntitySpawned(entity, sClassname);
		}
	}
}

public void OnEntitySpawned(int entity, const char[] classname)
{
	if(g_bCleaningUp)
		return;

	if(entity < 0 || entity > MAX_EDICTS)
		return;

	if(!IsValidEntity(entity))
		return;

	bool bTrigger = StrEqual(classname, "trigger_hurt", false) ||
					StrEqual(classname, "trigger_push", false) ||
					StrEqual(classname, "trigger_teleport", false) ||
					StrEqual(classname, "trigger_multiple", false);

	bool bMoving = !strncmp(classname, "func_physbox", 12, false);

	if(!bTrigger && !bMoving)
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

	// Lag compensate all moving stuff
	if(bMoving)
	{
		AddEntityForLagCompensation(entity, false);
		return;
	}

	// Lag compensate all (non player-) parented hurt triggers
	if(bTrigger && iParent > MaxClients && iParent < MAX_EDICTS)
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
		}

		return MRES_Supercede;
	}

	return MRES_Ignored;
}

public MRESReturn Detour_OnRestartRound()
{
	g_bCleaningUp = true;

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

	if(!(StrEqual(sClassname, "trigger_hurt", false) ||
		StrEqual(sClassname, "trigger_push", false) ||
		StrEqual(sClassname, "trigger_teleport", false)))
	{
		return MRES_Ignored;
	}

	if(AddEntityForLagCompensation(entity, true))
	{
		// Filter the trigger from being touched outside of the lag compensation
		g_aBlockTriggerTouch[entity] = 1;
	}

	return MRES_Ignored;
}

public MRESReturn Detour_OnFrameUpdatePostEntityThink()
{
	for(int i = 0; i < g_iNumEntities; i++)
	{
		// Don't make the entity check untouch in FrameUpdatePostEntityThink.
		// If the player didn't get simulated in the current frame then
		// they didn't have a chance to touch this entity.
		// Hence the touchlink could be broken and we only let the player check untouch.
		int EFlags = GetEntData(g_aEntityLagData[i].iEntity, g_iEFlags);
		EFlags &= ~EFL_CHECK_UNTOUCH;
		SetEntData(g_aEntityLagData[i].iEntity, g_iEFlags, EFlags);
	}
}


public void OnRunThinkFunctions(bool simulating)
{
	FilterTriggerTouchPlayers(g_aBlockTriggerTouch, false);

	for(int i = 0; i < g_iNumEntities; i++)
	{
		if(!IsValidEntity(g_aEntityLagData[i].iEntity))
		{
			PrintToBoth("!!!!!!!!!!! OnRunThinkFunctions SHIT deleted: %d / %d", i, g_aEntityLagData[i].iEntity);
			RemoveRecord(i);
			i--; continue;
		}

		// Save old touchStamp
		int touchStamp = GetEntData(g_aEntityLagData[i].iEntity, g_iTouchStamp);
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
		SetEntData(g_aEntityLagData[i].iEntity, g_iTouchStamp, touchStamp);

		if(g_aEntityLagData[i].iDeleted)
		{
			if(g_aEntityLagData[i].iDeleted + MAX_RECORDS <= GetGameTickCount())
			{
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

		// +1 because the newest record in the list is one tick old
		// this is because we simulate players first
		// hence no new entity record was inserted on the current tick
		iDelta += 1;
		if(iDelta >= g_aEntityLagData[i].iNumRecords)
			iDelta = g_aEntityLagData[i].iNumRecords - 1;

		int iRecordIndex = g_aEntityLagData[i].iRecordIndex - iDelta;
		if(iRecordIndex < 0)
			iRecordIndex += MAX_RECORDS;

		RestoreEntityFromRecord(iEntity, g_aaLagRecords[i][iRecordIndex]);
		g_aEntityLagData[i].bRestore |= !g_aEntityLagData[i].iDeleted;
	}

	return Plugin_Continue;
}

public void OnPostPlayerThinkFunctions()
{
	for(int i = 0; i < g_iNumEntities; i++)
	{
		// Restore original touchStamp
		SetEntData(g_aEntityLagData[i].iEntity, g_iTouchStamp, g_aEntityLagData[i].iTouchStamp);

		if(!g_aEntityLagData[i].bRestore)
			continue;

		RestoreEntityFromRecord(g_aEntityLagData[i].iEntity, g_aEntityLagData[i].RestoreData);
		g_aEntityLagData[i].bRestore = false;
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

			if(CompareVectors(g_aaLagRecords[i][iOldRecord].vecAbsOrigin, TmpRecord.vecAbsOrigin) &&
				CompareVectors(g_aaLagRecords[i][iOldRecord].angAbsRotation, TmpRecord.angAbsRotation))
			{
				g_aEntityLagData[i].iNotMoving++;
			}
			else
			{
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
	}
}


void RecordDataIntoRecord(int iEntity, LagRecord Record)
{
	// Force recalculation of all values
	int EFlags = GetEntData(iEntity, g_iEFlags);
	EFlags |= EFL_DIRTY_ABSTRANSFORM;
	SetEntData(iEntity, g_iEFlags, EFlags);

	SDKCall(g_hCalcAbsolutePosition, iEntity);

	GetEntDataVector(iEntity, g_iVecOrigin, Record.vecOrigin);
	GetEntDataVector(iEntity, g_iVecAbsOrigin, Record.vecAbsOrigin);
	GetEntDataVector(iEntity, g_iAngRotation, Record.angRotation);
	GetEntDataVector(iEntity, g_iAngAbsRotation, Record.angAbsRotation);
	GetEntDataArray(iEntity, g_iCoordinateFrame, view_as<int>(Record.rgflCoordinateFrame), COORDINATE_FRAME_SIZE);
	Record.flSimulationTime = GetEntDataFloat(iEntity, g_iSimulationTime);
}

bool DoesRotationInvalidateSurroundingBox(int iEntity)
{
	int SolidFlags = GetEntData(iEntity, g_iSolidFlags);
	if(SolidFlags & FSOLID_ROOT_PARENT_ALIGNED)
		return true;

	int SurroundType = GetEntData(iEntity, g_iSurroundType);
	switch(SurroundType)
	{
		case USE_COLLISION_BOUNDS_NEVER_VPHYSICS,
			 USE_OBB_COLLISION_BOUNDS,
			 USE_BEST_COLLISION_BOUNDS:
		{
			// IsBoundsDefinedInEntitySpace()
			int SolidType = GetEntData(iEntity, g_iSolidType);
			return ((SolidFlags & FSOLID_FORCE_WORLD_ALIGNED) == 0) &&
					(SolidType != SOLID_BBOX) && (SolidType != SOLID_NONE);
		}

		case USE_HITBOXES,
			 USE_GAME_CODE:
		{
			return true;
		}

		case USE_ROTATION_EXPANDED_BOUNDS,
			 USE_SPECIFIED_BOUNDS:
		{
			return false;
		}

		default:
		{
			return true;
		}
	}
}

void InvalidatePhysicsRecursive(int iEntity)
{
	// NetworkProp()->MarkPVSInformationDirty()
	int fStateFlags = GetEdictFlags(iEntity);
	fStateFlags |= FL_EDICT_DIRTY_PVS_INFORMATION;
	SetEdictFlags(iEntity, fStateFlags);

	// CollisionProp()->MarkPartitionHandleDirty();
	Address CollisionProp = GetEntityAddress(iEntity) + view_as<Address>(g_iCollision);
	SDKCall(g_hMarkPartitionHandleDirty, CollisionProp);

	if(DoesRotationInvalidateSurroundingBox(iEntity))
	{
		// CollisionProp()->MarkSurroundingBoundsDirty();
		int EFlags = GetEntData(iEntity, g_iEFlags);
		EFlags |= EFL_DIRTY_SURROUNDING_COLLISION_BOUNDS;
		SetEntData(iEntity, g_iEFlags, EFlags);
	}
}

void RestoreEntityFromRecord(int iEntity, LagRecord Record)
{
	SetEntDataVector(iEntity, g_iVecOrigin, Record.vecOrigin);
	SetEntDataVector(iEntity, g_iVecAbsOrigin, Record.vecAbsOrigin);
	SetEntDataVector(iEntity, g_iAngRotation, Record.angRotation);
	SetEntDataVector(iEntity, g_iAngAbsRotation, Record.angAbsRotation);
	SetEntDataArray(iEntity, g_iCoordinateFrame, view_as<int>(Record.rgflCoordinateFrame), COORDINATE_FRAME_SIZE);
	SetEntDataFloat(iEntity, g_iSimulationTime, Record.flSimulationTime);

	InvalidatePhysicsRecursive(iEntity);
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
	g_aEntityLagData[i].iTouchStamp = GetEntData(iEntity, g_iTouchStamp);

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
	for(int i = 0; i < 3; i++)
	{
		obj.vecOrigin[i] = other.vecOrigin[i];
		obj.vecAbsOrigin[i] = other.vecAbsOrigin[i];
		obj.angRotation[i] = other.angRotation[i];
		obj.angAbsRotation[i] = other.angAbsRotation[i];
	}

	obj.flSimulationTime = other.flSimulationTime;

	for(int i = 0; i < COORDINATE_FRAME_SIZE; i++)
	{
		obj.rgflCoordinateFrame[i] = other.rgflCoordinateFrame[i];
	}
}

bool CompareVectors(const float vec1[3], const float vec2[3])
{
	return vec1[0] == vec2[0] && vec1[1] == vec2[1] && vec1[2] == vec2[2];
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
