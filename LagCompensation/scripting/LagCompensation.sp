#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <CSSFixes>
#include <dhooks>

#define SetBit(%1,%2)		((%1)[(%2) >> 5] |= (1 << ((%2) & 31)))
#define ClearBit(%1,%2)		((%1)[(%2) >> 5] &= ~(1 << ((%2) & 31)))
#define CheckBit(%1,%2)		!!((%1)[(%2) >> 5] & (1 << ((%2) & 31)))

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name 			= "LagCompensation",
	author 			= "BotoX",
	description 	= "",
	version 		= "1.0",
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

enum
{
	SF_TRIGGER_ALLOW_CLIENTS				= 0x01,		// Players can fire this trigger
	SF_TRIGGER_ALLOW_NPCS					= 0x02,		// NPCS can fire this trigger
	SF_TRIGGER_ALLOW_PUSHABLES				= 0x04,		// Pushables can fire this trigger
	SF_TRIGGER_ALLOW_PHYSICS				= 0x08,		// Physics objects can fire this trigger
	SF_TRIGGER_ONLY_PLAYER_ALLY_NPCS		= 0x10,		// *if* NPCs can fire this trigger, this flag means only player allies do so
	SF_TRIGGER_ONLY_CLIENTS_IN_VEHICLES		= 0x20,		// *if* Players can fire this trigger, this flag means only players inside vehicles can
	SF_TRIGGER_ALLOW_ALL					= 0x40,		// Everything can fire this trigger EXCEPT DEBRIS!
	SF_TRIGGER_ONLY_CLIENTS_OUT_OF_VEHICLES	= 0x200,	// *if* Players can fire this trigger, this flag means only players outside vehicles can
	SF_TRIG_PUSH_ONCE						= 0x80,		// trigger_push removes itself after firing once
	SF_TRIG_PUSH_AFFECT_PLAYER_ON_LADDER	= 0x100,	// if pushed object is player on a ladder, then this disengages them from the ladder (HL2only)
	SF_TRIG_TOUCH_DEBRIS 					= 0x400,	// Will touch physics debris objects
	SF_TRIGGER_ONLY_NPCS_IN_VEHICLES		= 0x800,	// *if* NPCs can fire this trigger, only NPCs in vehicles do so (respects player ally flag too)
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
Handle g_hActivate;
Handle g_hAcceptInput;

int g_iParent;
int g_iSpawnFlags;
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

int g_aLagCompensated[MAX_EDICTS] = {-1, ...};
int g_aFilterTriggerTouch[MAX_EDICTS / 32];
int g_aaFilterClientEntity[((MAXPLAYERS + 1) * MAX_EDICTS) / 32];
int g_aBlockTriggerMoved[MAX_EDICTS / 32];
int g_aBlacklisted[MAX_EDICTS / 32];

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


	hGameData = LoadGameConfigFile("sdktools.games");
	if(!hGameData)
		SetFailState("Failed to load sdktools gamedata.");

	int offset = GameConfGetOffset(hGameData, "Activate");
	if(offset == -1)
		SetFailState("Failed to find Activate offset");

