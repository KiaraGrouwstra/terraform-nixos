#!/usr/bin/env bash
# nixos-deploy deploys a nixos-instantiate-generated drvPath to a target host
#
# Usage: nixos-deploy.sh <drvPath> <outPath> <targetHost> <targetPort> <buildOnTarget> <sshPrivateKey> <packedKeysJson> <switch-action> <deleteOlderThan> [<build-opts>] ignoreme
set -euo pipefail

### Defaults ###

buildArgs=(
  --option extra-binary-caches https://cache.nixos.org/
)
profile=/nix/var/nix/profiles/system
# will be set later
sshOpts=(
  -o "ControlMaster=auto"
  -o "ControlPersist=60"
  # Avoid issues with IP re-use. This disable TOFU security.
  -o "StrictHostKeyChecking=no"
  -o "UserKnownHostsFile=/dev/null"
  -o "GlobalKnownHostsFile=/dev/null"
  # interactive authentication is not possible
  -o "BatchMode=yes"
)
scpOpts=("${sshOpts[@]}")

###  Argument parsing ###

drvPath="$1"
outPath="$2"
targetHost="$3"
targetPort="$4"
buildOnTarget="$5"
sshPrivateKey="${sshPrivateKey:-}"
packedKeysJson="$6"
action="$7"
deleteOlderThan="$8"
performGC="$9"
verboseSSH="${10}"
shift 10

# remove the last argument
set -- "${@:1:$(($# - 1))}"
buildArgs+=("$@")

if [[ "${verboseSSH:-false}" == true ]]; then
  sshOpts+=( -v )
fi

sshOpts+=( -p "${targetPort}" )
scpOpts+=( -P "${targetPort}" )

workDir=$(mktemp -d)
trap 'rm -rf "$workDir"' EXIT

if [[ -n "${sshPrivateKey}" && "${sshPrivateKey}" != "-" ]]; then
  sshPrivateKeyFile="$workDir/ssh_key"
  echo "$sshPrivateKey" > "$sshPrivateKeyFile"
  chmod 0600 "$sshPrivateKeyFile"
  flag="IdentityFile=${sshPrivateKeyFile}"
  sshOpts+=( -o "$flag" )
  scpOpts+=( -o "$flag" )
fi

### Functions ###

log() {
  echo "--- $*" >&2
}

copyToTarget() {
  NIX_SSHOPTS="${sshOpts[*]}" nix-copy-closure --to "$targetHost" "$@"
}

remoteTempDir=""
makeRemoteTempDir() {
  remoteTempDir=$(ssh "${sshOpts[@]}" "$targetHost" "mktemp -d")
}

# assumes that passwordless sudo is enabled on the server
targetHostCmd() {
  # ${*@Q} escapes the arguments losslessly into space-separted quoted strings.
  # `ssh` did not properly maintain the array nature of the command line,
  # erroneously splitting arguments with internal spaces, even when using `--`.
  # Tested with OpenSSH_7.9p1.
  #
  # shellcheck disable=SC2029
  ssh "${sshOpts[@]}" "$targetHost" "'$remoteTempDir/maybe-sudo.sh' ${*@Q}"
}

# Setup a temporary ControlPath for this session. This speeds-up the
# operations by not re-creating SSH sessions between each command. At the end
# of the run, the session is forcefully terminated.
setupControlPath() {
  local flag="ControlPath=$workDir/ssh_control"
  sshOpts+=(-o "$flag")
  scpOpts+=(-o "$flag")
  cleanupControlPath() {
    local ret=$?
    # Avoid failing during the shutdown
    set +e
    # Close ssh multiplex-master process gracefully
    log "closing persistent ssh-connection"
    ssh "${sshOpts[@]}" -O stop "$targetHost"
    rm -rf "$workDir"
    exit "$ret"
  }
  trap cleanupControlPath EXIT
}

### Main ###

setupControlPath

makeRemoteTempDir
unpackKeysPath="$remoteTempDir/unpack-keys.sh"
maybeSudoPath="$remoteTempDir/maybe-sudo.sh"
packedKeysPath="$remoteTempDir/packed-keys.json"
scriptDir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
scp "${scpOpts[@]}" "$scriptDir/unpack-keys.sh" "$targetHost:$unpackKeysPath"
scp "${scpOpts[@]}" "$scriptDir/maybe-sudo.sh" "$targetHost:$maybeSudoPath"
echo "$packedKeysJson" | ssh "${sshOpts[@]}" "$targetHost" "cat > '$packedKeysPath'"
ssh "${sshOpts[@]}" "$targetHost" "chmod +x '$maybeSudoPath' '$unpackKeysPath' 1>/dev/null"
ssh "${sshOpts[@]}" "$targetHost" "'$maybeSudoPath' '$unpackKeysPath' '$packedKeysPath' 1>/dev/null"

if [[ "${buildOnTarget:-false}" == true ]]; then

  # Upload derivation
  log "uploading derivations"
  copyToTarget "$drvPath" --gzip --use-substitutes

  # Build remotely
  log "building on target"
  set -x
  targetHostCmd "nix-store" "--realize" "$drvPath" "${buildArgs[@]}"

else

  # Build derivation
  log "building on deployer"
  outPath=$(nix-store --realize "$drvPath" "${buildArgs[@]}")

  # Upload build results
  log "uploading build results"
  copyToTarget "$outPath" --gzip --use-substitutes

fi

# Activate
log "activating configuration"
targetHostCmd nix-env --profile "$profile" --set "$outPath"
targetHostCmd "$outPath/bin/switch-to-configuration" "$action"

# Cleanup previous generations
log "collecting old nix derivations"
# Deliberately not quoting $deleteOlderThan so the user can configure something like "1 2 3" 
# to keep generations with those numbers
targetHostCmd "nix-env" "--profile" "$profile" "--delete-generations" $deleteOlderThan
if [[ "${performGC:-true}" == true ]]; then
  targetHostCmd "nix-store" "--gc"
fi
