#!/usr/bin/env bash

# OK-API: Manage-My-Server --> multi-backup-ctrl.sh
# Copyright (c) 2020
# Author: Nico Schwarz
# Github Repository: ( https://github.com/OK-API/Manage-My-Server )
# OK-API : O.K.-Automated Procedures Initiative.
#
# Convenient multi-source to multi-target backup sync control.
#
# This file is copyright under the version 1.2 (only) of the EUPL.
# Please see the LICENSE file for your rights under this license.

#
# RECOMMENDED TO BE EXECUTED WITH SUDO OR ROOT PERMISSION
#

################################################################################
# Help Section                                                                 #
################################################################################

showHelp() {
        # Display Help
        echo
        echo "Usage: multi-backup-ctrl.sh [OPTIONS]"
        echo
        echo "This script is built to perform a backup of one or more source directories to one or more target directories."
        echo "It is designed to be run in a System which has multiple backup disks which can be mounted in different paths."
        echo "Even though it might run on a large variety of systems, it was made for being used with 'openmediavault'."
        echo "The configuration which source directory shall be backed up to which target directory is being read from a separate config file."
        echo "The script is built to be either executed with sudo or root permissions."
        echo
        echo "Syntax: multi-backup-ctrl.sh -p|--path file_path [-t|--test] [-s|--silent] [-h|--help]"
        echo 
        echo "Options:"
        echo "-p|--path     Mandatory parameter. Specifies the path of the config file which contains the source and target folders for the backup. "
        echo "-t|--test     Sets the test flag, which makes the script run without really performing the rsync backup."
        echo "-s|--silent   Sets the 'silent' flag, which prevents the output of DEBUG and INFO level logs to stdout. It will only be logged to the log file. ERROR level will still be logged to stdout and file."
        echo "-h|--help     Print this Help."
        echo
        echo "Example usage: ./multi-backup-ctrl.sh -p /tmp/myInputFile.txt"
        echo "Example usage: ./multi-backup-ctrl.sh -p /tmp/myInputFile.txt -s"
        echo "Example usage: ./multi-backup-ctrl.sh -p /tmp/myInputFile.txt -t"
        echo 
        echo "The input file must contain a pair of source directory and target directory in each line, separated by a blank."
        echo "The required format is '<sourceDir> <targetDir>'"
        echo
        echo "Example input file:"
        echo "/mnt/d/doBackupSource/subdir1 /mnt/f/doBackupTarget/"
        echo "/mnt/d/doBackupSource/subdir2 /mnt/f/doBackupTarget/foodir/"
        echo
        echo "Exit codes:"
        echo "0         if execution successful."
        echo "1         if preparation fails, which can be malformed input or problems with logging environment."
        echo "2         if the rsync based backup itself failed for some reason."
}

################################################################################
# check Regular Execution Tracking File for Execution in last Backup cycle     #
################################################################################
checkTrackingFile() {
       ##################
        # Checking if this script already ran in the past 24 hrs
        ##################
        # first check the existence of our tracking file
        if [[ -f $trackingFile ]]; then
                # Comparing modification epoch time with the actual epoch time.
                # If the difference is bigger than 86400 (24 hrs) then we can do a backup.
                # We only want to do a backup once a day.
                # This could also have been done using the command:  find /var/log/trackingFile -mtime +0
                #       This checks if there is a file that has a modification date older than 24 hrs.
                #       But I wanted to make the logic more obvious by using this if clause, for others to read.
                #       In addition I wanted to react differently on a non existing file and on an existing file with a mtime diff of less than 24 hrs.
                trackingFileDate=$(stat -c %Y "$trackingFile")
                currentTime=$(date +%s)
                timeDiff=$((currentTime - trackingFileDate))
                if ((timeDiff < 86400)); then
                        # This information is being logged to syslog, using logger, as we do not want it to clutter the dedicated logfile of this script.
                        # As this script can be executed multiple times a day (e.g. hourly), there can be a large number of these entries.
                        # We want this information in the syslog, but as there is no 'real' action being performed we just need the info that the script ran, but did not perform anything.
                        log "$logRegularExecFileName" "INFO" "trackingFile Date is smaller than 86400 seconds (24hrs). Nothing to do here. Age is $timeDiff."
                        # We consider this a successful execution of the script, assuming that it is being called regulary using e.g. a cronjob.
                        exit 0
                else
                        log "$logRegularExecFileName" "INFO" "trackingFile Date is bigger or equal than 86400 seconds (24hrs). Age is $timeDiff. Backup will be started now. For a detailed backup log see: $logdir/$logFileName"
                fi
        else
                log "$logRegularExecFileName" "INFO" "Tracking file $trackingFile not found. Assuming first or force run. Starting backup. For a detailed backup log see: $logdir/$logFileName"
        fi
}

