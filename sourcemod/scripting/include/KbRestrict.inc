// *************************************************************************
// This is the include file for KbRestrict
//
// To check that KbRestrict is installed and running.
// It will verify that the "KbRestrict" library exists
//
// *************************************************************************

#if defined _KbRestrict_included_
  #endinput
#endif
#define _KbRestrict_included_

public SharedPlugin __pl_KnifeBan = 
{
	name = "KbRestrict",
	file = "KbRestrict.smx",
#if defined REQUIRE_PLUGIN
	required = 1
#else
	required = 0
#endif
}

#if !defined REQUIRE_PLUGIN
public void __pl_kbrestrict_SetNTVOptional()
{
	MarkNativeAsOptional("KB_BanClient");
	MarkNativeAsOptional("KB_UnBanClient");
	MarkNativeAsOptional("KB_ClientStatus");
}
#endif

/*********************************************************
 * KbRestrict the target
 *
 * @param admin 	Admin Index
 * @param target	Target Index
 * @param time      Ban's length
 * @param sReason   Reason
*********************************************************/
native void KB_BanClient(int iadmin, int itarget, int itime, const char[] ssReason);

/*********************************************************
 * KbUnRestrict the target
 *
 * @param client 	Client Index
 * @param target	Target Index
 * @param sReason   Reason
 *********************************************************/
native void KB_UnBanClient(int iadmin, int itarget, char[] ssReason);

/*********************************************************
 * Check if client is restricted
 * 
 * @return 	true if client is restricted, false otherwise
 *********************************************************/
native bool KB_ClientStatus(int client);
