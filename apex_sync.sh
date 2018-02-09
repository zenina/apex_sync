#!/bin/bash - 
#===============================================================================
#
#          FILE: apex_sync_new.sh
# 
#         USAGE: ./apex_sync_new.sh 
# 
#   DESCRIPTION: rsync_encapsulate: version 3
# 
#       OPTIONS: ---
#  REQUIREMENTS: rsync, ssh, bash
#          BUGS: ---
#         NOTES: custom script
#        AUTHOR: Nina L (nl), snarfsnaplen@gmail.com
#  ORGANIZATION: 
#       CREATED: 02/08/2018 19:32:38
#      REVISION:  ---
#===============================================================================

# rsync_encapsulate: version 3 
# November 26th 2010

host="10.0.0.1"
user=admin

stamp="$(date +%s)"

## Email Reports
err_rcpt="pink@server"


## Paths
root_path=/opt/customer/psadmin/nina_test
in_path="${root_path}/in"
out_path="${root_path}/out"
archive_path="${root_path}/archives"
remote_out="/usr2/ora/apexproddump/out"
remote_in="/usr2/ora/apexproddump/in"

php_bin="/opt/customer/php/current/bin/php"
encapsulate_path="/opt/customer/psadmin/authtool/web/encapsulatev2/php/MGM_import"
encapsulate_script="process.php"
stamp_path=${root_path}/${stamp}

## Files
archive=${archive_path}/${stamp}.tgz
received_list="${stamp_path}/received"
status_file=${stamp_path}/status
log_file=${root_path}/rsync.log
lock_file=${root_path}/rsync.lock

## Arrays of variable sets. We use these during init to check specific conditions
req_files=( ${log_file} "${encapsulate_path}/${encapsulate_script}" ${php_bin} )  
req_paths=( ${root_path} ${archive_path} )
tmp_dirs=( ${stamp_path} ${in_path} ${out_path} )

set -o pipefail

log(){
	date_stamp="$(date +"[%F %T]")"
	if [ -n "$1" ]; then
		echo "$@" | log
	else
		while read line; do 
				echo "${date_stamp}: $line" >> $log_file
		done
	fi
}

tag(){
	tag=$1
	while read line;
	do
	log "(${tag}) $line"
	done
}

stat(){
	OIFS=$IFS
	IFS=,
	stat_arr=( ${stat_arr[*]} "status: $@", )
	log "status: $@" 
	IFS=$OIFS
}

error(){
	OIFS=$IFS
	IFS=,
	err_arr=( ${err_arr[*]} "error: $@", )
	stat "(error): $@"
	IFS=$OIFS
}

debug(){
	if $set_debug; then
		echo "debug: $@" | log
	fi
}

ssh_apex(){
unset ssh_return
remote_commands="$@"
ssh -oPasswordAuthentication=no ${user}@${host} "$remote_commands"
ssh_return=$?
if [[ "$ssh_return" -eq "255" ]]; then
	error "init: passwordless authentication to apex server (${user}@${host}) failed"
	die 1
else
	return $ssh_return
fi
}
die(){
# Exit/die function. 
	## If lock is set (lock was obtained, and no other sync's were running, meaning we ran through a full process), do additional pre-exit actions
	if $lockSet; then	
		## Archive ##
		## If files were transferred/pulled, run archiving process
		if $archiveFiles; then
			## Write our status report to our status file
			echo -e "${stat_arr[*]/#/\\n}" >> ${status_file}
			## move in and out dirs into the epoch stamped directory. They will then be archived into a tarball in the archive folder in that dir. 
			mv ${in_path} ${stamp_path}/
			in_path=${stamp_path}/in
			mv ${out_path} ${stamp_path}/
			out_path=${stamp_path}/out
			tar -C ${root_path} -czpf ${archive} ${stamp}  2>&1 |log   || {
				stat "Warning: Archive creation failed, moving directories to \'archives\' folder"
				mv -v ${stamp_path} ${archive_path}/ | log
			} && {
				stat "Archive created for this encapsulate run: ${archive}"
				rm -rf ${stamp_path}
			}
		else
			## If we didn't make it far enough to pull down a fileset to archive, remove temp directories
			rm -rf ${tmp_dirs[*]}
		fi
		## remove the lock file
		log "Removing tmp files, and lock file"
		rm ${lock_file} 2>/dev/null | log && {
			stat "Released lock for session: (stamp: $stamp - pid: $pid)"
		} || {
			error "Failed to release lock for session (stamp: $stamp - pid: $pid)"
		}
		log "Exiting"
	fi
	## If we encountered an error, Send an email with our status report, and error report
	if [[ "${#err_arr[@]}" > 0 ]]; then
		log "mailing error report, and status report"
		mail -s "${stamp} authoring rsync" ${err_rcpt} <<EOF
		rsync_encapsulate encountered the following errors:
		$(echo -e ${stat_arr[*]/#/\\n})
EOF
	fi
	exit $1
}


sync(){
# Rsync function
# This creates a consistent standard for somethign we test, and call twice, less duplicate code, and more flexibility. 
# It also gives us an opportunity to sanitize input
	unset rsync_cmd
	if [ -z $2 ]; then
		error "sync function called with out required dst/src parameters"
		return 1
	fi
	src_path=$2
	dst_path=$3
	## print verbose data if debug is set
	if $debug; then
		rsync_opts="-avp"
	else
		rsync_opts="-ap"
	fi

	case $1 in
		"in")
			rsync_cmd="rsync ${rsync_opts} ${user}@${host}:${src_path} ${dst_path}"
			;;
		out)	
			rsync_cmd="rsync ${rsync_opts} ${src_path}  ${user}@${host}:${dst_path}"
			;;
		*)
			error "sync function called without required 'in/out' parameter, aborting"
			return 1 
			;;
	esac

	## Run rsync
	$rsync_cmd 2>&1 || {
		return 1
	} && {
		return 0
	}

}

