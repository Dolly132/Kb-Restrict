#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <multicolors>
#include <adminmenu>
#include <KbRestrict>

#define KB_Tag "{aqua}[Kb-Restrict]{bisque}"
#define MenuMode_RestrictPlayer 0
#define MenuMode_OnlineBans 1
#define MenuMode_AllBans 2
#define MenuMode_OwnBans 3

/* Array handle */
ArrayList g_aBannedIPs;

/* Admin Menu */
TopMenu g_hAdminMenu = null;

/* Cvar handle */
ConVar
	g_cvDefaultLength = null
	, g_cvAddBanLength = null
	, g_cvNetPublicAddr = null
	, g_cvPort = null
	, g_hCvar_MaxBanTime
	, g_hCVar_Debug;

/* Database handle */
Database g_hDB;

char
	ServerIP[32];

float RetryTime = 15.0;

bool
	g_bKnifeModeEnabled
	, g_bIsClientRestricted[MAXPLAYERS + 1] = {false, ...}
	, g_bIsClientTypingReason[MAXPLAYERS + 1] = { false, ... };

int
	g_iClientTargets[MAXPLAYERS + 1] = { -1, ... }
	, g_iClientTargetsLength[MAXPLAYERS + 1] = { -1, ... }
	, g_iClientMenuMode[MAXPLAYERS + 1] = {-1, ...};

enum struct PlayerData
{
	int BanDuration;
	int TimeStamp_Start;
	int TimeStamp_End;
	char ClientIP[32];
	char AdminName[32];
	char AdminSteamID[32];
	char Reason[124];
	char MapIssued[124];
	
	void ResetValues()
	{
		this.BanDuration = -2;
		this.TimeStamp_Start = 0;
		this.TimeStamp_End = 0;
		this.ClientIP[0] = '\0';
		this.AdminName[0] = '\0';
		this.AdminSteamID[0] = '\0';
		this.Reason[0] = '\0';
		this.MapIssued[0] = '\0';
	}
}

PlayerData g_PlayerData[MAXPLAYERS + 1];

public Plugin myinfo = 
{
	name = "Kb-Restrict",
	author = "Dolly, .Rushaway",
	description = "Adjust weapons damage from the KBanned players",
	version = "3.1.3",
	url = "https://nide.gg"
}