	// CPhysForce::Activate
	g_hActivate = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, Hook_CPhysForce_Activate);
	if(g_hActivate == INVALID_HANDLE)
		SetFailState("Failed to DHookCreate Activate");

	offset = GameConfGetOffset(hGameData, "AcceptInput");
	if(offset == -1)
		SetFailState("Failed to find AcceptInput offset.");

	// CBaseEntity::AcceptInput( const char *szInputName, CBaseEntity *pActivator, CBaseEntity *pCaller, variant_t Value, int outputID )
	g_hAcceptInput = DHookCreate(offset, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity, OnAcceptInput);
	if(g_hAcceptInput == INVALID_HANDLE)
		SetFailState("Failed to DHook AcceptInput.");

	DHookAddParam(g_hAcceptInput, HookParamType_CharPtr);
	DHookAddParam(g_hAcceptInput, HookParamType_CBaseEntity);
	DHookAddParam(g_hAcceptInput, HookParamType_CBaseEntity);
	DHookAddParam(g_hAcceptInput, HookParamType_Object, 20, DHookPass_ByVal|DHookPass_ODTOR|DHookPass_OCTOR|DHookPass_OASSIGNOP); // variant_t is a union of 12 (float[3]) plus two int type params 12 + 8 = 20
	DHookAddParam(g_hAcceptInput, HookParamType_Int);

	delete hGameData;


	RegAdminCmd("sm_unlag", Command_AddLagCompensation, ADMFLAG_RCON, "sm_unlag <entidx>");
	RegAdminCmd("sm_lagged", Command_CheckLagCompensated, ADMFLAG_GENERIC, "sm_lagged");

	FilterClientEntityMap(g_aaFilterClientEntity, true);
	BlockTriggerMoved(g_aBlockTriggerMoved, true);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginEnd()
{
	g_bCleaningUp = true;
	FilterClientEntityMap(g_aaFilterClientEntity, false);
	BlockTriggerMoved(g_aBlockTriggerMoved, false);
	FilterTriggerTouchPlayers(g_aFilterTriggerTouch, false);

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

	g_bCleaningUp = false;

	g_iParent = FindDataMapInfo(0, "m_pParent");
	g_iSpawnFlags = FindDataMapInfo(0, "m_spawnflags");
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
			{
				OnEntityCreated(entity, sClassname);
				OnEntitySpawned(entity, sClassname);

				if(StrEqual(sClassname, "phys_thruster", false))
				{
					Hook_CPhysForce_Activate(entity);
				}
			}
		}
	}

	g_bLateLoad = false;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if(g_bCleaningUp)
		return;

	if(StrEqual(classname, "phys_thruster", false))
	{
		DHookEntity(g_hActivate, true, entity);
	}
	else if(StrEqual(classname, "game_ui", false))
	{
		DHookEntity(g_hAcceptInput, true, entity);
	}
}

public void OnEntitySpawned(int entity, const char[] classname)
{
	if(g_bCleaningUp)
		return;

	CheckEntityForLagComp(entity, classname);
}

public MRESReturn OnAcceptInput(int entity, Handle hReturn, Handle hParams)
{
	if(!IsValidEntity(entity))
		return MRES_Ignored;

	char sCommand[128];
	DHookGetParamString(hParams, 1, sCommand, sizeof(sCommand));

	if(!StrEqual(sCommand, "Activate", false))
		return MRES_Ignored;

	if(DHookIsNullParam(hParams, 3))
		return MRES_Ignored;

	int iCaller = DHookGetParam(hParams, 3);
	if(iCaller <= 0 || iCaller >= MAX_EDICTS)
		return MRES_Ignored;

	// Don't lagcompensate anything that has a game_ui button in their hierarchy.
	BlacklistFamily(iCaller);

	return MRES_Ignored;
}

void BlacklistFamily(int entity)
{
	if(entity > 0 && entity < MAX_EDICTS)
	{
		SetBit(g_aBlacklisted, entity);
		RemoveEntityFromLagCompensation(entity);
	}

	// Blacklist children of this entity
	BlacklistChildren(entity);

	// And blacklist all parents and their children
	for(;;)
	{
		entity = GetEntDataEnt2(entity, g_iParent);
		if(entity == INVALID_ENT_REFERENCE)
			break;

		if(entity > 0 && entity < MAX_EDICTS)
		{
			SetBit(g_aBlacklisted, entity);
			RemoveEntityFromLagCompensation(entity);
		}

		// And their children
		BlacklistChildren(entity);
	}
}

