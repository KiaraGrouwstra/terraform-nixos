variable "target_host" {
  type        = string
  description = "DNS host to deploy to"
}

variable "target_user" {
  type        = string
  description = "SSH user used to connect to the target_host"
  default     = "root"
}

variable "target_port" {
  type        = number
  description = "SSH port used to connect to the target_host"
  default     = 22
}

variable "ssh_private_key" {
  type        = string
  description = "Content of private key used to connect to the target_host"
  default     = ""
}

variable "ssh_private_key_file" {
  type        = string
  description = "Path to private key used to connect to the target_host"
  default     = ""
}

variable "ssh_agent" {
  type        = bool
  description = "Whether to use an SSH agent. True if not ssh_private_key is passed"
  default     = null
}

variable "NIX_PATH" {
  type        = string
  description = "Allow to pass custom NIX_PATH"
  default     = ""
}

variable "nixos_config" {
  type        = string
  description = "Path to a NixOS configuration"
  default     = ""
}

variable "config" {
  type        = string
  description = "NixOS configuration to be evaluated. This argument is required unless 'nixos_config' is given"
  default     = ""
}

variable "config_pwd" {
  type        = string
  description = "Directory to evaluate the configuration in. This argument is required if 'config' is given"
  default     = ""
}

variable "extra_eval_args" {
  type        = list(string)
  description = "List of arguments to pass to the nix evaluation"
  default     = []
}

variable "extra_build_args" {
  type        = list(string)
  description = "List of arguments to pass to the nix builder"
  default     = []
}

variable "build_on_target" {
  type        = string
  description = "Avoid building on the deployer. Must be true or false. Has no effect when deploying from an incompatible system. Unlike remote builders, this does not require the deploying user to be trusted by its host."
  default     = false
}

variable "triggers" {
  type        = map(string)
  description = "Triggers for deploy"
  default     = {}
}

variable "keys" {
  type        = map(string)
  description = "A map of filename to content to upload as secrets in /var/keys"
  default     = {}
}

variable "target_system" {
  type        = string
  description = "Nix system string"
  default     = "x86_64-linux"
}

variable "hermetic" {
  type        = bool
  description = "Treat the provided nixos configuration as a hermetic expression and do not evaluate using the ambient system nixpkgs. Useful if you customize eval-modules or use a pinned nixpkgs."
  default     = false
}

variable "delete_older_than" {
  type        = string
  description = "Can be a list of generation numbers, the special value old to delete all non-current generations, a value such as 30d to delete all generations older than the specified number of days (except for the generation that was active at that point in time), or a value such as +5 to keep the last 5 generations ignoring any newer than current, e.g., if 30 is the current generation +5 will delete generation 25 and all older generations."
  default     = "+1"
}

variable "deploy_environment" {
  type        = map(string)
  description = "Extra environment variables to be set during deployment."
  default     = {}
}

variable "perform_gc" {
  type        = bool
  description = "If false then no GC will be perfomed after the deploy."
  default     = true
}

variable "verbose_ssh" {
  type        = bool
  description = "If true the ssh connection will be made with verbose mode to aid debugging."
  default     = false
}

# --------------------------------------------------------------------------

locals {
  triggers = {
    deploy_nixos_drv  = data.external.nixos-instantiate.result["drv_path"]
    deploy_nixos_keys = sha256(jsonencode(var.keys))
  }

  extra_build_args = concat([
    "--option", "substituters", data.external.nixos-instantiate.result["substituters"],
    "--option", "trusted-public-keys", data.external.nixos-instantiate.result["trusted-public-keys"],
    ],
    var.extra_build_args,
  )
  ssh_private_key_file = var.ssh_private_key_file == "" ? "-" : var.ssh_private_key_file
  ssh_private_key      = local.ssh_private_key_file == "-" ? var.ssh_private_key : file(local.ssh_private_key_file)
  ssh_agent            = var.ssh_agent == null ? (local.ssh_private_key != "") : var.ssh_agent
  build_on_target      = data.external.nixos-instantiate.result["currentSystem"] != var.target_system ? true : tobool(var.build_on_target)
  packed_keys_json = jsonencode(var.keys)
}

# used to detect changes in the configuration
data "external" "nixos-instantiate" {
  program = concat([
    "${path.module}/nixos-instantiate.sh",
    var.NIX_PATH == "" ? "-" : var.NIX_PATH,
    var.config != "" ? var.config : var.nixos_config,
    var.config_pwd == "" ? "." : var.config_pwd,
    # end of positional arguments
    # start of pass-through arguments
    "--argstr", "system", var.target_system,
    "--arg", "hermetic", var.hermetic
    ],
    var.extra_eval_args,
  )
}

resource "null_resource" "deploy_nixos" {
  triggers = merge(var.triggers, local.triggers)

  # do the actual deployment
  provisioner "local-exec" {
    environment = merge(var.deploy_environment, {
      sshPrivateKey = local.ssh_private_key
    })
    interpreter = concat([
      "${path.module}/nixos-deploy.sh",
      data.external.nixos-instantiate.result["drv_path"],
      data.external.nixos-instantiate.result["out_path"],
      "${var.target_user}@${var.target_host}",
      var.target_port,
      local.build_on_target,
      local.packed_keys_json,
      "switch",
      var.delete_older_than,
      var.perform_gc,
      var.verbose_ssh
      ],
      local.extra_build_args
    )
    command = "ignoreme"
  }
}

# --------------------------------------------------------------------------

output "id" {
  description = "random ID that changes on every nixos deployment"
  value       = null_resource.deploy_nixos.id
}