//----------------------------------------------------------------------------------------------------
// Forwards :
//----------------------------------------------------------------------------------------------------
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	RegPluginLibrary("KbRestrict");

	CreateNative("Kb_BanClient", Native_KB_BanClient);
	CreateNative("Kb_UnBanClient", Native_KB_UnBanClient);
	CreateNative("Kb_ClientStatus", Native_KB_ClientStatus);
	
	return APLRes_Success;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnPluginStart()
{
	LoadTranslations("KbRestrict.phrases");
	LoadTranslations("common.phrases");

	RegAdminCmd("sm_kban", Command_KbRestrict, ADMFLAG_BAN, "sm_kban <#userid|name> <minutes|0> [reason]");
	RegAdminCmd("sm_kunban", Command_KbUnRestrict, ADMFLAG_BAN, "sm_kunban <#userid|name> [reason]");
	RegAdminCmd("sm_koban", Command_OfflineKbRestrict, ADMFLAG_BAN, "sm_koban <#userid|name> <minutes|0> [reason]");
	RegConsoleCmd("sm_kstatus", Command_CheckKbStatus, "Shows current player Kb-Restrict status");
	RegConsoleCmd("sm_kbanstatus", Command_CheckKbStatus, "Shows current player Kb-Restrict status");

	g_cvDefaultLength 	= CreateConVar("sm_kbrestrict_length", "30", "Default length when no length is specified");
	g_cvAddBanLength 	= CreateConVar("sm_kbrestrict_addban_length", "133920", "The Maximume length for offline KbRestrict command");
	g_hCvar_MaxBanTime	= CreateConVar("sm_kbrestrict_max_bantime", "133920", "Maximum ban time allowed via console command (0-518400)", _, true, 0.0, true, 518400.0);
	g_hCVar_Debug 		= CreateConVar("sm_kbrestrict_debug_level", "1", "[0 = Disabled | 1 = Errors | 2 = Infos]", FCVAR_REPLICATED);

	AutoExecConfig(true);
	
	g_cvNetPublicAddr = FindConVar("net_public_adr");
	if(g_cvNetPublicAddr == null)
		g_cvNetPublicAddr = CreateConVar("net_public_adr", "", "For servers behind NAT/DHCP meant to be exposed to the public internet, this is the public facing ip address string: (\"x.x.x.x\" )", FCVAR_NOTIFY);

	g_cvPort = FindConVar("hostport");

	char sNet[32], sPort[16];
	g_cvNetPublicAddr.GetString(sNet, sizeof(sNet));
	g_cvPort.GetString(sPort, sizeof(sPort));
	
	Format(ServerIP, sizeof(ServerIP), "%s:%s", sNet, sPort);

	ConnectToDB();
	CreateTimer(2.0, Timer_BansChecker, _, TIMER_REPEAT);
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i))
		{
			OnClientPutInServer(i);
			OnClientPostAdminCheck(i);
			OnClientConnected(i);
		}
	}
	
	TopMenu topmenu;
	if(LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
		OnAdminMenuReady(topmenu);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnAllPluginsLoaded()
{
	g_bKnifeModeEnabled = LibraryExists("KnifeMode");
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
	public void OnLibraryAdded(const char[] name)	
{	
	if (StrEqual(name, "KnifeMode"))	
		g_bKnifeModeEnabled = true;	
}

//----------------------------------------------------------------------------------------------------	
// Purpose:	
//----------------------------------------------------------------------------------------------------	
public void OnLibraryRemoved(const char[] name)	
{	
	if(StrEqual(name, "adminmenu", false))	
		g_hAdminMenu = null;	
	if (StrEqual(name, "KnifeMode"))	
		g_bKnifeModeEnabled = false;	
}

//----------------------------------------------------------------------------------------------------	
// Purpose:	
//----------------------------------------------------------------------------------------------------
public void OnMapStart()
{
	g_aBannedIPs = new ArrayList(ByteCountToCells(4096));
	UpdateBannedIPs();
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnMapEnd()
{
	g_aBannedIPs.Clear();
	delete g_aBannedIPs;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientConnected(int client)
{
	if(IsFakeClient(client))
		return;
		
	char ClientIP[32];
	GetClientIP(client, ClientIP, sizeof(ClientIP));
	
	if(g_aBannedIPs == null)
		return;
		
	if(g_aBannedIPs.FindString(ClientIP) != -1)
		g_bIsClientRestricted[client] = true;
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientDisconnect(int client)
{
	g_bIsClientRestricted[client] = false;
	g_bIsClientTypingReason[client] = false;
	g_PlayerData[client].ResetValues();
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void OnClientPostAdminCheck(int client)
{
	if(IsFakeClient(client))
		return;
		
	KB_ApplyRestrict(client);
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
stock void CheckPlayerExpireTime(int lefttime, char[] TimeLeft, int maxlength)
{
	if(lefttime > -1)
	{
		if(lefttime < 60) // 60 secs
			FormatEx(TimeLeft, maxlength, "%02i %s", lefttime, "Seconds");
		else if(lefttime > 3600 && lefttime <= 3660) // 1 Hour
			FormatEx(TimeLeft, maxlength, "%i %s %02i %s", lefttime / 3600, "Hour", (lefttime / 60) % 60, "Minutes");
		else if(lefttime > 3660 && lefttime < 86400) // 2 Hours or more
			FormatEx(TimeLeft, maxlength, "%i %s %02i %s", lefttime / 3600, "Hours", (lefttime / 60) % 60, "Minutes");
		else if(lefttime > 86400 && lefttime <= 172800) // 1 Day
			FormatEx(TimeLeft, maxlength, "%i %s %02i %s", lefttime / 86400, "Day", (lefttime / 3600) % 24, "Hours");
		else if(lefttime > 172800) // 2 Days or more
			FormatEx(TimeLeft, maxlength, "%i %s %02i %s", lefttime / 86400, "Days", (lefttime / 3600) % 24, "Hours");
		else // Less than 1 Hour
			FormatEx(TimeLeft, maxlength, "%i %s %02i %s", lefttime / 60, "Minutes", lefttime % 60, "Seconds");
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
stock int GetCurrent_KbRestrict_Players()
{
	int count = 0;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && g_bIsClientRestricted[i])
			count++;
	}
	
	return count;
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
stock int GetPlayerFromSteamID(const char[] sSteamID)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if(IsValidClient(i) && IsClientAuthorized(i))
		{
			char SteamID[32];
			GetClientAuthId(i, AuthId_Steam2, SteamID, sizeof(SteamID));
			if(StrEqual(sSteamID, SteamID))
				return i;
		}
	}
	
	return -1;
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
stock void FormatClientTeam(int client, char[] buf, int maxlen)
{
	switch(GetClientTeam(client))
	{
		case 0:
			Format(buf, maxlen, "No Team");
		case 1:
			Format(buf, maxlen, "Spectator");
		case 2:
			Format(buf, maxlen, "Zombie");
		case 3:
			Format(buf, maxlen, "Human");
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
	if(g_bKnifeModeEnabled == false)
	{
		if(IsValidClient(victim) && IsValidClient(attacker) && attacker != victim)
		{
			if(IsPlayerAlive(attacker) && GetClientTeam(attacker) == 3 && g_bIsClientRestricted[attacker])
			{
				char sWeapon[32];
				GetClientWeapon(attacker, sWeapon, 32);

				/* Knife */
				if (StrEqual(sWeapon, "weapon_knife"))
					damage -= (damage * 0.95);

				/* ShotGuns */
				if (StrEqual(sWeapon, "weapon_m3") || StrEqual(sWeapon, "weapon_xm1014"))
					damage -= (damage * 0.80);

				/* Snipers */
				if (StrEqual(sWeapon, "weapon_awp") || StrEqual(sWeapon, "weapon_scout"))
					damage -= (damage * 0.60);

				/* Semi-Auto Snipers */
				if (StrEqual(sWeapon, "weapon_sg550") || StrEqual(sWeapon, "weapon_g3sg1"))
					damage -= (damage * 0.40);

				return Plugin_Changed;
			}
		}
	}
	
	return Plugin_Continue;
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
stock bool IsValidClient(int client)
{
	return (1 <= client <= MaxClients && IsClientInGame(client) && !IsClientSourceTV(client) && !IsFakeClient(client));
}

//----------------------------------------------------------------------------------------------------
// Native :
//----------------------------------------------------------------------------------------------------
public int Native_KB_BanClient(Handle plugin, int params)
{
	char sReason[128];
		
	int admin = GetNativeCell(1);
	int client = GetNativeCell(2);
	int time = GetNativeCell(3);
	GetNativeString(4, sReason, sizeof(sReason));

	if(g_bIsClientRestricted[client])
		return 0;
			
	KB_RestrictPlayer(client, admin, time, sReason);
	return 1;
}

//----------------------------------------------------------------------------------------------------
// Native :
//----------------------------------------------------------------------------------------------------
public int Native_KB_UnBanClient(Handle plugin, int params)
{
	char sReason[128];
		
	int admin = GetNativeCell(1);
	int client = GetNativeCell(2);
	GetNativeString(3, sReason, sizeof(sReason));

	if(!g_bIsClientRestricted[client])
		return 0;
		
	KB_UnRestrictPlayer(client, admin, sReason);
	return 1;
}

//----------------------------------------------------------------------------------------------------
// Native :
//----------------------------------------------------------------------------------------------------
public int Native_KB_ClientStatus(Handle plugin, int params)
{
	int client = GetNativeCell(1);

	return g_bIsClientRestricted[client];
}

//----------------------------------------------------------------------------------------------------
// Database Attempting Connection :
//----------------------------------------------------------------------------------------------------
stock void ConnectToDB()
{
	Database.Connect(DB_OnConnect, "KbRestrict");
}

//----------------------------------------------------------------------------------------------------
// Database Connection Status :
//----------------------------------------------------------------------------------------------------
public void DB_OnConnect(Database db, const char[] sError, any data)
{
	if(db == null || sError[0])
	{
		if (RetryTime <= 15.0)
			RetryTime = 15.0;
		else if (RetryTime > 60.0)
			RetryTime = 60.0;
		
		/* Failure happen. Do retry with delay */
		CreateTimer(RetryTime, DB_RetryConnection);
		
		if (g_hCVar_Debug.IntValue >= 1)
		{
			int RetryTimeInt = RoundToFloor(RetryTime);
			LogError("[Kb-Restrict] Couldn't connect to database `KbRestrict`, retrying in %d seconds. \nError: %s", RetryTimeInt, sError);
		}

		return;
	}
	
	LogMessage("[Kb-Restrict] Successfully connected to database!");
	g_hDB = db;
	g_hDB.SetCharset("utf8");
	DB_CreateTables();
}

//----------------------------------------------------------------------------------------------------
// Database Attempting Reconnect :
//----------------------------------------------------------------------------------------------------
public Action DB_RetryConnection(Handle timer)
{
    if(g_hDB == null)
        ConnectToDB();
    
    return Plugin_Continue;
}

public Action Timer_BansChecker(Handle timer)
{
	if(g_hDB == null)
		return Plugin_Stop;
	
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_steamid`, `length`, `time_stamp_end` FROM `KbRestrict_CurrentBans` WHERE server_ip='%s'", ServerIP);
	SQL_TQuery(g_hDB, SQL_CheckBans, sQuery);
	return Plugin_Continue;
}

public void SQL_CheckBans(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(hResults == null)
		return;
	
	char SteamID[32];
	int length, time_stamp_end;
	while(SQL_FetchRow(hResults))
	{
		SQL_FetchString(hResults, 0, SteamID, sizeof(SteamID));
		int client = GetPlayerFromSteamID(SteamID);
		length = SQL_FetchInt(hResults, 1);
		time_stamp_end = SQL_FetchInt(hResults, 2);
		
		if(length == 0)
			continue;
		
		if(time_stamp_end < GetTime())
		{
			if(client != -1)
				KB_UnRestrictPlayer(client, 0, "KBan Expired");
			else
				KB_RemoveBanFromDB(SteamID);
		}
	}
}
						
stock void UpdateBannedIPs()
{
	if(g_aBannedIPs == null)
		return;
		
	g_aBannedIPs.Clear();
	
	// Let's add the banned IPs to the arraylist
	if(g_hDB == null)
		return;
	
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_ip` FROM `KbRestrict_CurrentBans` WHERE server_ip='%s'", ServerIP);
	SQL_TQuery(g_hDB, SQL_AddBannedIPsToArray, sQuery);
}

//----------------------------------------------------------------------------------------------------
// Database :
//----------------------------------------------------------------------------------------------------
public void SQL_AddBannedIPsToArray(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(hResults == null)
		return;
	
	while(SQL_FetchRow(hResults))
	{
		char ClientIP[32];
		SQL_FetchString(hResults, 0, ClientIP, sizeof(ClientIP));
		
		g_aBannedIPs.PushString(ClientIP);
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose :
//----------------------------------------------------------------------------------------------------
stock void KB_ApplyRestrict(int client)
{
	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
	
	if(g_hDB == null)
		return;
		
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_ip`, `admin_name`, `admin_steamid`, `reason`, `Map`, `length`, `time_stamp_start`, `time_stamp_end`"
											... "FROM `KbRestrict_CurrentBans` WHERE client_steamid='%s' and server_ip='%s'", SteamID, ServerIP);
				
	DataPack pack = new DataPack();
	SQL_TQuery(g_hDB, SQL_ApplyRestrict, sQuery, pack);
	
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(SteamID);
}

//----------------------------------------------------------------------------------------------------
// Database :
//----------------------------------------------------------------------------------------------------
public void SQL_ApplyRestrict(Handle hDatabase, Handle hResults, const char[] sError, DataPack pack)
{
	char SteamID[32];
	
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	pack.ReadString(SteamID, sizeof(SteamID));
	
	delete pack;
	
	if(client < 1)
		return;
	
	if(hResults == null)
		return;
	
	if(!IsClientInGame(client))
		return;
	
	char ClientIP[32];
	GetClientIP(client, ClientIP, sizeof(ClientIP));
	
	char buffer[256];
	while(SQL_FetchRow(hResults))
	{
		/* Get target data from Database */
		
		/* Client IP */
		SQL_FetchString(hResults, 0, buffer, sizeof(buffer));

		/* Check client IP, then update Database data */
		if(StrEqual(buffer, "UnKnown"))
		{
			char sQuery[1024];
			g_hDB.Format(sQuery, sizeof(sQuery), "UPDATE `KbRestrict_CurrentBans` SET client_ip ='%s' WHERE client_steamid='%s'", ClientIP, SteamID);
			SQL_TQuery(g_hDB, SQL_AddClientIPToDB, sQuery);
		}
		else
			Format(g_PlayerData[client].ClientIP, 32, "%s", buffer);

		/* Admin Name */
		SQL_FetchString(hResults, 1, buffer, sizeof(buffer));
		Format(g_PlayerData[client].AdminName, 32, "%s", buffer);

		/* Admin SteamID */
		SQL_FetchString(hResults, 2, buffer, sizeof(buffer));
		Format(g_PlayerData[client].AdminSteamID, 32, "%s", buffer);

		/* Reason */
		SQL_FetchString(hResults, 3, buffer, sizeof(buffer));
		Format(g_PlayerData[client].Reason, 124, "%s", buffer);

		/* Map */
		SQL_FetchString(hResults, 4, buffer, sizeof(buffer));
		Format(g_PlayerData[client].MapIssued, 124, "%s", buffer);
		
		/* Length */
		g_PlayerData[client].BanDuration = SQL_FetchInt(hResults, 5);

		/* Time_stamp_start */
		g_PlayerData[client].TimeStamp_Start = SQL_FetchInt(hResults, 6);

		/* Time_stamp_end */
		g_PlayerData[client].TimeStamp_End = SQL_FetchInt(hResults, 7);
		
		g_bIsClientRestricted[client] = true;
	}
}
	
public void SQL_AddClientIPToDB(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Error while updating client IP. \nError: %s", sError);
}

//----------------------------------------------------------------------------------------------------
// Database :
//----------------------------------------------------------------------------------------------------
stock void DB_CreateTables()
{
	if(g_hDB == null)
		return;
	
	char sDriver[32];
	g_hDB.Driver.GetIdentifier(sDriver, sizeof(sDriver));
	if(StrEqual(sDriver, "mysql", false))
	{
		if (g_hCVar_Debug.IntValue >= 2)
			LogMessage("[Kb-Restrict] Attempting to create table.. (MYSQL)");

		char sQuery[1024];
		g_hDB.Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `KbRestrict_CurrentBans`"
												... "(`id` int(11) unsigned NOT NULL auto_increment,"
												... "`server_ip` varchar(32) NOT NULL,"
												... "`client_name` varchar(64) NOT NULL,"
												... "`client_steamid` varchar(32) NOT NULL,"
												... "`client_ip` varchar(32) NOT NULL,"
												... "`admin_name` varchar(64) NOT NULL,"
												... "`admin_steamid` varchar(32) NOT NULL,"
												... "`reason` varchar(128) NOT NULL,"
												... "`map` varchar(128) NOT NULL,"
												... "`length` int NOT NULL,"
												... "`time_stamp_start` int NOT NULL,"
												... "`time_stamp_end` int NOT NULL,"
												... "PRIMARY KEY (`id`))");
												
		SQL_TQuery(g_hDB, SQL_TablesMySQLCallback, sQuery);
	}
	else if(StrEqual(sDriver, "sqlite", false))
	{
		if (g_hCVar_Debug.IntValue >= 2)
			LogMessage("[Kb-Restrict] Attempting to create table.. (SQLITE)");

		char sQuery[1024];
		g_hDB.Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS `KbRestrict_CurrentBans`"
												... "(`id` INTEGER PRIMARY KEY AUTOINCREMENT,"
												... "`server_ip` varchar(32) NOT NULL,"
												... "`client_name` varchar(64) NOT NULL,"
												... "`client_steamid` varchar(32) NOT NULL,"
												... "`client_ip` varchar(32) NOT NULL,"
												... "`admin_name` varchar(64) NOT NULL,"
												... "`admin_steamid` varchar(32) NOT NULL,"
												... "`reason` varchar(128) NOT NULL,"
												... "`map` varchar(128) NOT NULL,"
												... "`length` INTEGER NOT NULL,"
												... "`time_stamp_start` INTEGER NOT NULL,"
												... "`time_stamp_end` INTEGER NOT NULL)");
												
		SQL_TQuery(g_hDB, SQL_TablesSQLiteCallback, sQuery);
	}
	else
	{
		if (g_hCVar_Debug.IntValue >= 1)
			LogError("[Self-Mute] Couldn't create tables for an unknown driver.");
		return;
	}
}

//----------------------------------------------------------------------------------------------------
// Database :
//----------------------------------------------------------------------------------------------------
public void SQL_TablesMySQLCallback(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(hResults == null)
		return;
		
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Couldn't create tables for MYSQL. \nError: %s", sError);
	else if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Kb-Restrict] Successfully created tables for MYSQL.");
}

//----------------------------------------------------------------------------------------------------
// Database :
//----------------------------------------------------------------------------------------------------
public void SQL_TablesSQLiteCallback(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(hResults == null)
		return;
		
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Couldn't create tables for SQLITE. \nError: %s", sError);
	else if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Kb-Restrict] Successfully created tables for SQLITE.");
}

//----------------------------------------------------------------------------------------------------
// Database :
//----------------------------------------------------------------------------------------------------
stock void KB_RestrictPlayer(int iTarget, int iAdmin, int time, const char[] reason = "NO REASON")
{
	char sAdminName[64], sTargetName[64], sEAdminName[64], sETargetName[64], sReason[128], Map[124];
	char AdminSteamID[32], TargetSteamID[32];
	GetCurrentMap(Map, sizeof(Map));
	g_bIsClientRestricted[iTarget] = true;
	
	if(iAdmin >= 1)
	{
		if(!GetClientAuthId(iAdmin, AuthId_Steam2, AdminSteamID, sizeof(AdminSteamID)))
			return;
	}
	else if(iAdmin < 1)
	{
		AdminSteamID = "Console";
	}
		
	if(!IsClientAuthorized(iTarget))
	{
		g_PlayerData[iTarget].BanDuration = -1;
		Format(g_PlayerData[iTarget].Reason, sizeof(PlayerData::Reason), reason);
		Format(g_PlayerData[iTarget].AdminSteamID, sizeof(PlayerData::AdminSteamID), AdminSteamID);
		CPrintToChatAll("%s %T", KB_Tag, "RestrictedTemp", iAdmin, iAdmin, iTarget, KB_Tag, reason);
		LogAction(iAdmin, iTarget, "[Kb-Restrict] \"%L\" has Kb-Restricted \"%L\" Temporarily. \nReason: %s", iAdmin, iTarget, reason);
		return;
	}
	
	char TargetIP[32]; 
	if(!GetClientIP(iTarget, TargetIP, sizeof(TargetIP)))
		return;
		
	if(!GetClientName(iAdmin, sAdminName, sizeof(sAdminName)))
		return;
		
	if(!GetClientName(iTarget, sTargetName, sizeof(sTargetName)))
		return;
	
	if(time < 0)
	{
		g_PlayerData[iTarget].BanDuration = -1;
		Format(g_PlayerData[iTarget].ClientIP, 32, TargetIP);
		Format(g_PlayerData[iTarget].AdminName, 32, sAdminName);
		Format(g_PlayerData[iTarget].AdminSteamID, 32, AdminSteamID);
		Format(g_PlayerData[iTarget].Reason, 124, reason);
		Format(g_PlayerData[iTarget].MapIssued, 124, Map);
		g_PlayerData[iTarget].TimeStamp_Start = GetTime();
		g_bIsClientRestricted[iTarget] = true;
		
		CPrintToChatAll("%s %T", KB_Tag, "RestrictedTemp", iAdmin, iAdmin, iTarget, KB_Tag, reason);
		LogAction(iAdmin, iTarget, "[Kb-Restrict] \"%L\" has Kb-Restricted \"%L\" Temporarily. \nReason: %s", iAdmin, iTarget, reason);
		return;
	}
	else if(time >= 0)
	{
		if(g_hDB == null)
			return;
	
		if(iAdmin >= 1)
		{
			if(!GetClientAuthId(iAdmin, AuthId_Steam2, AdminSteamID, sizeof(AdminSteamID)))
				return;
		}
		else if(iAdmin < 1)
		{
			AdminSteamID = "Console";
		}
		
		if(!GetClientAuthId(iTarget, AuthId_Steam2, TargetSteamID, sizeof(TargetSteamID)))
			return;
				
		g_hDB.Escape(sAdminName, sEAdminName, sizeof(sEAdminName));
		g_hDB.Escape(sTargetName, sETargetName, sizeof(sETargetName));
		g_hDB.Escape(reason, sReason, sizeof(sReason));
				
		if(iAdmin <= 0)
			Format(sEAdminName, sizeof(sEAdminName), "Console");
			
		if(time > 0)
		{
			int time_stamp_start = GetTime();
			int time_stamp_end = (time_stamp_start + (time * 60));

			Format(g_PlayerData[iTarget].ClientIP, 32, TargetIP);
			Format(g_PlayerData[iTarget].AdminName, 32, sAdminName);
			Format(g_PlayerData[iTarget].AdminSteamID, 32, AdminSteamID);
			Format(g_PlayerData[iTarget].Reason, 124, reason);
			Format(g_PlayerData[iTarget].MapIssued, 124, Map);
			g_PlayerData[iTarget].BanDuration = time;
			g_PlayerData[iTarget].TimeStamp_Start = time_stamp_start;
			g_PlayerData[iTarget].TimeStamp_End = time_stamp_end;
			
			//Add ban to database
			char sQuery[1024];
			g_hDB.Format(sQuery, sizeof(sQuery), "INSERT INTO `KbRestrict_CurrentBans`("
													... "`server_ip`, `client_name`, `client_steamid`, `client_ip`,"
													... "`admin_name`, `admin_steamid`, `reason`,"
													... "`map`, `length`, `time_stamp_start`, `time_stamp_end`) VALUES ("
													... "'%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%d', '%d', '%d')",
													ServerIP, sETargetName, TargetSteamID, TargetIP, sEAdminName, AdminSteamID,
													reason, Map, time, time_stamp_start, time_stamp_end);
													
			SQL_TQuery(g_hDB, SQL_AddBan, sQuery);
			
			CPrintToChatAll("%s %T", KB_Tag, "Restricted", iAdmin, iAdmin, iTarget, time, KB_Tag, reason);
			LogAction(iAdmin, iTarget, "[Kb-Restrict] \"%L\" has Kb-Restricted \"%L\" for \"%d\" minutes. \nReason: %s", iAdmin, iTarget, time, reason);
		}
		else if(time == 0)
		{		
			g_PlayerData[iTarget].BanDuration = 0;
			Format(g_PlayerData[iTarget].ClientIP, 32, TargetIP);
			Format(g_PlayerData[iTarget].AdminName, 32, sAdminName);
			Format(g_PlayerData[iTarget].AdminSteamID, 32, AdminSteamID);
			Format(g_PlayerData[iTarget].Reason, 124, reason);
			Format(g_PlayerData[iTarget].MapIssued, 124, Map);
			g_PlayerData[iTarget].TimeStamp_Start = GetTime();

			Format(g_PlayerData[iTarget].Reason, sizeof(PlayerData::Reason), reason);
			Format(g_PlayerData[iTarget].AdminSteamID, sizeof(PlayerData::AdminSteamID), AdminSteamID);
			CPrintToChatAll("%s %T", KB_Tag, "RestrictedPerma", iAdmin, iAdmin, iTarget, KB_Tag, reason);
			LogAction(iAdmin, iTarget, "[Kb-Restrict] \"%L\" has Kb-Restricted \"%L\" Permanently. \nReason: %s", iAdmin, iTarget, reason);
			
			//Add perma ban to database:
		
			char sQuery[1024];
			g_hDB.Format(sQuery, sizeof(sQuery), "INSERT INTO `KbRestrict_CurrentBans`("
													... "`server_ip`, `client_name`, `client_steamid`, `client_ip`,"
													... "`admin_name`, `admin_steamid`, `reason`,"
													... "`map`, `length`, `time_stamp_start`, `time_stamp_end`) VALUES ("
													... "'%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%d', '%d', '%d')",
													ServerIP, sETargetName, TargetSteamID, TargetIP, sEAdminName, AdminSteamID,
													reason, Map, 0, GetTime(), 0);
			
			SQL_TQuery(g_hDB, SQL_AddPermaBan, sQuery);
		}
		
		g_bIsClientRestricted[iTarget] = true;
	}
	
	UpdateBannedIPs();
}

//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
public void SQL_AddBan(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Error while adding ban to database. \nError: %s", sError);
	else if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Kb-Restrict] Successfully added Kban to database.");
}

//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
public void SQL_AddPermaBan(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Error while adding permanent Kban to database. \nError: %s", sError);
	else if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Kb-Restrict] Successfully added permanent Kban to database.");
}

//----------------------------------------------------------------------------------------------------
// Database And UnRestrict:
//----------------------------------------------------------------------------------------------------
stock void KB_UnRestrictPlayer(int iTarget, int iAdmin, const char[] reason = "NO REASON")
{
	if(!g_bIsClientRestricted[iTarget])
		return;
		
	g_bIsClientRestricted[iTarget] = false;
	CPrintToChatAll("%s %T", KB_Tag, "UnRestricted", iAdmin, iAdmin, iTarget, KB_Tag, reason);
	LogAction(iAdmin, iTarget, "[Kb-Restrict] \"%L\" has Kb-UnRestricted \"%L\". \nReason: %s", iAdmin, iTarget, reason);
	
	char SteamID[32];
	if(!GetClientAuthId(iTarget, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
		
	g_PlayerData[iTarget].ResetValues();
	KB_RemoveBanFromDB(SteamID);
}

//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
stock void KB_AddOfflineBanCheck(const char[] TargetSteamID, const char[] TargetName, int iAdmin, int time, const char[] reason)
{
	if(g_hDB == null)
		return;
	
	int userid;
	if(iAdmin < 1)
		userid = -1;
	else
		userid = GetClientUserId(iAdmin);
		
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_name` FROM `KbRestrict_CurrentBans` WHERE client_steamid='%s'", TargetSteamID);
	DataPack pack = new DataPack();
	SQL_TQuery(g_hDB, SQL_AddOfflineBanCheck, sQuery, pack);
	pack.WriteString(TargetSteamID);
	pack.WriteString(TargetName);
	pack.WriteCell(userid);
	pack.WriteCell(time);
	pack.WriteString(reason);
}

public void SQL_AddOfflineBanCheck(Handle hDatabase, Handle hResults, const char[] sError, DataPack pack)
{
	pack.Reset();
	char TargetSteamID[32], TargetName[64], reason[124];
	pack.ReadString(TargetSteamID, sizeof(TargetSteamID));
	pack.ReadString(TargetName, sizeof(TargetName));
	int userid = pack.ReadCell();
	int iAdmin;
	int time = pack.ReadCell();
	pack.ReadString(reason, sizeof(reason));
	
	delete pack;
	
	if(userid == -1)
		iAdmin = 0;
	else
		iAdmin = GetClientOfUserId(userid);
		
	if(SQL_FetchRow(hResults))
	{
		if(iAdmin == 0)
			PrintToServer("[Kb-Restrict] The specified target is already kbanned");
		else
			CPrintToChat(iAdmin, "%s %T", KB_Tag, "AlreadyKBanned", iAdmin);
			
		return;
	}
	else
		KB_AddOfflineBan(TargetSteamID, TargetName, iAdmin, time, reason);
}

//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
stock void KB_AddOfflineBan(const char[] TargetSteamID, const char[] TargetName, int iAdmin, int time, const char[] reason)
{
	if(g_hDB == null)
		return;
	
	char AdminSteamID[32];
	if(iAdmin == 0)
		AdminSteamID = "Console";
	else if(iAdmin >= 1)
	{
		if(!GetClientAuthId(iAdmin, AuthId_Steam2, AdminSteamID, sizeof(AdminSteamID)))
			return;
	}
	
	char sQuery[1024], sTargetName[64], sReason[124], AdminName[64], sAdminName[64];
	char CurrentMap[64];
	GetCurrentMap(CurrentMap, sizeof(CurrentMap));
	GetClientName(iAdmin, AdminName, sizeof(AdminName));
	g_hDB.Escape(TargetName, sTargetName, sizeof(sTargetName));
	g_hDB.Escape(AdminName, sAdminName, sizeof(sAdminName));
	g_hDB.Escape(reason, sReason, sizeof(sReason));
	
	int time_stamp_end = GetTime() + ((time * 60));
	
	g_hDB.Format(sQuery, sizeof(sQuery), "INSERT INTO `KbRestrict_CurrentBans` ("
											... "`server_ip`, `client_name`, `client_ip`, `client_steamid`,"
											... "`admin_name`, `admin_steamid`, `reason`,"
											... "`map`, `length`, `time_stamp_start`, `time_stamp_end`) "
											... "VALUES ('%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s', '%d', '%d', '%d') "
											... "ON DUPLICATE KEY UPDATE `server_ip`='%s', `client_name`='%s', `client_steamid`='%s',"
											... "`admin_name`='%s', `admin_steamid`='%s', `reason`='%s',"
											... "`map`='%s', `length`='%d', `time_stamp_start`='%d', `time_stamp_end`='%d'",
												ServerIP, sTargetName, "UnKnown", TargetSteamID, sAdminName, AdminSteamID, sReason, CurrentMap, time, GetTime(), time_stamp_end,
												ServerIP, sTargetName, TargetSteamID, sAdminName, AdminSteamID, sReason, CurrentMap, time, GetTime(), time_stamp_end);
								
	SQL_TQuery(g_hDB, SQL_AddOfflineBan, sQuery);
	
	if(iAdmin == 0 || !IsClientInGame(iAdmin))
		PrintToServer("[Kb-Restrict] Successfully Added Kb-Restrict ban on \"%s\"[\"%s\"] for \"%d\" minutes (reason: \"%s\")", TargetName, TargetSteamID, time, sReason);
	else
		CPrintToChat(iAdmin, "%s %T", KB_Tag, "OfflineBan", iAdmin, TargetName, TargetSteamID, time, sReason);
		
	LogAction(iAdmin, -1, "[Kb-Restrict] \"%L\" Added Offline Kb-Restrict on SteamID(\"%s\") with Name(\"%s\") for \"%d\". \nReason: \"%s\"",
							iAdmin, TargetSteamID, TargetName, time, reason);
							
	UpdateBannedIPs();
}
	
//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
public void SQL_AddOfflineBan(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Error while adding an offline kban to database. \nError: %s", sError);
	else if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Kb-Restrict] Successfully Added offline kban to database.");
}

//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
stock void KB_RemoveBanFromDB(const char[] TargetSteamID)
{
	if(g_hDB == null)
		return;
	
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "DELETE FROM `KbRestrict_CurrentBans` WHERE `client_steamid`='%s' and `server_ip`='%s'", TargetSteamID, ServerIP);
	
	SQL_TQuery(g_hDB, SQL_RemoveBanFromDB, sQuery);
	UpdateBannedIPs();
}

//----------------------------------------------------------------------------------------------------
// Database:
//----------------------------------------------------------------------------------------------------
public void SQL_RemoveBanFromDB(Handle hDatabase, Handle hResults, const char[] sError, any data)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("[Kb-Restrict] Error while removing KBan from database. \nError: %s", sError);
	else if (g_hCVar_Debug.IntValue >= 2)
		LogMessage("[Kb-Restrict] Successfully Removed Kban from Database.");
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if(!client)
		return Plugin_Continue;

	if(!IsValidClient(client))
		return Plugin_Continue;
	
	if(!g_bIsClientTypingReason[client])
		return Plugin_Continue;
		
	int target = GetClientOfUserId(g_iClientTargets[client]);
	int length = g_iClientTargetsLength[client];

	if(!target)
		return Plugin_Continue;

	if(StrEqual(command, "say") || StrEqual(command, "say_team"))
	{
		if(!IsValidClient(target))
		{
			CPrintToChat(client, "%s %T", KB_Tag, "PlayerNotValid", client);
			g_bIsClientTypingReason[client] = false;
			return Plugin_Handled;
		}
	
		if(g_bIsClientRestricted[target])
		{
			CPrintToChat(client, "%s %T", KB_Tag, "AlreadyKBanned", client);
			g_bIsClientTypingReason[client] = false;
			return Plugin_Handled;
		}
	
		char buffer[128];
		strcopy(buffer, sizeof(buffer), sArgs);
		KB_RestrictPlayer(target, client, length, buffer);
	
				
		g_bIsClientTypingReason[client] = false;
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

//----------------------------------------------------------------------------------------------------
// Commands :
//----------------------------------------------------------------------------------------------------
public Action Command_CheckKbStatus(int client, int args)
{
	if(!client)
	{
		ReplyToCommand(client, "You cannot use this command from server console.");
		return Plugin_Handled;
	}
	
	if(!g_bIsClientRestricted[client])
	{
		CReplyToCommand(client, "%s %T", KB_Tag, "PlayerNotRestricted", client);
		return Plugin_Handled;
	}
	
	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
	{
		CReplyToCommand(client, "%s %T", KB_Tag, "PlayerRestrcitedTemp", client);
		return Plugin_Handled;
	}
	else
	{
		if(g_PlayerData[client].BanDuration == -1)
		{
			CReplyToCommand(client, "%s %T", KB_Tag, "PlayerRestrcitedTemp", client);
			return Plugin_Handled;
		}
		else if(g_PlayerData[client].BanDuration == 0)
		{
			CReplyToCommand(client, "%s %T", KB_Tag, "PlayerRestrictedPerma", client);
			return Plugin_Handled;
		}
		
		int lefttime = (g_PlayerData[client].TimeStamp_End - GetTime());
		char sTimeLeft[128];
		
		CheckPlayerExpireTime(lefttime, sTimeLeft, sizeof(sTimeLeft));
		CReplyToCommand(client, "%s %T", KB_Tag, "RestrictTimeLeft", client, sTimeLeft);
		return Plugin_Handled;
	}
}

//----------------------------------------------------------------------------------------------------
// Commands :
//----------------------------------------------------------------------------------------------------
public Action Command_KbRestrict(int client, int args)
{
	if(args < 1)
	{
		Display_MainKbRestrictList_Menu(client);
		CReplyToCommand(client, "%s Usage: sm_kban <player> <duration> <reason>", KB_Tag);
		return Plugin_Handled;
	}
	
	char Arguments[256], arg[50], s_time[20];
	GetCmdArgString(Arguments, sizeof(Arguments));
	
	int len, next_len;
	len = BreakString(Arguments, arg, sizeof(arg));
	if(len == -1)
    {
        len = 0;
        Arguments[0] = '\0';
    }
	
	if((next_len = BreakString(Arguments[len], s_time, sizeof(s_time))) != -1)
        len += next_len;
	else
    {
        len = 0;
        Arguments[0] = '\0';
    }

	int time;
	if(!StringToIntEx(s_time, time))
		time = g_cvDefaultLength.IntValue;
	
	// Check for Perma ban and then check if admin is not root if so then stop the command
	if (time == 0 && !CheckCommandAccess(client, "sm_kban_perm", ADMFLAG_ROOT, true))
	{
		CReplyToCommand(client, "%s %T", KB_Tag, "Not have permission pKBan", client);
		return Plugin_Handled;
	}
	
	// Check for the limited kban length, and then check if admin is not root, if so then stop the command
	if(time >= g_hCvar_MaxBanTime.IntValue)
	{
		//Check if admin has permission
		if (!CheckCommandAccess(client, "sm_kban_long", ADMFLAG_ROOT, true))
		{
			CReplyToCommand(client, "%s %T", KB_Tag, "Not have permission lKBan", client, g_hCvar_MaxBanTime.IntValue);
			return Plugin_Handled;
		}
	}
	
	int target = FindTarget(client, arg, false, false);
	
	if(!IsValidClient(target))
		return Plugin_Handled;
	
	if(g_bIsClientRestricted[target])
	{
		if(!client)
		{
			ReplyToCommand(client, "The secified target is aleady kbanned.");
			return Plugin_Handled;
		}
		
		CReplyToCommand(client, "%s %T", KB_Tag, "AlreadyKBanned", client);
		return Plugin_Handled;
	}
	
	if(args < 2)
	{
		KB_RestrictPlayer(target, client, g_cvDefaultLength.IntValue);
		return Plugin_Handled;
	}
	
	if(args < 3)
	{
		if(!CheckCommandAccess(client, "sm_rcon", ADMFLAG_RCON, true) && time == 0)
		{
			KB_RestrictPlayer(target, client, g_cvDefaultLength.IntValue);
			return Plugin_Handled;
		}
		
		KB_RestrictPlayer(target, client, time);
		return Plugin_Handled;
	}
		
	if(!CheckCommandAccess(client, "sm_rcon", ADMFLAG_RCON, true) && time == 0)
	{	
		KB_RestrictPlayer(target, client, g_cvDefaultLength.IntValue, Arguments[len]);
		return Plugin_Handled;
	}
	
	KB_RestrictPlayer(target, client, time, Arguments[len]);
	return Plugin_Handled;
}

//----------------------------------------------------------------------------------------------------
// Commands :
//----------------------------------------------------------------------------------------------------
public Action Command_KbUnRestrict(int client, int args)
{
	if(args < 1)
	{
		Display_MainKbRestrictList_Menu(client);
		CReplyToCommand(client, "%s Usage: sm_kunban <player> <reason>.", KB_Tag);
		return Plugin_Handled;
	}
	
	char Arguments[256], arg[50];
	GetCmdArgString(Arguments, sizeof(Arguments));
	
	int len;
	len = BreakString(Arguments, arg, sizeof(arg));
	if(len == -1)
    {
        len = 0;
        Arguments[0] = '\0';
    }

	int target = FindTarget(client, arg, false, false);
	char AdminSteamID[32];
	
	if(!IsValidClient(target))
		return Plugin_Handled;
	
	if(!g_bIsClientRestricted[target])
	{
		if(!client)
		{
			ReplyToCommand(client, "The specified target is already kb-unrestricted.");
			return Plugin_Handled;
		}
		
		CReplyToCommand(client, "%s %T", KB_Tag, "AlreadyKUnbanned", client);
		return Plugin_Handled;
	}
	
	if(client <= 0)
		AdminSteamID = "Console";
	else
	{
		if(!GetClientAuthId(client, AuthId_Steam2, AdminSteamID, sizeof(AdminSteamID)))
			return Plugin_Handled;
	}
	
	if(!CheckCommandAccess(client, "sm_koban", ADMFLAG_RCON, true) && !StrEqual(AdminSteamID, g_PlayerData[target].AdminSteamID, false))
	{
		CReplyToCommand(client, "%s %T", KB_Tag, "NotOwnBan", client);
		return Plugin_Handled;
	}

	if(args < 2)
	{
		KB_UnRestrictPlayer(target, client);
		return Plugin_Handled;
	}
	
	KB_UnRestrictPlayer(target, client, Arguments[len]);
	return Plugin_Handled;
}

//----------------------------------------------------------------------------------------------------
// Commands :
//----------------------------------------------------------------------------------------------------
public Action Command_OfflineKbRestrict(int client, int args)
{
	if(args < 4)
	{
		CReplyToCommand(client, "%s Usage: sm_koban \"<steamid>\" <playername> <time> <reason>", KB_Tag);
		return Plugin_Handled;
	}

	char Arguments[256], arg[50], playerName[32], s_time[20];
	GetCmdArgString(Arguments, sizeof(Arguments));
	
	int len, next_len1, next_len2;
	len = BreakString(Arguments, arg, sizeof(arg));
	if(len == -1)
    {
        len = 0;
        Arguments[0] = '\0';
    }
	
	if((next_len1 = BreakString(Arguments[len], playerName, sizeof(playerName))) != -1)
        len += next_len1;
	else
    {
        len = 0;
        Arguments[0] = '\0';
    }
	
	if((next_len2 = BreakString(Arguments[len], s_time, sizeof(s_time))) != -1)
		len += next_len2;
	else
	{
		len = 0;
		Arguments[0] = '\0';
	}
	
	int time;
	if(!StringToIntEx(s_time, time))
		time = g_cvDefaultLength.IntValue;
	
	if(StrEqual(playerName, ""))
	{
		if(!client)
		{
			ReplyToCommand(client, "Please put the steamid between quotes");
			return Plugin_Handled;
		}
		
		CReplyToCommand(client, "%s %T", KB_Tag, "SteamID quotes", client);
		return Plugin_Handled;
	}
	
	if(!CheckCommandAccess(client, "sm_koban", ADMFLAG_RCON, true))
	{
		if(time <= 0)
			time = g_cvDefaultLength.IntValue;
		else if(time > g_cvAddBanLength.IntValue)
			time = g_cvAddBanLength.IntValue;
	}
	else
	{
		if(time < 0)
			time = g_cvDefaultLength.IntValue;
	}
	
	int target = GetPlayerFromSteamID(arg);
	if(target != -1)
	{
		if(g_bIsClientRestricted[target])
		{
			if(!client)
			{
				ReplyToCommand(client, "The specified target is already kb-restricted.");
				return Plugin_Handled;
			}
			
			CReplyToCommand(client, "%s %T", KB_Tag, "AlreadyKBanned", client);
			return Plugin_Handled;
		}
		
		KB_RestrictPlayer(target, client, time, Arguments[len]);
		return Plugin_Handled;
	}
	else if(target == -1)
	{
		KB_AddOfflineBanCheck(arg, playerName, client, time, Arguments[len]);
		return Plugin_Handled;
	}
	
	return Plugin_Handled;
}

// MENUS RELATED STUFFS

// Top menu
//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------

public void OnAdminMenuReady(Handle aTopMenu)
{
	TopMenu topmenu = TopMenu.FromHandle(aTopMenu);
	
	if(g_hAdminMenu == topmenu)
		return;
	
	g_hAdminMenu = topmenu;
	
	TopMenuObject hMenuObj = g_hAdminMenu.AddCategory("KbRestrictCommands", CategoryHandler, "sm_koban", ADMFLAG_BAN);

	if(hMenuObj == INVALID_TOPMENUOBJECT)
		return;
		
	g_hAdminMenu.AddItem("KbRestrict_RestrictPlayer", ItemHandler_RestrictPlayer, hMenuObj, "sm_koban", ADMFLAG_BAN);
	g_hAdminMenu.AddItem("KbRestrict_ListOfKbans", ItemHandler_ListOfKbans, hMenuObj, "sm_koban", ADMFLAG_RCON);
	g_hAdminMenu.AddItem("KbRestrict_OnlineKBanned", ItemHandler_OnlineKBanned, hMenuObj, "sm_koban", ADMFLAG_BAN);
	g_hAdminMenu.AddItem("KbRestrict_OwnBans", ItemHandler_OwnBans, hMenuObj, "sm_koban", ADMFLAG_BAN);
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void CategoryHandler(TopMenu topmenu, 
      TopMenuAction action,
      TopMenuObject object_id,
      int param,
      char[] buffer,
      int maxlength)
{
	if(action == TopMenuAction_DisplayTitle)
	{
		strcopy(buffer, maxlength, "KbRestrict Commands Main Menu");
	}
	else if(action == TopMenuAction_DisplayOption)
	{
		strcopy(buffer, maxlength, "KbRestrict Commands");
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ItemHandler_RestrictPlayer(TopMenu topmenu, 
      TopMenuAction action,
      TopMenuObject object_id,
      int param,
      char[] buffer,
      int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		strcopy(buffer, maxlength, "KBan a Player");
	}
	else if(action == TopMenuAction_SelectOption)
	{
		DisplayKBan_Menu(param, .mode=MenuMode_RestrictPlayer);
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ItemHandler_ListOfKbans(TopMenu topmenu, 
      TopMenuAction action,
      TopMenuObject object_id,
      int param,
      char[] buffer,
      int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		strcopy(buffer, maxlength, "List of KBans");
	}
	else if(action == TopMenuAction_SelectOption)
	{
		if(CheckCommandAccess(param, "sm_koban", ADMFLAG_RCON, true))
		{
			DisplayKBan_Menu(param, .mode=MenuMode_AllBans);				
		}
		else
		{
			CPrintToChat(param, "%s You don't have access to view the KBan List.", KB_Tag);
		}
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ItemHandler_OnlineKBanned(TopMenu topmenu, 
      TopMenuAction action,
      TopMenuObject object_id,
      int param,
      char[] buffer,
      int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		strcopy(buffer, maxlength, "Online KBanned");
	}
	else if(action == TopMenuAction_SelectOption)
	{
		DisplayKBan_Menu(param, .mode=MenuMode_OnlineBans);
	}
}

//----------------------------------------------------------------------------------------------------
// Purpose:
//----------------------------------------------------------------------------------------------------
public void ItemHandler_OwnBans(TopMenu topmenu, 
      TopMenuAction action,
      TopMenuObject object_id,
      int param,
      char[] buffer,
      int maxlength)
{
	if(action == TopMenuAction_DisplayOption)
	{
		strcopy(buffer, maxlength, "Your Own List of KBans");
	}
	else if(action == TopMenuAction_SelectOption)
	{
		DisplayKBan_Menu(param, .mode=MenuMode_OwnBans);
	}
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------		
stock void Display_MainKbRestrictList_Menu(int client)
{
	Menu menu = new Menu(Menu_KbRestrictList);
	menu.SetTitle("[Kb-Restrict] Kban Main Menu");
	menu.ExitBackButton = true;
	
	menu.AddItem("0", "Kban a Player");
	menu.AddItem("1", "List of Kbans", CheckCommandAccess(client, "sm_koban", ADMFLAG_RCON, true) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("2", "Online KBanned");
	menu.AddItem("3", "Your Own List of Kbans");
	
	menu.Display(client, MENU_TIME_FOREVER);
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
public int Menu_KbRestrictList(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		
		case MenuAction_Select:
		{
			switch(param2)
			{
				case 0:
					DisplayKBan_Menu(param1, .mode=MenuMode_RestrictPlayer);
				case 1:
					DisplayKBan_Menu(param1, .mode=MenuMode_AllBans);
				case 2:
					DisplayKBan_Menu(param1, .mode=MenuMode_OnlineBans);
				case 3:
					DisplayKBan_Menu(param1, .mode=MenuMode_OwnBans);
			}
		}
	}
	
	return 0;
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
stock void DisplayKBan_Menu(int client, int mode)
{
	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
		
	Menu menu;
	if(mode == MenuMode_RestrictPlayer || mode == MenuMode_OnlineBans)	
		menu = new Menu(Menu_KbanHandler);
		
	switch(mode)
	{
		case MenuMode_RestrictPlayer:
		{
			menu.SetTitle("[Kb-Restrict] Restrict a Player");
			for(int target = 1; target <= MaxClients; target++)
			{
				if(IsValidClient(target) && !g_bIsClientRestricted[target])
				{
					char MenuBuffer[32], MenuText[128], ClientTeam[32];
					Format(MenuBuffer, sizeof(MenuBuffer), "0|%d", GetClientUserId(target));
					FormatClientTeam(target, ClientTeam, sizeof(ClientTeam));
					Format(MenuText, sizeof(MenuText), "%N [%s]", target, ClientTeam);
					menu.AddItem(MenuBuffer, MenuText);
				}
			}
			
			menu.ExitBackButton = true;
			menu.Display(client, MENU_TIME_FOREVER);
			return;
		}
		
		case MenuMode_AllBans:
		{
			DB_AddAllBansToMenu(client);
			return;
		}
		
		case MenuMode_OnlineBans:
		{
			menu.SetTitle("[Kb-Restrict] Online KBans");
			if(GetCurrent_KbRestrict_Players() >= 1)
			{
				for(int target = 1; target <= MaxClients; target++)
				{
					if(IsValidClient(target) && g_bIsClientRestricted[target])
					{
						char MenuBuffer[32], MenuText[128], ClientTeam[32];
						Format(MenuBuffer, sizeof(MenuBuffer), "2|%d", GetClientUserId(target));
						FormatClientTeam(target, ClientTeam, sizeof(ClientTeam));
						Format(MenuText, sizeof(MenuText), "%N [%s]", target, ClientTeam);
						menu.AddItem(MenuBuffer, MenuText);
					}
				}
			}
			else if(GetCurrent_KbRestrict_Players() <= 0)
				menu.AddItem("", "No KBan", ITEMDRAW_DISABLED);
				
			menu.ExitBackButton = true;
			menu.Display(client, MENU_TIME_FOREVER);
			return;
		}

		case MenuMode_OwnBans:
		{
			DB_AddAdminBansToMenu(client);
			return;
		}
	}
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
public int Menu_KbanHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				Display_MainKbRestrictList_Menu(param1);
		}
		
		case MenuAction_Select:
		{
			char buffer[128];
			menu.GetItem(param2, buffer, sizeof(buffer));
			
			char ExBuffer[2][128];
			ExplodeString(buffer, "|", ExBuffer, 2, sizeof(ExBuffer[]), true);
			int num = StringToInt(ExBuffer[0]);
			int userid = StringToInt(ExBuffer[1]);
			int target = GetClientOfUserId(userid);

			if(!target)
				return 0;

			if(num == 0)
			{
				g_iClientTargets[param1] = userid;
				DisplayLengths_Menu(param1);
			}
			
			if(num == 2)
				KB_ShowBanDetails(param1, target);
		}
	}
	
	return 0;
}
		
stock void DB_AddAllBansToMenu(int client)
{
	if(g_hDB == null)
		return;
		
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_name`, `client_steamid` FROM `KbRestrict_CurrentBans` WHERE server_ip='%s'", ServerIP);
	SQL_TQuery(g_hDB, SQL_AddAllBansToMenu, sQuery, GetClientUserId(client));
}

public void SQL_AddAllBansToMenu(Handle hDatabase, Handle hResults, const char[] sError, int userid)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("Error: %s", sError);
		
	int client = GetClientOfUserId(userid);

	if(client < 1)
		return;

	if(!IsClientInGame(client))
		return;

	if(hResults == null)
		return;
	
	Menu menu = new Menu(Menu_AllBansHandler);
	menu.SetTitle("[Kb-Restrict] All KBans");
	menu.ExitBackButton = true;
	
	int icount = 0;
	while(SQL_FetchRow(hResults))
	{
		char TargetName[32], TargetSteamID[32], MenuBuffer[64], MenuText[128], ClientTeam[32];
		SQL_FetchString(hResults, 0, TargetName, sizeof(TargetName));
		SQL_FetchString(hResults, 1, TargetSteamID, sizeof(TargetSteamID));
		
		int target = GetPlayerFromSteamID(TargetSteamID);
		if(target != -1)
			FormatClientTeam(target, ClientTeam, sizeof(ClientTeam));
			
		Format(MenuBuffer, sizeof(MenuBuffer), "%s", TargetSteamID);
		Format(MenuText, sizeof(MenuText), "%s [%s][%s]", TargetName, TargetSteamID, (target == -1) ? "Offline" : ClientTeam);	
		
		menu.AddItem(MenuBuffer, MenuText);
		icount++;
	}
	if(icount <= 0)
		menu.AddItem("", "No KBan", ITEMDRAW_DISABLED);
		
	menu.Display(client, MENU_TIME_FOREVER);
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
public int Menu_AllBansHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				Display_MainKbRestrictList_Menu(param1);
		}
		
		case MenuAction_Select:
		{
			char buffer[128];
			menu.GetItem(param2, buffer, sizeof(buffer));
			
			KB_AddActionsFromDBToMenu(param1, buffer, .mode=MenuMode_AllBans);
		}
	}
	
	return 0;
}

stock void KB_ShowBanDetails(int client, int target)
{
	if(!g_bIsClientRestricted[target])
		return;
	
	if(g_PlayerData[target].BanDuration == -1) // player kbanned temporarily
	{
		Menu menu = new Menu(Menu_ActionsHandler);
		char sTitle[124], MenuText[124], MenuBuffer[32];
		Format(sTitle, sizeof(sTitle), "KBan Details for %N", target);
		menu.SetTitle(sTitle);
		menu.ExitBackButton = true;		
		IntToString(GetClientUserId(target), MenuBuffer, sizeof(MenuBuffer));
		
		Format(MenuText, sizeof(MenuText), "Player Name : %N", target);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Admin Name : %s", g_PlayerData[target].AdminName);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Reason : %s", g_PlayerData[target].Reason);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Duration : Temporary");
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		menu.AddItem(MenuBuffer, "Kb-UnRestrict Player");
		
		menu.Display(client, MENU_TIME_FOREVER);
	}
	else
	{
		char SteamID[32];
		if(!GetClientAuthId(target, AuthId_Steam2, SteamID, sizeof(SteamID)))
			return;
			
		KB_AddActionsFromDBToMenu(client, SteamID, .mode=MenuMode_OnlineBans);
	}
}

public int Menu_ActionsHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayKBan_Menu(param1, .mode=MenuMode_OnlineBans);
		}
		
		case MenuAction_Select:
		{
			char buffer[32];
			menu.GetItem(param2, buffer, sizeof(buffer));
			int target = GetClientOfUserId(StringToInt(buffer));

			if(!target)
				return 0;

			if(!IsValidClient(target))
				CPrintToChat(param1, "%s %T", KB_Tag, "PlayerNotValid", param1);
			
			if(g_bIsClientRestricted[target])
				KB_UnRestrictPlayer(target, param1);
			else
				CPrintToChat(param1, "%s %T", KB_Tag, "AlreadyKUnbanned", param1);
				
			DisplayKBan_Menu(param1, .mode=MenuMode_OnlineBans);
		}
	}
	
	return 0;
}

stock void KB_AddActionsFromDBToMenu(int client, const char[] SteamID, int mode)
{
	if(g_hDB == null)
		return;
	
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_name`, `admin_name`, `admin_steamid`, `reason`, `map`, `length`, `time_stamp_start`, `time_stamp_end`"
											... "FROM `KbRestrict_CurrentBans` WHERE client_steamid='%s' and server_ip='%s'", SteamID, ServerIP);
	
	g_iClientMenuMode[client] = mode;
	DataPack pack = new DataPack();
	SQL_TQuery(g_hDB, SQL_AddActionsFromDBToMenu, sQuery, pack);
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(SteamID);
}

public void SQL_AddActionsFromDBToMenu(Handle hDatabase, Handle hResults, const char[] sError, DataPack pack)
{
	char SteamID[32];
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	pack.ReadString(SteamID, sizeof(SteamID));
	delete pack;

	if(!client)
		return;

	if(!IsClientInGame(client))
		return;
	
	if(hResults == null)
		return;
	
	Menu menu = new Menu(Menu_ActionsHandlerAll);
	char sTitle[124];
	Format(sTitle, sizeof(sTitle), "KBan Details for [%s]", SteamID);
	menu.SetTitle(sTitle);
	menu.ExitBackButton = true;
	
	char MenuBuffer[124], MenuText[256];
	char Name[32], AdminName[32], AdminSteamID[32], Reason[124], Map[124];
	char sDateStart[128], sDateEnd[128], sTimeLeft[128];
	int length, time_stamp_start, time_stamp_end;
	bool bIsBanned = false;
	
	while(SQL_FetchRow(hResults))
	{
		SQL_FetchString(hResults, 0, Name, sizeof(Name));
		SQL_FetchString(hResults, 1, AdminName, sizeof(AdminName));
		SQL_FetchString(hResults, 2, AdminSteamID, sizeof(AdminSteamID));
		SQL_FetchString(hResults, 3, Reason, sizeof(Reason));
		SQL_FetchString(hResults, 4, Map, sizeof(Map));
		
		length = SQL_FetchInt(hResults, 5);
		time_stamp_start = SQL_FetchInt(hResults, 6);
		time_stamp_end = SQL_FetchInt(hResults, 7);
		
		FormatTime(sDateStart, sizeof(sDateStart), "%d %B %G @ %r", time_stamp_start);
		FormatTime(sDateEnd, sizeof(sDateEnd), "%d %B %G @ %r", time_stamp_end);
		
		Format(MenuText, sizeof(MenuText), "Player Name : %s", Name);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Player SteamID : %s", SteamID);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Admin Name : %s", AdminName);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Admin SteamID : %s", AdminSteamID);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Reason : %s", Reason);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Map : %s", Map);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		
		length == 0 ? Format(MenuText, sizeof(MenuText), "Duration : Permanent") :
		Format(MenuText, sizeof(MenuText), "Duration : %d Minutes", length);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Date Issued : %s", sDateStart);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Date End : %s", length == 0 ? "Never" : sDateEnd);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		int timeleft = (time_stamp_end - GetTime());
		CheckPlayerExpireTime(timeleft, sTimeLeft, sizeof(sTimeLeft));
		Format(MenuText, sizeof(MenuText), "Expire Time : %s", length == 0 ? "Never" : sTimeLeft);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		
		bIsBanned = true;
	}
	if(bIsBanned)
	{
		Format(MenuBuffer, sizeof(MenuBuffer), "%s|%s", Name, SteamID);	
		char sAdminSteamID[32];
		if(!GetClientAuthId(client, AuthId_Steam2, sAdminSteamID, sizeof(sAdminSteamID)))
			return;
			
		bool bCanUnban = false;
		if(StrEqual(AdminSteamID, sAdminSteamID, false) || CheckCommandAccess(client, "sm_koban", ADMFLAG_RCON, true))
			bCanUnban = true;
			
		menu.AddItem(MenuBuffer, "Kb-UnRestrict Player", (bCanUnban) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	}
	
	menu.Display(client, MENU_TIME_FOREVER);	
}

public int Menu_ActionsHandlerAll(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayKBan_Menu(param1, g_iClientMenuMode[param1]);		
		}
		
		case MenuAction_Select:
		{
			char buffer[256];
			menu.GetItem(param2, buffer, sizeof(buffer));
			char ExBuffers[2][128];
			ExplodeString(buffer, "|", ExBuffers, 2, sizeof(ExBuffers[]), true);
			// ExBuffers[0] = name, ExBuffers[1] = SteamID
			
			int target = GetPlayerFromSteamID(ExBuffers[1]);
			if(target == -1)
			{
				KB_RemoveBanFromDB(ExBuffers[1]);
				CPrintToChat(param1, "%s %T", KB_Tag, "SteamIDKUnban", param1, ExBuffers[0], ExBuffers[1]);
			}
			else
			{
				if(g_bIsClientRestricted[target])
					KB_UnRestrictPlayer(target, param1);
				else
					CPrintToChat(param1, "%s %T", KB_Tag, "AlreadyKUnbanned", param1);
			}
				
			DisplayKBan_Menu(param1, g_iClientMenuMode[param1]);
		}
	}
	
	return 0;
}

stock void DB_AddAdminBansToMenu(int client)
{
	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
	
	if(g_hDB == null)
		return;
	
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_name`, `client_steamid`"
											... "FROM `KbRestrict_CurrentBans` WHERE admin_steamid='%s' and server_ip='%s'", SteamID, ServerIP);
							
	SQL_TQuery(g_hDB, SQL_AddAdminBansToMenu, sQuery, GetClientUserId(client));
}

public void SQL_AddAdminBansToMenu(Handle hDatabase, Handle hResults, const char[] sError, int userid)
{
	if(sError[0] && g_hCVar_Debug.IntValue >= 1)
		LogError("Error: %s", sError);
		
	int client = GetClientOfUserId(userid);

	if(!client)
		return;

	if(!IsClientInGame(client))
		return;
	
	if(hResults == null)
		return;
		
	Menu menu = new Menu(Menu_AdminBansHandler);
	menu.SetTitle("[Kb-Restrict] Your own KBans");
	menu.ExitBackButton = true;
	
	char ClientName[32], ClientSteamID[32], MenuBuffer[32], MenuText[124], ClientTeam[32];
	int icount = 0;
	while(SQL_FetchRow(hResults))
	{
		SQL_FetchString(hResults, 0, ClientName, sizeof(ClientName));
		SQL_FetchString(hResults, 1, ClientSteamID, sizeof(ClientSteamID));
		
		Format(MenuBuffer, sizeof(MenuBuffer), "%s", ClientSteamID);
		int target = GetPlayerFromSteamID(ClientSteamID);
		if(target != -1)
			FormatClientTeam(target, ClientTeam, sizeof(ClientTeam));
			
		Format(MenuText, sizeof(MenuText), "%s[%s][%s]", ClientName, ClientSteamID, (target == -1) ? "Offline" : ClientTeam);
		menu.AddItem(MenuBuffer, MenuText);
		icount++;
	}
	if(icount <= 0)
		menu.AddItem("", "No KBan", ITEMDRAW_DISABLED);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_AdminBansHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				Display_MainKbRestrictList_Menu(param1);
		}
		
		case MenuAction_Select:
		{
			char buffer[32];
			menu.GetItem(param2, buffer, sizeof(buffer));
			DB_AddAdminBansActionsToMenu(param1, buffer);
		}
	}
	
	return 0;
}
				
stock void DB_AddAdminBansActionsToMenu(int client, const char[] TargetSteamID)
{
	char SteamID[32];
	if(!GetClientAuthId(client, AuthId_Steam2, SteamID, sizeof(SteamID)))
		return;
	
	if(g_hDB == null)
		return;
	
	char sQuery[1024];
	g_hDB.Format(sQuery, sizeof(sQuery), "SELECT `client_name`, `reason`, `map`, `length`, `time_stamp_start`, `time_stamp_end`"
											... "FROM `KbRestrict_CurrentBans` WHERE admin_steamid='%s' and client_steamid='%s' and server_ip='%s'", SteamID, TargetSteamID, ServerIP);
			
	DataPack pack = new DataPack();
	SQL_TQuery(g_hDB, SQL_AddAdminBansActionsToMenu, sQuery, pack);
	pack.WriteCell(GetClientUserId(client));
	pack.WriteString(TargetSteamID);
}

public void SQL_AddAdminBansActionsToMenu(Handle hDatabase, Handle hResults, const char[] sError, DataPack pack)
{
	pack.Reset();
	int client = GetClientOfUserId(pack.ReadCell());
	char TargetSteamID[32];
	pack.ReadString(TargetSteamID, sizeof(TargetSteamID));
	delete pack;

	if(!client)
		return;

	if(!IsClientInGame(client))
		return;
	
	if(hResults == null)
		return;
	
	Menu menu = new Menu(Menu_AdminBansActionsHandler);
	char sTitle[124];
	Format(sTitle, sizeof(sTitle), "KBan Details for [%s]", TargetSteamID);
	menu.SetTitle(sTitle);
	menu.ExitBackButton = true;
	
	char MenuBuffer[124], MenuText[256];
	char TargetName[32], Reason[124], Map[124];
	char sDateStart[128], sDateEnd[128], sTimeLeft[128];
	int length, time_stamp_start, time_stamp_end;
	
	bool bIsBanned = false;
	while(SQL_FetchRow(hResults))
	{
		SQL_FetchString(hResults, 0, TargetName, sizeof(TargetName));
		SQL_FetchString(hResults, 1, Reason, sizeof(Reason));
		SQL_FetchString(hResults, 2, Map, sizeof(Map));
		
		length = SQL_FetchInt(hResults, 3);
		time_stamp_start = SQL_FetchInt(hResults, 4);
		time_stamp_end = SQL_FetchInt(hResults, 5);
		
		FormatTime(sDateStart, sizeof(sDateStart), "%d %B %G @ %r", time_stamp_start);
		FormatTime(sDateEnd, sizeof(sDateEnd), "%d %B %G @ %r", time_stamp_end);
		
		Format(MenuText, sizeof(MenuText), "Player Name : %s", TargetName);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Player SteamID : %s", TargetSteamID);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Admin Name : %s", "Your Own Ban");
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Reason : %s", Reason);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Map : %s", Map);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		
		length == 0 ? Format(MenuText, sizeof(MenuText), "Duration : Permanent") :
		Format(MenuText, sizeof(MenuText), "Duration : %d Minutes", length);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Date Issued : %s", sDateStart);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		Format(MenuText, sizeof(MenuText), "Date End : %s", length == 0 ? "Never" : sDateEnd);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		
		int timeleft = (time_stamp_end - GetTime());
		CheckPlayerExpireTime(timeleft, sTimeLeft, sizeof(sTimeLeft));
		Format(MenuText, sizeof(MenuText), "Expire Time : %s", length == 0 ? "Never" : sTimeLeft);
		menu.AddItem("", MenuText, ITEMDRAW_DISABLED);
		
		bIsBanned = true;
	}
	if(bIsBanned)
	{
		Format(MenuBuffer, sizeof(MenuBuffer), "%s|%s", TargetName, TargetSteamID);	
		char sTitle2[124];
		Format(sTitle2, sizeof(sTitle2), "KBan Details for %s[%s]", TargetName, TargetSteamID);
		menu.SetTitle(sTitle2);
		menu.AddItem(MenuBuffer, "Kb-UnRestrict Player");
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Menu_AdminBansActionsHandler(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
		
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayKBan_Menu(param1, .mode=MenuMode_OwnBans);		
		}
		
		case MenuAction_Select:
		{
			char buffer[256];
			menu.GetItem(param2, buffer, sizeof(buffer));
			char ExBuffers[2][128];
			ExplodeString(buffer, "|", ExBuffers, 2, sizeof(ExBuffers[]), true);
			// ExBuffers[0] = name, ExBuffers[1] = SteamID
			
			int target = GetPlayerFromSteamID(ExBuffers[1]);
			if(target == -1)
			{
				KB_RemoveBanFromDB(ExBuffers[1]);
				CPrintToChat(param1, "%s %T", KB_Tag, "SteamIDKUnban", param1, ExBuffers[0], ExBuffers[1]);
			}
			else
			{
				if(g_bIsClientRestricted[target])
					KB_UnRestrictPlayer(target, param1);
				else
					CPrintToChat(param1, "%s %T", KB_Tag, "AlreadyKUnbanned", param1);
			}
				
			DisplayKBan_Menu(param1, .mode=MenuMode_OwnBans);
		}
	}
	
	return 0;
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
stock void DisplayLengths_Menu(int client)
{
	Menu menu = new Menu(Menu_KbRestrict_Lengths);
	menu.SetTitle("[Kb-Restrict] KBan Duration");
	menu.ExitBackButton = true;
	
	char LengthBufferP[64], LengthBufferT[64];
	FormatEx(LengthBufferP, sizeof(LengthBufferP), "%s", "Permanently");
	FormatEx(LengthBufferT, sizeof(LengthBufferT), "%s", "Temporary");

	menu.AddItem("0", LengthBufferP, CheckCommandAccess(client, "sm_koban", ADMFLAG_RCON, true) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("-1", LengthBufferT);
	
	for(int i = 15; i >= 15 && i < 241920; i++)
	{
		if(i == 15 || i == 30 || i == 45)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			FormatEx(text, sizeof(text), "%d %s", i, "Minutes");
			menu.AddItem(buffer, text);
		}
		else if(i == 60)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int hour = (i / 60);
			FormatEx(text, sizeof(text), "%d %s", hour, "Hour");
			menu.AddItem(buffer, text);
		}
		else if(i == 120 || i == 240 || i == 480 || i == 720)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int hour = (i / 60);
			FormatEx(text, sizeof(text), "%d %s", hour, "Hours");
			menu.AddItem(buffer, text);
		}
		else if(i == 1440)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int day = (i / 1440);
			FormatEx(text, sizeof(text), "%d %s", day, "Day");
			menu.AddItem(buffer, text);
		}
		else if(i == 2880 || i == 4320 || i == 5760 || i == 7200 || i == 8640)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int day = (i / 1440);
			FormatEx(text, sizeof(text), "%d %s", day, "Days");
			menu.AddItem(buffer, text);
		}
		else if(i == 10080)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int week = (i / 10080);
			FormatEx(text, sizeof(text), "%d %s", week, "Week");
			menu.AddItem(buffer, text);
		}
		else if(i == 20160 || i == 30240)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int week = (i / 10080);
			FormatEx(text, sizeof(text), "%d %s", week, "Weeks");
			menu.AddItem(buffer, text);
		}
		else if(i == 40320)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int month = (i / 40320);
			FormatEx(text, sizeof(text), "%d %s", month, "Month");
			menu.AddItem(buffer, text);
		}
		else if(i == 80640 || i == 120960 || i == 241920)
		{
			char buffer[32], text[32];
			IntToString(i, buffer, sizeof(buffer));
			int month = (i / 40320);
			FormatEx(text, sizeof(text), "%d %s", month, "Months");
			menu.AddItem(buffer, text);
		}
	}
	
	menu.Display(client, MENU_TIME_FOREVER);
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
public int Menu_KbRestrict_Lengths(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
			delete menu;
			
		case MenuAction_Cancel:
		{
			if(param2 == MenuCancel_ExitBack)
				DisplayKBan_Menu(param1, .mode=MenuMode_RestrictPlayer);
		}
		
		case MenuAction_Select:
		{		
			char buffer[64];
			menu.GetItem(param2, buffer, sizeof(buffer));
			int time = StringToInt(buffer);
			int target = GetClientOfUserId(g_iClientTargets[param1]);

			if(!target)
				return 0;
	
			if(IsValidClient(target))
			{
				g_iClientTargetsLength[param1] = time;
				DisplayReasons_Menu(param1);
			}
		}
	}
	
	return 0;
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
stock void DisplayReasons_Menu(int client)
{
	Menu menu = new Menu(Menu_Reasons);
	char sMenuTranslate[128];
	FormatEx(sMenuTranslate, sizeof(sMenuTranslate), "[Kb-Restrict] Please Select a Reason");
	menu.SetTitle(sMenuTranslate);
	menu.ExitBackButton = true;
	
	char sBuffer[128];
	
	FormatEx(sBuffer, sizeof(sBuffer), "%s", "Boosting", client);
	menu.AddItem(sBuffer, sBuffer);
	
	FormatEx(sBuffer, sizeof(sBuffer), "%s", "TryingToBoost", client);
	menu.AddItem(sBuffer, sBuffer);

	FormatEx(sBuffer, sizeof(sBuffer), "%s", "Trimming team", client);
	menu.AddItem(sBuffer, sBuffer);

	FormatEx(sBuffer, sizeof(sBuffer), "%s", "Trolling on purpose", client);
	menu.AddItem(sBuffer, sBuffer);
	
	FormatEx(sBuffer, sizeof(sBuffer), "%s", "Custom Reason", client);
	menu.AddItem("4", sBuffer);
	
	menu.Display(client, MENU_TIME_FOREVER);
}

//----------------------------------------------------------------------------------------------------
// Menu :
//----------------------------------------------------------------------------------------------------
public int Menu_Reasons(Menu menu, MenuAction action, int param1, int param2)
{
	switch(action)
	{
		case MenuAction_End:
		{
			g_bIsClientTypingReason[param1] = false;
			delete menu;
		}
		
		case MenuAction_Cancel:
		{		
			if(param2 == MenuCancel_ExitBack)
			{
				g_bIsClientTypingReason[param1] = false;

				int target = GetClientOfUserId(g_iClientTargets[param1]);

				if(!target)
					return 0;

				if(IsValidClient(target))
					DisplayLengths_Menu(param1);
				else
					CPrintToChat(param1, "%s %T", KB_Tag, "PlayerNotValid", param1);
			}
		}
		
		case MenuAction_Select:
		{
			int target = GetClientOfUserId(g_iClientTargets[param1]);
			if(!target)
					return 0;
					
			if(param2 == 4)
			{			
				if(IsValidClient(target))
				{
					if(!g_bIsClientRestricted[target])
					{
						CPrintToChat(param1, "%s %T.", KB_Tag, "ChatReason", param1);
						g_bIsClientTypingReason[param1] = true;
					}
					else
						CPrintToChat(param1, "%s %T.", KB_Tag, "AlreadyKBanned", param1);
				}
				else
					CPrintToChat(param1, "%s %T", KB_Tag, "PlayerNotValid", param1);
			}
			else
			{
				char buffer[128];
				menu.GetItem(param2, buffer, sizeof(buffer));
				
				if(IsValidClient(target))
					KB_RestrictPlayer(target, param1, g_iClientTargetsLength[param1], buffer);
			}
		}
	}
	
	return 0;
}

// End :)
