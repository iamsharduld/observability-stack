terraform {
  required_version = ">= 1.5"
  required_providers {
    juju = {
      source  = "juju/juju"
      version = ">= 1.0"
    }
  }
}

variable "model" {
  type = string
}

data "juju_model" "model" {
  name  = var.model
  owner = "admin"
}

module "cos-lite" {
  source       = "git::https://github.com/canonical/observability-stack//terraform/cos-lite?ref=track/3.0"
  model        = { uuid = data.juju_model.model.uuid }
  risk         = var.risk
  internal_tls = true
}

# Risk of the upgrade target; override with TF_VAR_risk (e.g. beta)
variable "risk" {
  type    = string
  default = "edge"
}
