# Configure the Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 2.37"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 0.8"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 2.2"
    }
    null = {
      source = "hashicorp/null"
      version = "~> 3.0.0"
    }
  }

  backend "azurerm" {
    resource_group_name  = "DevOps"
    storage_account_name = "stweuaquilaterraform"
    container_name       = "state"
    key                  = "learn.001.tfstate"
  }
}

provider "azurerm" {
  features {}
}

provider "random" {
  version = "~> 2.2"
}

provider "null" {
  version = "~> 3.0.0"
}

resource "random_id" "namespace_id" {
  byte_length = 2
}

variable "environment" {
  type        = string
  description = "Deployment environment"
  default     = "dev"

  validation {
    condition = contains(
      ["dev", "fb", "int", "test", "qual", "prod"],
      var.environment
    )
    error_message = (
      "Allowed values are: \"dev\", \"fb\", \"int\", \"test\", \"qual\", \"prod\"."
    )
  }
}

variable "spa_host_name" {
  type        = string
  description = "SPA hostname used to construct redirect URL"
  default     = "localhost:4200"
}

variable "api_host_name" {
  type        = string
  description = "API hostname used to construct redirect URL"
  default     = "localhost:4300"
}

data "azuread_group" "waternet_admins" {
  name = "AAD_SG SPA Admins"
}

output "waternet_admins_members" {
  value       = data.azuread_group.waternet_admins.members
  description = "Members of the waternet admins group"
}

locals {
  spa_url                              = "https://${var.spa_host_name}"
  api_url                              = "https://${var.api_host_name}"
  namespace                            = lower(substr(random_id.namespace_id.hex, 0, 3))
  microsoft_graph_application_id       = "00000003-0000-0000-c000-000000000000"
  microsoft_graph_permission_openid    = "37f7f235-527c-4136-accd-4a02d197296e"
  microsoft_graph_permission_profile   = "14dad69e-099b-42c9-810b-d002981feec1"
  microsoft_graph_permission_user_read = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"
  microsoft_graph_permission_mail_send = "e383f46e-2787-4529-855e-0e479a3ffac0"
}

resource "azuread_application" "spa" {
  name     = "Aquanet SPA ${var.environment}-${local.namespace}"
  homepage = local.spa_url

  reply_urls = [local.spa_url]

  owners = data.azuread_group.waternet_admins.members

  available_to_other_tenants = true

  oauth2_allow_implicit_flow = true
  oauth2_permissions         = []

  required_resource_access {
    resource_app_id = local.microsoft_graph_application_id

    resource_access {
      id   = local.microsoft_graph_permission_openid
      type = "Scope"
    }

    resource_access {
      id   = local.microsoft_graph_permission_profile
      type = "Scope"
    }

    resource_access {
      id   = local.microsoft_graph_permission_user_read
      type = "Scope"
    }

    resource_access {
      id   = local.microsoft_graph_permission_mail_send
      type = "Scope"
    }
  }

  required_resource_access {
    resource_app_id = azuread_application.api.application_id

    dynamic "resource_access" {
      for_each = azuread_application.api.oauth2_permissions

      content {
        id   = resource_access.value.id
        type = "Scope"
      }
    }
  }
}

resource "azuread_service_principal" "spa" {
  application_id               = azuread_application.spa.application_id
  app_role_assignment_required = true
}

resource "azuread_application" "api" {
  name     = "Aquanet API ${var.environment}-${local.namespace}"
  homepage = local.api_url
  identifier_uris = [
    "api://aquanet-api-${var.environment}-${local.namespace}"
  ]

  owners = data.azuread_group.waternet_admins.members

  available_to_other_tenants = true

  oauth2_permissions {
    admin_consent_display_name = "Access Waternet API"
    admin_consent_description = (
      "Allow the application to access the Waternet API on behalf of the signed-in user."
    )

    user_consent_display_name = "Access Waternet API"
    user_consent_description = (
      "Allow the application to access the Waternet API on your behalf."
    )

    type       = "User"
    value      = "user_impersonation"
    is_enabled = true
  }
}

resource "null_resource" "api_known_clients" {
  provisioner "local-exec" {
    # Can't use 'az ad app update' because it fails on the second run due to a duplicate value error
    # This az rest command fails in CMD because of escaping but works in PS and bash
    command = "az rest --method PATCH --uri https://graph.microsoft.com/beta/applications/${azuread_application.api.id} --headers Content-Type=application/json --b \"{\\\"api\\\":{\\\"knownClientApplications\\\":[\\\"${azuread_application.spa.application_id}\\\"]}}\""
  }
}

resource "null_resource" "api_pre_authorised_apps" {
  provisioner "local-exec" {
    # Can't use 'az ad app update' because it just doesn't work, might be a bug in the az cli.
    # This az rest command fails in CMD because of escaping but works in PS and bash
    command = "az rest --method PATCH --uri https://graph.microsoft.com/beta/applications/${azuread_application.api.id} --headers Content-Type=application/json --b \"{\\\"api\\\":{\\\"preAuthorizedApplications\\\":[{\\\"appId\\\":\\\"${azuread_application.spa.application_id}\\\",\\\"permissionIds\\\":${replace(jsonencode(azuread_application.api.oauth2_permissions[*].id),"\"","\\\"")}}]}}\""

  }
}
