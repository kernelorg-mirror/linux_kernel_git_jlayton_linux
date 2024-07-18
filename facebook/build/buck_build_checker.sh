#!/bin/bash
# SPDX-License-Identifier: GPL
#
# Works when executed from linux repo present in devservers
#
# Pass positional arguments to overrite default values for
# ARCH($1), FLAVOR($2) LINUX_REPOPATH($3) and
# REL_PATH_TO_BUCK($4) whenever needed
#
# Can also be used in git bisect run <validation script>
# to find the commit that broke buck build for ARCH + FLAVOR
#
# Script exits with code:
# 0 for successful build
# 1 for incorrect command path
# 3 for compilation errors
#
# set -x

if [ -z "$1" ]
then
  ARCH=x86_64
else
  ARCH=$1
fi

if [ -z "$2" ]
then
  FLAVOR=lol2
else
  FLAVOR=$2
fi

if [ -z "$3" ]
then
  LINUX_REPO_PATH="$(pwd)/"
else
  LINUX_REPO_PATH=$3
fi

if [ -z "$4" ]
then
  REL_PATH_TO_BUCK=./facebook/build/buck
else
  REL_PATH_TO_BUCK=$4
fi

# Construcing command
COMMAND="$LINUX_REPO_PATH"
COMMAND+="$REL_PATH_TO_BUCK"

ABORT_EXIT_CODE=1
if [ ! -f "$COMMAND" ]
then
  echo "Could not find buck at $COMMAND"
  echo "Aborting ..."
  exit $ABORT_EXIT_CODE
fi

if [ "${FLAVOR,,}" = "none" ]
then
  echo "Executing ... $COMMAND build //:$ARCH"
  $COMMAND build //:$ARCH
  exit $?
else
  echo "Executing ... $COMMAND build //:$ARCH-$FLAVOR"
  $COMMAND build //:$ARCH-$FLAVOR
  exit $?
fi