################################################################################
# Main function to actually perform the backup sync jobs                       #
################################################################################
startBackup() {

        #successVar="true"
        # The -p parameter creates all parent directories and does not throw an error if the folder already exists
        #mkdir -p "$logdir"
        timestamp=$(date +%Y%m%d-%H:%M:%S)
        log "$logFileName" "INFO" "All checks passed. Starting Backup."
        # Some thoughts about the following rsync command:
        #       --modify-window=1 rounds the timestamp to full seconds. NTFS timestamps have a resolution of 2 seconds, FAT/EXT filesystems use seconds.
        #       modify-window allows us to have a timestamp that differs by 1 second.
        #       As this script might sync from different filesystems, and the timestamp is being used for checking for changed files, 
        #       it must be able to match properly when using different file systems.
        #
        #       rsync parameter -z is not being used anymore. -z compresses the data before transferring it, 
        #       this is not required if you sync using sata/esata, of if you are having a fast network.
        #       In fact it might even slow things down, as it brings load on the cpu of your server (and only uses one core).
        #       If you need to sync over a small bandwidth WAN connection, you can add the -z paramater again.
        #
        #       --stats  Shows a comprehensive report at the end of transferring the data.
        #       -v      Flag for verbose output
        #       -h      Flag for human readable output
        ((counter=0))
        for i in "${sourceDirectoryArray[@]}"; do
                # Adding a blank line in notification to have it better formatted in output
                notification="$notification \n"
                # Following line is for debug purpose only
                #echo $timestamp ": Looping through index " $i | tee -a $logdir/backLogOverview.log
                timestamp=$(date +%Y%m%d-%H:%M:%S)
                notification="$notification $timestamp Backing up $i to target device ${targetDirectoryArray[$counter]}.\n"
                log "$logFileName" "INFO" "Backing up $i to target device ${targetDirectoryArray[$counter]}."
                # We always need to create the stderr output log for building proper notifications, even if we only to a testrun
                timestamp=$(date +%Y%m%d-%H%M%S)
                logStdErrorFile="$timestamp-stderr.log"
                touch "$logdir/$logStdErrorFile"
                if [ "$testFlag" != "true" ]; then
                        # logging to execution to make an entry that can be picked up by a monitoring sytem.
                        # In addition this creates a more readable entry, as the backup log contains loads of details from the rsync.
                        log "$logRegularExecFileName" "INFO" "Backing up $i to target device ${targetDirectoryArray[$counter]}."
                        # Running the rsync. Redirecting output of stdin and stdout to a file and tee by splitting the pipe.
                        rsync -avh --modify-window=1 --stats "$i" "${targetDirectoryArray[$counter]}" > >(tee -a "$logdir/$logFileName") 2> >(tee -a "$logdir/$logStdErrorFile" >&2)
                        # Getting the returncode of the first command in the pipe - the rsync.
                        out=${PIPESTATUS[0]}
                else
                        # we assume a successful rsync command when using the -t testparam.
                        log  "$logFileName" "INFO" "Testflag recognized. Skipped rsync execution."
                        out=0
                fi
                # uncomment following line for debugging purpose to test the if clause while using the -t param. change the value to 0 for testing the script success.
                #out=42
                timestamp=$(date +%Y%m%d-%H:%M:%S)
                log "$logFileName" "INFO" "FINISHED backup of $i to ${targetDirectoryArray[$counter]} with code $out at $(date)."
                notification="$notification $timestamp FINISHED backup of $i to ${targetDirectoryArray[$counter]} with code $out at $(date)."
                if [ "$out" != 0 ] && [ -n "$out" ]; then
                        # successVar="false"
                        # TODO: successVar shall be used later to handle failures of just one backup job. If one backup fails it shall continue to do the other backup jobs, but finally fail and send a notification.
                        errmsg="$(cat "$logdir/$logStdErrorFile")"
                        timestamp=$(date +%Y%m%d-%H:%M:%S)
                        notification="$notification \n$timestamp: Backup of  $i  to target device  ${targetDirectoryArray[$counter]}  failed with output  $errmsg  and code  $out \n"
                        log "$logFileName" "ERROR" "$notification"
                        exit 2
                fi
                ((++counter))
        done
        # Setting the new modification date on trackingFile
        touch "$trackingFile"
        log "$logFileName" "INFO" "FINAL FINISH $(date)"
        exit 0
}

