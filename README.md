# pglvmbackup

## TL;DR

I would recommend to use this script if you either:

* feel LVM snapshotting is the best way to make a backup
* need a robust backup system optimized for monitoring

Otherwise, go for pgBackRest.

## Alternatives

There is pg_basebackup which is the standard tool, it used to be the general recommendation - though as of 2021, pgBaseBackup is the recommended tool by our most senior in-house PostgreSQL expert.

For us it didn't work out as our client explicitly wanted backups through LVM-snapshotting.  I found a a tool at https://github.com/credativ/pg_backup_ctl which may be based on LVM snapshotting and may take care of all aspects of the PITR backup (even including editing config files).  It also didn't fit very well with our needs, I believe it doesn't work when trying to take the base backup from the slave server, and I believe it's not terribly robust at handling unexpected errors and warnings.

Doing a backup is fairly simple, just some few lines of code ... run pg_start_backup(), create an lvm snapshot, run pg_stop_backup(), make a tarball of the lvm snapshot, delete the lvm snapshot ... how difficult can that be?  Five minutes of work?  Actually, I'm very much surprised to say that I ended up doing a lot of work before getting a workable backup script, I would not recommend anyone to "roll your own" on this one!

## Pros and cons

* According to one of my colleagues, the usage of LVM snapshotting may cause more IO overhead than just relying on pg_start/pg_end, so he's recommending against it.
* This script is designed for robustness.  If anything goes wrong, there should be lots of alarms on our monitoring system.
* Archiving of binlogs is not handled by this script and has to be taken care of outside of this script.

## Rationale

We needed a robust PITR backup system for a client.  Some of the requirements:

* It should be a PITR-compatible backup (we're using pg_start_backup() and pg_stop_backup() to guarantee this)
* It should use the LVM snapshot feature to avoid a large database being stuck in backup mode for a longer time
* It should work from a slave server in a master/slave setup (but it should also work on a standalone server).
* We should have strong monitoring on the backup;
  * monitoring that the backup script succeeded reasonably recently (script will touch the configurable file $SUCCESSFILE when it runs without any warnings or errors, hence it's possible to monitor the age of this file)
  * monitoring that the backup is bigger than some specified minimum size
  * monitoring that the backup script doesn't get stuck (running for too long) - solved by introducing a pid-file that can be monitoried
  * monitoring that postgres doesn't get stuck in backup mode (solved through the check_pgactivity nrpe plugin and its backup_label_age service)
  * monitoring that the backup doesn't yield errors (all unexpected stderr logging ends up in a configurable $PROBLEMFILE which can be monitored)

I have been told that the IO-overhead of LVM doing copy-on-write probably is bigger than the overhead of having PostgreSQL standing in backup mode while the backup is being taken.

## Installation, prerequisites and usage

* The script should be run by the root user
* "sudo -u postgres" should just work, without being queried for a password
* LVM should be used
* Postgres data is on a separate partition
* Script expects a configuration file in /etc/default/pglvmbackup - an example configuration file is supplied.  If you want to have the configuration somewhere else and don't want to hard-code it in the script, then I'd be happy to merge in a patch supporting a command line option "-c /path/to/configfile" or "--configfile=/path/to/configfile".
* Script does not take any options or parameters, it should just be run
* Directories referred to in the config file needs to exist

## SELinux

In our setup pglvmbackup is executed through our bareos/bacula backup setup, and it's running under SELinux.  This caused some challenges.  I must admit that I haven't spent much efforts on getting the SELinux setup right, I have just run "audit2allow" on the audit log and made a .te-file out of it.  The supplied file may need to be tuned, i.e. if you're running the backup script through cron, you may want to replace bacula_t with cron_t.

## Puppet setup, nrpe/nagios/icinga setup

We're deploying this through puppet, the pglvmbackup.pp manifest is part of an internal postgres puppet module, and the config file exists as an erb template in our puppet environment.  The current puppet module is tightly intervowen with our in-house backup and monitoring modules though, so it doesn't make much sense publishing it.  Same with nagios/icinga/nrpe setup.  Say, why don't you contact my employer [Redpill Linpro](https://www.redpill-linpro.com) for a quote on postgres administration, including monitoring and backup? :-)