init(){
# Init function: Pre-run sanity checks
	## Check for lock
	lockSet=false
	archiveFiles=false
	pid=$$
	if [[ -w "${lock_file}" ]]; then
		runpid="$(< $lock_file)"
		if [[ -n "$runpid" ]]; then
			if ps -p ${runpid}; then
				echo "encapsulate sync is already running (locked), exiting."
				die 1
			else
				error "Process in lock file is no longer running. Perhaps stale lock ($runpid) ? aborting"
				die 1
			fi
		else
			error "Lock file found, but empty. This suggests the encapsulate sync may already be running, or the lock is stale. aborting"
			die 1
		fi
		if [[ ! -w "${lock_file}" ]]; then 
			error "Fatal, Can not write to lock file: ${lock_file}, aborting"
			die 1
		else
			echo "$pid" > ${lock_file} || {
				error "Fatal, could not write to lock file, aborting."
				die 1
			} && {
				lockSet=true
				stat "lock obtained for this session (stamp: ${stamp} | pid: $pid )"
			}
		fi
	else
		echo "$pid" > ${lock_file} || {
			error "Fatal, could not write to lock file"
			die 1
		} && {
			lockSet=true
			stat "lock obtained for this session (stamp: ${stamp} | pid: $pid )"
		}
	fi	
	## Make sure we can write to the log
	if [ ! -w ${log_file} ]; then
		error "Fatal, can't write to log file ${log_file}"
		die 1
	fi
	## Check for required paths
	for dir in ${req_paths[*]}; do
		if [[ ! -w "${dir}" ]]; then 
			error "Required directory is either missing, or can't be written to: ${dir}"
			die 1	
		fi
	done
	## Check for required files
	for file in ${req_files[*]}; do
		if [[ ! -r "${file}" ]]; then
			error "can't find/read required file: $file}"
			die 1
		fi
	done 
	## Check ssh/auth, and ensure we can ssh via our ssh function with no issues. We take this opportunity to check to see if files are ready to be processed.
	## We check to see if files are ready for process by checking for a sync.lock file in the remote_out path. Oracle will write this when it's ready for us to pickup the files
	## If this file doesn't exist, then the process is not ready, it's running, or there are no files to pickup, so we abort.  
	ssh_apex "hostname" || {
		error "ssh failed with: $ssh_return"
		die 1
	}

## Uncomment the following block when sync.lock is setup on the apex server
#	ssh_apex "[[ -e "${remote_out}/sync.lock" ]] &&  exit 35 || exit 36"  
#	if [[ "$ssh_return" -eq "35" ]]; then
#		stat "init: Files are ready for processing, initiating sync"
#	elif [[ "$ssh_return" -eq "36" ]]; then
#		stat "init: Files aren't ready for processing, will check again later"
#		die 0 
#	else
#		error "init: ssh check for sync.lock on apex server failed (${user}@${host}). exit status: $return"
#		die 1
#	fi 
##		
	## Delete and recreate tmpdirs to prevent cross contam during sco creation/organization
	for dir in ${tmp_dirs[*]} ; do 
		if [[ -e "${dir}"  ]]; then
			rm -rfv ${dir} || { 
					error "Can't remove old directory: $dir. Could cross contaminate, aborting" 
					die 1
					} 
		fi

		# (re)create dirs
		mkdir -v ${dir}  || { 
			error "Can't create dir: $dir, aborting"
			die 1
			}
	done
}

