#!/bin/bash
# SPDX-License-Identifier: GPL
#
# Works when executed from linux repo present in devservers
#
# Pass positional arguments to overrite default value for
# PATH_TO_BUCK_BUILD_CHECKER_SCRIPT($1)
# whenever needed
#
# Update [if necessary] the arch + flavor arrays in this script
# to match : facebook/config/flavors.td.bzl
#
# Script sequuentially builds arch + flavor arrays
#
# When encountering a build failure, the script prints arch and
# flavor info and abruptly exits
#
# Script exits with code:
# 0 When all builds successfully complet
# 1 for aborts and compilation errors
#
# set -x

if [ -z "$1" ]
then
  PATH_TO_BUCK_BUILD_CHECKER_SCRIPT=$(pwd)/facebook/build/buck_build_checker.sh
else
  PATH_TO_BUCK_BUILD_CHECKER_SCRIPT=$1
fi

ABORT_EXIT_CODE=1

if [ ! -f "$PATH_TO_BUCK_BUILD_CHECKER_SCRIPT" ]
then
  echo "Checked path $PATH_TO_BUCK_BUILD_CHECKER_SCRIPT"
  echo "Could not find buck build checker script !"
  echo "Aborting ..."
  exit $ABORT_EXIT_CODE
fi

declare -a x86=(
"hardened"
"kdump"
"lol2"
"zion"
"clangtrain"
"hardenedtrain"
"debug"
"lto"
"none"
)

declare -a arm=(
"kdump"
"none"
)

CUR_FLAVOR_ARR=()
CUR_ARCH=""

function git_bisect_suggestion() {
  echo ""
  echo "Suggestion : We can use git bisect command to find the bad commit"
  echo "Here's how :"
  echo "git bisect start"
  echo "git bisect good <Known [old] commit id that builds>"
  echo "git bisect bad <current commit id>"
  echo "cp ./facebook/build/buck_build_checker.sh <location outside the repo>"
  echo "Modify default values for ARCH and FLAVOR when necessary"
  echo "git bisect run <modified buck_build_checker.sh located outside the repo>"
  echo ""
}

function buck_build_abort_suggestion() {
  echo ""
  echo "It is highly unlikely to be a compilation error"
  echo "As buck build compilation errors have [known] exit code 3"
  echo "$PATH_TO_BUCK_BUILD_CHECKER_SCRIPT had exited with abort code $ABORT_EXIT_CODE"
  echo "Address $PATH_TO_BUCK_BUILD_CHECKER_SCRIPT requirements and try again"
  echo ""
}

function build() {
  for flavor in "${CUR_FLAVOR_ARR[@]}"
  do
    echo ""
    echo "Building $CUR_ARCH $flavor"
    echo ""
    $PATH_TO_BUCK_BUILD_CHECKER_SCRIPT $CUR_ARCH $flavor
    RESULT=$?
    if [ $RESULT -eq 0 ]
    then
      echo ""
      echo "Build for arch : $CUR_ARCH flavor : $flavor succeeded"
      echo ""
    elif [ $RESULT -eq $ABORT_EXIT_CODE ]
    then
      echo ""
      echo "Could not complete build for arch : $CUR_ARCH flavor : $flavor"
      echo ""
      buck_build_abort_suggestion
      exit $ABORT_EXIT_CODE
    else
      echo ""
      echo "Build failed for arch : $CUR_ARCH flavor : $flavor"
      git_bisect_suggestion
      exit $ABORT_EXIT_CODE
    fi
  done
}

CUR_ARCH="x86_64"
CUR_FLAVOR_ARR=(${x86[@]})
build

CUR_ARCH="aarch64"
CUR_FLAVOR_ARR=(${arm[@]})
build

echo "Congratulations, All build flavors in "
echo "x86_64 : ${x86[*]}"
echo "aarch64 : ${arm[*]}"
echo "succeeded without compilation errors !"
