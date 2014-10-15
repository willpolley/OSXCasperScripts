#!/bin/bash
#
#
# Filevault Helper
#
#
# FVHelper leverages Casper's built FV handling (so we can use the GUI and key escrow)
# - adds some GUI
# - allows you to skip a management account(s)
# - call it at login trigger so we don't forget to enable FV
# - execute it via self service and it will logout for you

skipusers=( "admin" ) 		# prevent these users from being prompted (your local management accounts etc.)
fvpolicy="-id 1234"			# use either the policy id or a custom trigger of your FV policy.
#fvpolicy="-trigger filevault"
fvhelperreceipt="/Library/Application Support/JAMF/Receipts/FVHelper"

spawned="${1}" # used internally
username="${3}"

dialogicon="System:Library:CoreServices:CoreTypes.bundle:Contents:Resources:FileVaultIcon.icns"

checkProcess()
{
	if [ "$(ps aux | grep "${1}" | grep -v grep)" != "" ]
	then
		return 0
	else
		return 1
	fi
}

checkConsoleStatus()
{
	userloggedin="$(who | grep console | awk '{print $1}')"
	consoleuser="$(ls -l /dev/console | awk '{print $3}')"
	screensaver="$(ps aux | grep ScreenSaverEngine | grep -v grep)"

	if [ "${screensaver}" != "" ]
	then
		# screensaver is running
		echo "screensaver"
		return
	fi
	
	if [ "${userloggedin}" == "" ]
	then
		# no users logged in (at loginwindow)
		echo "nologin"
		return
	fi
	
	if [ "${userloggedin}" != "${consoleuser}" ]
	then
		# a user is loggedin, but we are at loginwindow or we have multiple users logged in with switching (too hard for now)
		echo "loginwindow"
		return
	fi

	# if we passed all checks, user is logged in and we are safe to prompt or display bubbles
	echo "userloggedin"
}


logoutUser()
{
	waitforlogout=30
	# sending appleevent seems most robust and fastest way, can still be blocked by stuck app (I'm looking at you MS Office and Lync)
	echo "sending logout ..."
	osascript -e "ignoring application responses" -e "tell application \"loginwindow\" to $(printf \\xc2\\xab)event aevtrlgo$(printf \\xc2\\xbb)" -e "end ignoring"

	while [ "$(checkConsoleStatus)" != "nologin" ]
	do
		for (( c=1; c<=${waitforlogout}; c++ ))
		do
			sleep 1
			# check if we've logged out yet, break if so, otherwise check every second
			[ "$(checkConsoleStatus)" == "nologin" ] && break
		done
		if [ "$(checkConsoleStatus)" != "nologin" ]
		then
			osascript -e "ignoring application responses" -e "tell application \"loginwindow\" to $(printf \\xc2\\xab)event aevtrlgo$(printf \\xc2\\xbb)" -e "end ignoring"
		fi
	done
	# we should have really logged out by now!
}

spawnScript()
{
	# we use this so we can execute from self service.app and call a logout with out breaking policy execution.
	# the script copies, then spawns itself 
	if [ "$spawned" != "--spawned" ]
	then
		tmpscript="$(mktemp /tmp/fvhelper.XXXXXXXXXXXXXXX)"
		cp "${0}" "${tmpscript}"
		# spawn the script in the background
		echo "spawned script $tmpscript"
		chmod 700 "${tmpscript}"
		"${tmpscript}" --spawned '' ${username} &
		exit 0
	fi
}

cleanUp()
{
	[ "$spawned" == "--spawned" ] && rm "${0}" 	#if we are spawned, eat ourself.
}

#
# Start the bidness
#

spawnScript

until checkProcess "Finder.app"
do
	sleep 3
done

[ "${username}" == "" ] && username="$(who | grep console | awk '{print $1}')" # if running from self service

for skipuser in ${skipusers[@]}
do
	if [ "${username}" == "${skipuser}" ]
	then
		echo "${username} shouldn't be filevaulted by fvhelper, bye."
		cleanUp
		exit 0
	fi
done

if [ ! -f "${fvhelperreceipt}" ] # no receipt, we can prompt to enable FV.
then
	if [ "$(checkConsoleStatus)" == "userloggedin" ] # double check we have logged in user
	then
		filevaultprompt=$(osascript -e "display dialog \"This Mac requires FileVault Encryption.

Would you like to enable for ${username} ?\" with icon file \"${dialogicon}\" buttons {\"Later\",\"Enable FileVault and Restart...\"} default button 2" | cut -d, -f1 | cut -d: -f2)
		if [ "$filevaultprompt" == "Enable FileVault and Restart..." ]
		then
			echo "jamf please call the fv policy"
			jamf policy ${fvpolicy}
			touch "${fvhelperreceipt}"
			osascript -e "display dialog \"FileVault has been enabled. Your Mac will now logout, prompt you for your password and then restart to finalise the encryption process.\" with icon file \"${dialogicon}\" buttons {\"OK\"} default button 1 giving up after 20"
			logoutUser
		else
			echo "user skipped FV"
		fi
	fi
else
	# if we've run the policy and the receipt exists, the JSS isn't up to date, recon.
	jamf recon
fi

cleanUp
exit 0