buildtree(){
shopt -s nullglob
	glob_pattern="[A-Za-z][0-9]*_*"
	path_arr=( ${in_path}/${glob_pattern} ) 
	(( "${#path_arr[*]}" > 0 )) && {
		## strip leading path from each array element
		file_arr=(${path_arr[*]//*\//})
		## strip suffixes so all that remains is an id list
		id_arr=(${file_arr[*]/%_*}) 
		## Create ID dir, and move all associated files into directory.
		log "Building dir structure"
		for id in ${id_arr[*]}; do
			dir="${in_path}/${id}"
			if [[ ! -d "${dir}" ]]; then
				mkdir ${dir}
				mv ${in_path}/${id}_* ${dir}/
			fi
		done
	} || {
		log "Sco filename convention unmatched, moving all files to \'undefined\' directory"
	}
	# Move any remaining files, or unmatched files, into the undefined directory
	mkdir ${in_path}/undefined
	find ${in_path} -maxdepth 1 -type f -exec mv {} ${in_path}/undefined/ \;
shopt -u nullglob
}

pull_files(){
	sync in ${remote_out}/ ${in_path} |tag receive || {
		error "pre-encapsulate: transfer in of xml files failed, aborting"
		die 1	
	} && {
		## create received list, and determine if we have any files to process
		stat "rsync in completed"
		find ${in_path} -maxdepth 1 -mindepth 1 -type f -fprintf ${received_list} "%f\n" 
		# remove the local sync/lock flag before proceeding
		rm -v ${in_path}/sync.lock | log
		if [[ -z "$(< ${received_list})" ]]; then
			stat "No files found to process on remote server: $host, aborting"
			die 0
		else
			archiveFiles=true
		fi
	}
}

encapsulate(){
	shopt -s nullglob
	log "Running encapsulate against xml's"
	cd ${encapsulate_path}
	QUERY_STRING="in=${in_path}&out=${out_path}"
	${php_bin} ./${encapsulate_script} | tag encapsulate || {
		error "encapsulate failed to run, please check log"
		die 1
	} && {
		stat "encapsulate ran successfully"
		status_file_arr=( ${out_path}/*_status.csv ${out_path}/*_status.xls )
		status_csv="${status_file_arr[0]}"
		status_xls="${status_file_arr[1]}"
		ls ${status_csv}
		ls ${status_xls}
		if [[ ! -e "${status_csv}" ]] || [[ ! -e "${status_xls}" ]]; then
			error "encapsulate status files not found (${status_csv}, ${status_xls}) aborting"
			die 1
		else
			stat "encapsulate status files created:"
			stat "${status_csv}"
			stat "${status_xls}"
			return 0
		fi
	}
	shopt -u nullglob
	
}

post(){
	## Process our status file
	log "transferring status file: authtool --> apex"
	sync out ${out_path}/ ${remote_in}/ | tag send || {
		error "transfer of status files to apex server failed"
	} && {
		stat "transferred status file to apex server"
	}
	## Mail status csv file. This is just for testing purposes 
	mail -s "sco build status: ${stamp}" ${status_rcpt}< ${status_csv}
	## If we've made it to this point, we have processed files with encapsulate. We can now delete them off the remote/originating host
	file_list_arr=( $(< ${received_list}))
	if [[ "${#file_list_arr[*]}" > 0 ]]; then
		if [[ "${remote_out}" =~ '.*\/.*out.*' ]]; then
			rm_list=( ${file_list_arr[*]/#/${remote_out}\/} )
			ssh_apex "rm -fv ${rm_list[*]}" | tag "remote delete" || {
				error "failed to delete all files on remote host."
				} && {
				stat "cleaned up/deleted all processed files on the apex server"
				}
		else
			error "pre-delete sanity check failed: \'${remote_out}\'. Not deleting any files off remote host"
		fi
	else
		log "Received file list empty during delete process. Has the list been moved?" 
	fi
	stat "encapsulate_sync, and all post run processes completed"

}


case $1 in
	rerun)
		# debug set, debug messages are printed for each step
		set_debug=true
		set -x
		init 
		pull_files
		buildtree
		;;
	*)
		# debug unset, no debug messages are printed 
		set_debug=false
		init 
		pull_files
		buildtree
		encapsulate 	
		post
		die 0 
		;;
esac
