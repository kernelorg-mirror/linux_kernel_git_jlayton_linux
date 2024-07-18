#!/bin/bash

# A script to generate a patch diff to update the clang pgo profile data

usage() {
  echo "Usage: $0 <linux_repo_dir> <base_branch> [no-dry-run] [<training_time_in_seconds>]"
  echo "       twtf_handle can be modified like: twtf_handle=<...> $0 ..."
}

args="$@"

# We need the linux repo location, so we can get into the repo and
# create a diff there.
linux_repo_dir=$1

if [ -z "${linux_repo_dir}" ]; then
  echo "Error: Missing linux repo directory"
  usage
  exit 1
fi

# The linux repo should be clean, i.g., there is no uncommited files.
# Otherwise, the diff generation may not succeed.
if [[ $(git -C ${linux_repo_dir} diff --stat) != '' ]]; then
  echo "Error: The linux repo at ${linux_repo_dir} has uncommitted files"
  exit 1
fi

# We need a base branch to create a diff. The base branch is a branch
# existing in the remote git repository. The final diff is created
# on top of the base branch.
# The base branch should also tell us its corresponding major kernel
# version where manifold directory the training data should be put.
base_branch=$2

if [ -z "${base_branch}" ]; then
  echo "Error: Missing the base branch"
  usage
  exit 1
fi

# default: do 'jf submit'
do_submit=0
# default: training time 7200 seconds
training_time=7200

