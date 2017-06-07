#!/bin/sh

#-------------------------------------------------------------------
#
# This file is part of the CernVM File System.
#
#-------------------------------------------------------------------

set -e

# Setup Mnesia
echo "Setting up the Mnesia schema"
bin/cvmfs_services escript scripts/setup_mnesia.escript

# Install syslog configuration file
echo "Installing the syslog configuration file"
sudo cp -v scripts/90-cvmfs_services.conf /etc/rsyslog.d/

echo "  - restarting rsyslog"
sudo systemctl restart rsyslog