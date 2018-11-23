#!/bin/bash

## NOTE: Upstream home for this script is https://gitlab.com/tobixen/pglvmbackup

################
## CONFIGURATION
################

. /etc/default/pglvmbackup


####################
## UTILITY FUNCTIONS
####################


## "Soft" errors should not abort the backup (it is likely to be
## intact), but we want to flag the problems
soft_error() {
    echo "$(date +$TFMT) ERROR: $@" >> $PROBLEMFILE
    echo "$(date +$TFMT) Continuing backup anyway" >> $PROBLEMFILE
}

## When encountering a "hard" error, it's obvious that we won't be
## able to make any useful backup, and we can as well quit.
hard_error() {
    echo "$(date +$TFMT) CRITICAL: $@" >> $PROBLEMFILE
    echo "$(date +$TFMT) Aborting" >> $PROBLEMFILE
    [ -n "$COPROC_PID" ] && echo '\q'  >&${COPROC[1]}
    log "aborting due to some error, check $PROBLEMFILE"
    rm $PIDFILE
    exit 2
}

log() {
    echo "$(date +$TFMT) $@" >> $LOGFILE
}

## Read from the coproc pipe and yield soft errors if there is any unexpected output
expect_nothing() {
    stoplines="$1"
    stoplines= [ -z "$stoplines" ] || 100
    n=0
    while read -t 0.01 psqlout <&${COPROC[0]} && [ -n "$psqlout" ] && soft_error "unexpected extra output from command (select pg_start_backup('${label}', false, false);): '$psqlout'"
    do
        [ $n -gt $stoplines ] && break
        n=$((n+1))
    done
}

## Read from the coproc pipe and redirect to log.  Eventually, expect
## something from the output.
pipe_to_log() {
    timeout="$1"
    [ -z "$timeout" ] && timeout=60
    maxlines="$2"
    expect="$3"
    command="$4"
    n=1
    
    if [ -n "$command" ]
    then
        log "ran $command"
    fi
         
    read -t $timeout psqlout <&${COPROC[0]} || soft_error "timed out waiting for results ($command)"
    if [ -n "$expect" ]
    then
        echo $psqlout | grep -q $expect || soft_error "unexpected results from command $command: $psqlout"
    fi
    log $psqlout
    while [ $n -lt $maxlines ]
    do
        read -t 0.01 psqlout <&${COPROC[0]} || break
        log $psqlout
    done
    expect_nothing
}

#############
## SOME SETUP
#############

log "pglvmbackup started"


## Reset $PROBLEMFILE
if [ -f $PROBLEMFILE ]
then
    mv $PROBLEMFILE $PROBLEMFILE.$$
    cat $PROBLEMFILE.$$ >> $PROBLEMFILE.old.log
    rm $PROBLEMFILE.$$
fi

## pid file (ref https://tobru.ch/follow-up-bash-script-locking-with-flock/ - and ref that the customer wants to monitor weather the script is running)
exec 200>$PIDFILE
flock -n 200 || hard_error "unable to lock $PIDFILE - backup already running?"
echo $$ 1>&200
 
## Pipe stderr to the PROBLEMFILE.  If any stderr logging is captured there, the backup will be marked as non-successful.
exec 2>>$PROBLEMFILE


###########################
## CREATING BACKUP SNAPSHOT
###########################

## non-exclusive backups (ref the comment on the top of the file)
## means we need to hold the psql connection until the snapshot has
## been taken.  To do this with bash and psql, we need to start up
## psql as a coprocesses.  coprocesses were introduced in bash v4.
coproc sudo -u postgres psql -t 2> >(perl -pe 'use POSIX qw(strftime); $date=strftime("'$TFMT'", localtime()); s/^NOTICE.*$// && chomp && next; s/^/$date stderr from psql: /' >> $PROBLEMFILE)

## Prepare postgres for backup
echo "select pg_start_backup('${label}', false, false);" >&${COPROC[1]}

## Pipe the output to the log.  Expect to see a slash.  Expect only one line of input
pipe_to_log 60 1 / pg_start_backup

if [ -n "$MASTER_SERVER" ]
then
    ## roll the wal file (usually included when doing pg_start_backup, but has to be done from the server side)
    log "running pg_switch_${WAL}() on master"
    echo "select pg_switch_${WAL}();" | sudo -u postgres ssh postgres@$MASTER_SERVER psql >> $LOGFILE || soft_error "couldn't run pg_switch_${WAL}"
fi
sync ## the sync should be very much redundant

## create LVM snapshot.  The "File descriptor ... leaked on lvcreate invocation" is according to google a harmless warning that should be ignored
lvcreate --size $LVSIZE --snapshot --name $label $PGSQLDEVICE >> $LOGFILE 2> >(grep -Ev '^File descriptor.*leaked on lv.* invocation' 1>&2) || hard_error "failure while running lvcreate" 

## Tell postgresql that we're done taking the backup
echo "select pg_stop_backup(false);" >&${COPROC[1]}
pipe_to_log 60 20 / pg_stop_backup

## Quit the postgresql session
echo '\q'  >&${COPROC[1]}

#########################################
## STREAMING THE BACKUP TO FILE OR STDOUT
#########################################
mountdir=$(mktemp -d)
mount $VG_PATH/$label $mountdir
log "tarring archive"
cd $mountdir ; tar --create --gzip --file $OUTPUT_TARGET --index-file >(cat >> $LOGFILE) --verbose . || hard_error "tar archiving failed: \"tar --create --gzip --file $OUTPUT_TARGET --index-file >(cat >> $LOGFILE) --verbose .\""
log "done tarring"
cd /
umount $mountdir
rmdir $mountdir

##########
## CLEANUP
##########
log "lvdisplay output:"
lvdisplay $VG_PATH/$label >> $LOGFILE 2> >(grep -Ev '^File descriptor.*leaked on lv.* invocation' 1>&2)
log "running lvremove"
lvremove -y --select name=$label >> $LOGFILE 2> >(grep -Ev '^File descriptor.*leaked on lv.* invocation' 1>&2) || soft_error "lvremove failed.  This may cause the next backup to fail or the lvm space to fill up"

if [ -s "$PROBLEMFILE" ]
then
    log "Some problems or stderr output encountered, backup may be corrupted or inconsistent, please check $PROBLEMFILE"
    rm $PIDFILE
    exit 1
else
    ## No problems encountered, no stderr logging encountered, fix a
    ## timestamp marker for the last successful backup and exit
    ## successfully
    log "No problems or stderr output encountered, backup should be good, updating timestamp file $SUCCESSFILE"
    touch $SUCCESSFILE
    rm $PIDFILE
    exit 0
fi