################################################################################
# Function to get and validate input file content                              #
################################################################################
getFileContent() {
        # Reading information from file
        ((counter=0))
        while IFS= read -r line; do
                # Cutting input to fill array with source and target folder information
                fieldsArray=($(echo "$line" | cut -d' ' -f1-))
                # First checking if we have read a valid number of fields.
                # As there are only pairs allowed in the input file, we should have an even number of fields now.
                if [ ${#fieldsArray[@]} -ne 2 ]; then
                        # If it is an uneven number of fields, we have for sure a malformed input file
                        log "$logRegularExecFileName" "ERROR" "Invalid format of input file content. Every line needs to contain a pair of folders, separated by one blank. Example: /home/myUser/myFolder /mnt/myTargetMount/targetFolder"
                        exit 1
                fi
                        # Filling the directory array which will be used to iterate and fill the rsync command later.
                        sourceDirectoryArray[$counter]="${fieldsArray[0]}"
                        targetDirectoryArray[$counter]="${fieldsArray[1]}"
                        ((++counter))
        done <"$filepath"
}

################################################################################
# Function to validate input file content                                      #
################################################################################
checkFileContent() {
        # Checking and validating input
        # Now checking if the source paths exist
        # We only check the source paths. Non existant target paths will be created later anyway.
        for i in "${sourceDirectoryArray[@]}"; do
                timestamp=$(date +%Y%m%d-%H:%M:%S)
                # echo "i is $i"
                if [ -d "$i" ]; then
                        log "$logRegularExecFileName" "INFO" "Successfully checked existence of input folder: $i."
                else
                        log "$logRegularExecFileName" "ERROR" "Directory $i does not exist. Please check your input file. Specifying an input file with correct source and target folders is mandatory."
                        exit 1
                fi
        done
}

log(){
        targetFile=$1
        type=$2
        message=$3
        # TODO: Check for existence of log directory and log file.
        timestamp=$(date +%d.%m.%Y-%H:%M:%S)
        if [ "$type" = "ERROR" ]; then
                printf "%s\n"  "$timestamp $type $message" 1>&2 > >(tee -a "$logdir/$targetFile" >&2)       
        else
                if [ "$silentFlag" = true ]; then
                        # If the -s silent parameter has been set, we only append the log to the log file.
                        printf "%s\n"  "$timestamp $type $message" >> "$logdir/$targetFile"
                else
                        # If the -s silent paramater has not been set, the message gets added to the log file and appears as output in the shell
                        printf "%s\n"  "$timestamp $type $message" | tee -a "$logdir/$targetFile"
                fi
        fi

}

################################################################################
# Main functionality to parse the command input and call the script functions  #
################################################################################
# Reading input parameters one by one, and parsing it.
# In this while loop we only read the parameters, and validate input.
# We only start the backup later, if 
testFlag=false
silentFlag=false
declare -a sourceDirectoryArray
declare -a targetDirectoryArray
# Preparing logging and log directories
logdir="/var/log/multiBackupLog"
logFileName="backupLog.log"
logRegularExecFileName="executionLog.log"
trackingFile="$logdir/trackingFile"

# First we check if we get any input parameter at all, as there are some mandatory params.
if [[ $# -eq 0 ]]; then
        # we just show the usage information if there are no params present
        showHelp
        exit 0
fi

# Setting up everything for logging. 
# Ironically enough we use the log function to log errors about log files not being present. In some cases this might lead to additional errors,
# as the tee call might not be able to write to the file, but the printf part of the log function will bring this message to the stderr output.
# The -p parameter creates all parent directories and does not throw an error if the folder already exists
mkdir -p "$logdir"
rc=$?
if [ "$rc" != "0" ]; then
        log "$logRegularExecFileName" "ERROR" "Could not check or create $logdir. Command 'mkdir -p $logdir' failed with returncode $rc."
        exit 1
fi
touch "$logdir/$logFileName"
rc=$?
if [ "$rc" != "0" ]; then
        log "$logRegularExecFileName" "ERROR" "Could not check or create $logdir. Command 'touch $logdir/$logFileName' failed with returncode $rc."
        exit 1
fi

# Starting to parse input parameters and performing input validation
# Reading and parsing the arguments and setting flags to influence the script behaviour later.
while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
        -h | --help)
                showHelp
                exit 0
                ;;
        -p | --path) # specifies input file path
                filepath="$2"

                # First we check if the file exists
                if [[ -f "$filepath" ]]; then
                        # If the file exists, we read its contents.
                        getFileContent
                else
                        log "$logRegularExecFileName" "ERROR" "The filepath '$filepath' specified with the -p|--path parameter does not exist."
                        exit 1
                fi
                shift # past argument
                shift # past value
                ;;
        -t | --test) # specifies the testFlag
                testFlag=true
                shift # past argument
                ;;
        -s | --silent) # We handled this before. 
                silentFlag=true
                log "$logRegularExecFileName" "INFO" "Silent flag has been set. INFO and DEBUG Level output will not go to stdout but logfile only."
                shift # past argument
                ;;
        *) # unknown option
                printf "Unknown input parameter %s. \nUsage: \n" "$1" >&2
                showHelp
                exit 1
                ;;
        esac
done

# For having a better visualization in the log file, we just add a couple of # characters to visually separate the different runs of this script in the log
# This is being done here, to have the entry in the log file before the first real log entry, and we do not want it to show up when we just need to pass the -h/help usage information.
log "$logRegularExecFileName" "DEBUG" "#####################################################################"
log "$logFileName" "DEBUG" "#####################################################################"
# We validated the filepath before in the argument parsing. For the -s parameter to have effect, we write this log outside of the argument parsing function.
log "$logRegularExecFileName" "INFO" "Input filepath validated: $filepath and successfully extracted data."
# Now we validate the content and checking for the existance of the source folders
checkFileContent
# All checks and validations are done now, proving that the proper parameters have been set, and the input has been validated.
# Performing check if there has been a backup in the last 24 hrs.
# The check will exit with rc 0 if there has been a check, so the backup is not started.
checkTrackingFile
# If the last backup is more than 24 hrs ago, we start the backup.
startBackup