void BlacklistChildren(int parent)
{
	int entity = INVALID_ENT_REFERENCE;
	while((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_REFERENCE)
	{
		if(GetEntDataEnt2(entity, g_iParent) != parent)
			continue;

		if(entity > 0 && entity < MAX_EDICTS)
		{
			SetBit(g_aBlacklisted, entity);
			RemoveEntityFromLagCompensation(entity);
		}
	}
}

bool CheckEntityForLagComp(int entity, const char[] classname, bool bRecursive=false, bool bGoodParents=false)
{
	if(entity < 0 || entity > MAX_EDICTS)
		return false;

	if(!IsValidEntity(entity))
		return false;

	if(g_aLagCompensated[entity] != -1)
		return false;

	bool bTrigger = StrEqual(classname, "trigger_hurt", false) ||
					StrEqual(classname, "trigger_push", false) ||
					StrEqual(classname, "trigger_teleport", false);

	bool bPhysbox = !strncmp(classname, "func_physbox", 12, false);

	bool bBlacklisted = CheckBit(g_aBlacklisted, entity);

	if(!bTrigger && !bPhysbox || bBlacklisted)
		return false;

	// Don't lag compensate anything that could be parented to a player
	// The player simulation would usually move the entity,
	// but we would overwrite that position change by restoring the entity to its previous state.
	int iParent = INVALID_ENT_REFERENCE;
	char sParentClassname[64];
	for(int iTmp = entity;;)
	{
		iTmp = GetEntDataEnt2(iTmp, g_iParent);
		if(iTmp == INVALID_ENT_REFERENCE)
			break;

		iParent = iTmp;
		GetEntityClassname(iParent, sParentClassname, sizeof(sParentClassname));

		if(StrEqual(sParentClassname, "player") ||
			!strncmp(sParentClassname, "weapon_", 7))
		{
			return false;
		}

		if(CheckBit(g_aBlacklisted, entity))
		{
			return false;
		}

		if(g_aLagCompensated[iParent] != -1)
		{
			bGoodParents = true;
			break;
		}

		if(strncmp(sParentClassname, "func_", 5))
			continue;

		if(StrEqual(sParentClassname[5], "movelinear") ||
			StrEqual(sParentClassname[5], "door") ||
			StrEqual(sParentClassname[5], "rotating") ||
			StrEqual(sParentClassname[5], "tracktrain"))
		{
			bGoodParents = true;
			break;
		}
	}

	if(!bGoodParents)
		return false;

	if(AddEntityForLagCompensation(entity, bTrigger))
	{
		if(bTrigger)
		{
			int Flags = GetEntData(entity, g_iSpawnFlags);
			if(!(Flags & (SF_TRIGGER_ALLOW_PUSHABLES | SF_TRIGGER_ALLOW_PHYSICS | SF_TRIGGER_ALLOW_ALL | SF_TRIG_TOUCH_DEBRIS)))
				SetBit(g_aBlockTriggerMoved, entity);
		}

		if(bRecursive)
		{
			CheckEntityChildrenForLagComp(entity);
		}

		return true;
	}

	return false;
}

void CheckEntityChildrenForLagComp(int parent)
{
	int entity = INVALID_ENT_REFERENCE;
	while((entity = FindEntityByClassname(entity, "*")) != INVALID_ENT_REFERENCE)
	{
		if(GetEntDataEnt2(entity, g_iParent) != parent)
			continue;

		char sClassname[64];
		if(GetEntityClassname(entity, sClassname, sizeof(sClassname)))
		{
			CheckEntityForLagComp(entity, sClassname, _, true);
			CheckEntityChildrenForLagComp(entity);
		}
	}
}

public void OnEntityDestroyed(int entity)
{
	if(g_bCleaningUp)
		return;

	if(entity < 0 || entity > MAX_EDICTS)
		return;

	ClearBit(g_aBlacklisted, entity);

	int iIndex = g_aLagCompensated[entity];
	if(iIndex == -1)
		return;

	RemoveRecord(iIndex);
}


public MRESReturn Detour_OnUTIL_Remove(Handle hParams)
{
	if(g_bCleaningUp)
		return MRES_Ignored;

	int entity = DHookGetParam(hParams, 1);
	if(entity < 0 || entity > MAX_EDICTS)
		return MRES_Ignored;

	int iIndex = g_aLagCompensated[entity];
	if(iIndex == -1)
		return MRES_Ignored;

	// let it die
	if(!g_aEntityLagData[iIndex].bLateKill)
		return MRES_Ignored;

	// ignore sleeping entities
	if(g_aEntityLagData[iIndex].iNotMoving >= MAX_RECORDS)
		return MRES_Ignored;

	if(!g_aEntityLagData[iIndex].iDeleted)
	{
		g_aEntityLagData[iIndex].iDeleted = GetGameTickCount();
	}

	return MRES_Supercede;
}

public MRESReturn Detour_OnRestartRound()
{
	g_bCleaningUp = true;

	for(int i = 0; i < g_iNumEntities; i++)
	{
		int iEntity = g_aEntityLagData[i].iEntity;

		g_aLagCompensated[iEntity] = -1;
		ClearBit(g_aFilterTriggerTouch, iEntity);
		ClearBit(g_aBlockTriggerMoved, iEntity);

		for(int client = 1; client <= MaxClients; client++)
		{
			ClearBit(g_aaFilterClientEntity, client * MAX_EDICTS + iEntity);
		}

		if(g_aEntityLagData[i].iDeleted)
		{
			if(IsValidEntity(iEntity))
				RemoveEdict(iEntity);
		}

		g_aEntityLagData[i].iEntity = INVALID_ENT_REFERENCE;
	}

	for(int i = 0; i < sizeof(g_aBlacklisted); i++)
		g_aBlacklisted[i] = 0;

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

	CheckEntityForLagComp(entity, sClassname, true, true);

	return MRES_Ignored;
}

public MRESReturn Hook_CPhysForce_Activate(int entity)
{
	int attachedObject = GetEntPropEnt(entity, Prop_Data, "m_attachedObject");
	if(!IsValidEntity(attachedObject))
		return MRES_Ignored;

	char sClassname[64];
	if(!GetEntityClassname(attachedObject, sClassname, sizeof(sClassname)))
		return MRES_Ignored;

	CheckEntityForLagComp(attachedObject, sClassname, true, true);

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
	FilterTriggerTouchPlayers(g_aFilterTriggerTouch, false);

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

	// -1 because the newest record in the list is one tick old
	// this is because we simulate players first
	// hence no new entity record was inserted on the current tick
	int iGameTick = GetGameTickCount() - 1;

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
			SetBit(g_aaFilterClientEntity, client * MAX_EDICTS + iEntity);
			continue;
		}
		else if(g_aEntityLagData[i].iSpawned == iPlayerSimTick)
		{
			ClearBit(g_aaFilterClientEntity, client * MAX_EDICTS + iEntity);
		}

		if(g_aEntityLagData[i].iDeleted)
		{
			if(g_aEntityLagData[i].iDeleted <= iPlayerSimTick)
			{
				SetBit(g_aaFilterClientEntity, client * MAX_EDICTS + iEntity);
				continue;
			}
		}

		if(g_aEntityLagData[i].iNotMoving >= MAX_RECORDS)
			continue;

		int iRecord = iDelta;
		if(iRecord >= g_aEntityLagData[i].iNumRecords)
			iRecord = g_aEntityLagData[i].iNumRecords - 1;

		int iRecordIndex = g_aEntityLagData[i].iRecordIndex - iRecord;
		if(iRecordIndex < 0)
			iRecordIndex += MAX_RECORDS;

		RestoreEntityFromRecord(iEntity, g_aaLagRecords[i][iRecordIndex]);
		g_aEntityLagData[i].bRestore = !g_aEntityLagData[i].iDeleted;
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

	FilterTriggerTouchPlayers(g_aFilterTriggerTouch, true);
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

	if(g_aLagCompensated[iEntity] != -1)
		return false;

	int i = g_iNumEntities;
	g_iNumEntities++;

	g_aLagCompensated[iEntity] = i;

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

	if(bLateKill)
	{
		SetBit(g_aFilterTriggerTouch, iEntity);
	}

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

bool RemoveEntityFromLagCompensation(int iEntity)
{
	int index = g_aLagCompensated[iEntity];
	if(index == -1)
		return false;

	RemoveRecord(index);
	return true;
}

void RemoveRecord(int index)
{
	if(g_bCleaningUp)
		return;

	int iEntity = g_aEntityLagData[index].iEntity;

	if(IsValidEntity(iEntity))
	{
		char sClassname[64];
		GetEntityClassname(g_aEntityLagData[index].iEntity, sClassname, sizeof(sClassname));

		char sTargetname[64];
		GetEntPropString(g_aEntityLagData[index].iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));

		int iHammerID = GetEntProp(g_aEntityLagData[index].iEntity, Prop_Data, "m_iHammerID");

		PrintToBoth("[%d] RemoveRecord %d / %d (%s)\"%s\"(#%d), num: %d", GetGameTickCount(), index, g_aEntityLagData[index].iEntity, sClassname, sTargetname, iHammerID, g_iNumEntities);
	}

	g_aLagCompensated[iEntity] = -1;
	ClearBit(g_aFilterTriggerTouch, iEntity);
	ClearBit(g_aBlockTriggerMoved, iEntity);

	for(int client = 1; client <= MaxClients; client++)
	{
		ClearBit(g_aaFilterClientEntity, client * MAX_EDICTS + iEntity);
	}

	g_aEntityLagData[index].iEntity = INVALID_ENT_REFERENCE;

	for(int src = index + 1; src < g_iNumEntities; src++)
	{
		int dest = src - 1;

		EntityLagData_Copy(g_aEntityLagData[dest], g_aEntityLagData[src]);
		g_aEntityLagData[src].iEntity = INVALID_ENT_REFERENCE;
		g_aLagCompensated[g_aEntityLagData[dest].iEntity] = dest;

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

	return Plugin_Handled;
}

public Action Command_CheckLagCompensated(int client, int argc)
{
	if(argc == 0)
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

		return Plugin_Handled;
	}

	for(int iEntity = 0; iEntity < MAX_EDICTS; iEntity++)
	{
		bool bDeleted = false;
		for(int j = 1; j <= MaxClients; j++)
		{
			if(CheckBit(g_aaFilterClientEntity, j * MAX_EDICTS + iEntity))
			{
				bDeleted = true;
				break;
			}
		}

		bool bBlockPhysics = CheckBit(g_aFilterTriggerTouch, iEntity);
		bool bBlockTriggerMoved = CheckBit(g_aBlockTriggerMoved, iEntity);
		bool bBlacklisted = CheckBit(g_aBlacklisted, iEntity);

		if(bDeleted || bBlockPhysics || bBlockTriggerMoved || bBlacklisted)
		{
			int index = -1;
			for(int j = 0; j < g_iNumEntities; j++)
			{
				if(g_aEntityLagData[j].iEntity == iEntity)
				{
					index = j;
					break;
				}
			}

			char sClassname[64] = "INVALID";
			char sTargetname[64] = "INVALID";
			int iHammerID = -1;

			if(IsValidEntity(iEntity))
			{
				GetEntityClassname(iEntity, sClassname, sizeof(sClassname));
				GetEntPropString(iEntity, Prop_Data, "m_iName", sTargetname, sizeof(sTargetname));
				iHammerID = GetEntProp(iEntity, Prop_Data, "m_iHammerID");
			}

			PrintToConsole(client, "%2d. #%d %s \"%s\" (#%d) -> Phys: %d / TrigMov: %d / Deleted: %d / Black: %d",
				index, iEntity, sClassname, sTargetname, iHammerID, bBlockPhysics, bBlockTriggerMoved, bDeleted, bBlacklisted);
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