pos3=$3
if [ "$pos3" != "" ]; then
  if [ "$pos3" = "no-dry-run" ]; then
    do_submit=1

    pos4=$4
    if [ "$pos4" != "" ]; then
      if ! [[ $pos4 =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid training time"
        usage
        exit 1
      fi
      training_time=$pos4
    fi
  elif [[ $pos3 =~ ^[0-9]+$ ]]; then
    training_time=$pos3
  else
    echo "Error: Invalid training time"
    usage
    exit 1
  fi
fi

if [ "${do_submit}" = "0" ]; then
  manifold_kernel_dir="tmp"
elif [[ "${base_branch}" == *"v6.9"* ]]; then
  manifold_kernel_dir="v69"
else
  echo "Error: Base branch is not from v6.9"
  exit 1
fi

# NOTE: globalcert should be enabled. Otherwise, accessing to
# clangtrain kernel machines will fail. Currently, maximum time
# period is 12 hours. Let us set that.
globalcertreq --force --hours 12

# Temporary directory to be used to store intermediate files.
tmp_dir=/tmp/clangtrain_pgo_profile
/bin/rm -rf ${tmp_dir}
mkdir -p ${tmp_dir}

# The clangtrain kernel in the twtf experiment.
kernel=""
# The profdata file (with relative path) stored in manifold
manifold_target_file=
# The sha256 of the profdata file stored in manifold
sha256=

# We need a twtf handle in order to collect profiles and generate diff.
# The tier should have clangtrain kernels running with some workloads.
# Note that the handle name might change if the twtf experiment changes.
# But the idea is the twtf experiment should last a long time...
#
# We could also use smc tier directory. I am using twtf handle as
# through it we can easily get more information.
# default twtf handle is 7790a9d1-907a-4568-aae2-56c3ed002eb7, but
# is can be overwritten at the command line like
#   twtf_handle=<...> ./collect_profdata_and_submit.sh ...
twtf_handle=${twtf_handle:-ecd76ac1-91cf-41cf-9dd6-efd462dc70fa}
smc_tier=$(twtf status -e ${twtf_handle} -o Json | jq -r '.smc_tier')
echo "smc_tier: ${smc_tier}"

# check integrity of the tier, it should be the same clangtrain
# kernels for the whole tier.
validate_tier_and_find_clangtrain_kernel() {
  echo "Validating same clangtrain kernels in the smc_tier ..."
  for host in $(smcc ls-hosts ${smc_tier}); do
    echo "  Check host ${host}"
    local tmp_kernel=$(sush2 --skip-reason ${host} 'uname -r' 2> /dev/null)
    if [ ! -z "${kernel}" -a "${kernel}" != "${tmp_kernel}" ]; then
      echo "Error: tier has different kernel versions, e.g. ${kernel}, ${tmp_kernel}"
      exit 1
    fi
    kernel=${tmp_kernel}
    if [[ ${kernel} != *"clangtrain"* ]]; then
      echo "Error: ${tmp_kernel} is not a clangtrain kernel"
      exit 1
    fi
  done

  # check whether the clangtrain kernel matches manifold kernel dir
  # w.r.t. major branch.
  if [ ${manifold_kernel_dir} == "v69" ]; then
    if [[ ${kernel} != *"6.9"* ]]; then
      echo "Error: clangtrain kernel ${kernel} does not match base branch ${base_branch}"
      exit 1
    fi
  fi

  echo "clangtrain kernel: ${kernel}"
}

# collect training data for the tier
collect_training_data() {
  # start the training data collection
  echo "Enabling profile data collection ..."
  for host in $(smcc ls-hosts ${smc_tier}); do
    echo "  Enable profiling in ${host}"
    sush2 --skip-reason ${host} 'echo 1 > /sys/kernel/debug/pgo/reset' 2> /dev/null
  done
  # collect training data
  echo "Waiting ${training_time} seconds ..."
  sleep ${training_time}
  echo "Copying profile data within host and end profile data collection ..."
  # copy the training data to /root directory for later copying to dev servers,
  # and end the training data collection
  for host in $(smcc ls-hosts ${smc_tier}); do
    echo "  Copy profile and end profile data collection in ${host}"
    sush2 --skip-reason ${host} '/bin/cp /sys/kernel/debug/pgo/vmlinux.profraw /root/vmlinux.profraw && echo 0 > /sys/kernel/debug/pgo/reset' 2> /dev/null
  done
}

get_training_data_and_upload() {
  # retrieve raw profile data to local devserver
  # copy the raw training data from twtf machine to local devserver.
  echo "Retrieving profile data to local host ..."
  cd ${tmp_dir}
  for host in $(smcc ls-hosts ${smc_tier}); do
    echo "  Retrieve profile data from ${host}"
    # the smc tier /root/vmlinux.profraw will be downloaded into some local directory different for different hosts
    h5h fetch --root --globalcert --quiet -T host:${host} /root/vmlinux.profraw . --bypass-review "i am good" 1> /dev/null
  done

  # merge profdata
  # hardcode llvm15 now as it works for 6.9 kernel. Will change when compiler
  # is upgraded.
  echo "Merging profile data and calculating sha256sum"
  local compiler=~/fbsource/fbcode/third-party-buck/platform010/build/llvm-fb/15/bin/llvm-profdata
  local profdata_file=profdata.${kernel}.${training_time}s.$(whoami).$(date +%F-%H-%M-%S)
  ${compiler} merge --output=${profdata_file} $(find . -name vmlinux.profraw)
  sha256=$(sha256sum ${profdata_file} | cut -d " " -f1)
  echo '  profdata_file' ${profdata_file}
  echo '  sha256' ${sha256}

  # upload to the manifold
  manifold_target_file=linux_kernel/tree/clang_train_data/${manifold_kernel_dir}/${profdata_file}
  echo "Updating profile data to ${manifold_target_file}"
  manifold put --overwrite ${profdata_file} ${manifold_target_file}
}

gen_commit_and_submit() {
  echo "Generating the diff"
  # local linux repo directory
  cd ${linux_repo_dir}
  git checkout ${base_branch}
  git branch -D profdata.${kernel}
  git checkout -b profdata.${kernel}

  # modify facebook/bzl/constants.bzl to have newer training data
  # the below format is for 6.9
  /bin/rm -f ${tmp_dir}/tmp.patch
  old_ifs="${IFS}"
  IFS=''
  cat facebook/bzl/constants.bzl |
  while read line; do
    if [[ ${line} = *CLANG_TRAIN_DATA_URI* ]]; then
      echo CLANG_TRAIN_DATA_URI=\"https://interncache-all.fbcdn.net/manifold/${manifold_target_file}\" >> ${tmp_dir}/tmp.patch
    elif [[ ${line} = *CLANG_TRAIN_DATA_SHA256* ]]; then
      echo CLANG_TRAIN_DATA_SHA256=\"${sha256}\" >> $tmp_dir/tmp.patch
    elif [[ ${line} = *HARDENED_TRAIN_DATA_URI* ]]; then
      echo HARDENED_TRAIN_DATA_URI=\"https://interncache-all.fbcdn.net/manifold/${manifold_target_file}\" >> ${tmp_dir}/tmp.patch
    elif [[ ${line} = *HARDENED_TRAIN_DATA_SHA256* ]]; then
      echo HARDENED_TRAIN_DATA_SHA256=\"$sha256\" >> ${tmp_dir}/tmp.patch
    else
      echo ${line} >> ${tmp_dir}/tmp.patch
    fi
  done
  IFS=${old_ifs}

  /bin/mv ${tmp_dir}/tmp.patch facebook/bzl/constants.bzl
  git add facebook/bzl/constants.bzl
  git commit \
    -m "[META-ONLY] Update profile data with ${kernel}" \
    -m "Summary: auto generation of profile data based on ${kernel}" \
    -m "command line: twtf_handle=${twtf_handle} $(pwd)/facebook/scripts/collect_profdata_and_submit.sh ${args}" \
    -m "Test Plan: sandcastle test" \
    -m "Reviewers: songliubraving, riel, leit, chantra, clm, thesweettea, #linux_kernel"
  if [ "${do_submit}" = "1" ]; then
    jf submit
  fi
}

validate_tier_and_find_clangtrain_kernel

collect_training_data

get_training_data_and_upload

gen_commit_and_submit
