# Get current Azure client config for tenant_id and object_id
data "azurerm_client_config" "current" {}

locals {
  resource_name_prefix = "${var.environment}-${random_string.suffix.result}"
  common_tags          = merge(var.tags, { Environment = var.environment })
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

# Resource Group
resource "azurerm_resource_group" "main" {
  name     = "${var.resource_group_name}-${var.environment}"
  location = var.location
  tags     = local.common_tags
}

# Networking Module
module "networking" {
  source = "./modules/networking"

  resource_group_name      = azurerm_resource_group.main.name
  location                 = var.location
  resource_name_prefix     = local.resource_name_prefix
  vnet_address_space       = var.vnet_address_space
  public_subnet_prefixes   = var.public_subnet_prefixes
  private_subnet_prefixes  = var.private_subnet_prefixes
  database_subnet_prefixes = var.database_subnet_prefixes
  bastion_subnet_prefix    = var.bastion_subnet_prefix
  appgw_subnet_prefix      = var.appgw_subnet_prefix
  tags                     = local.common_tags
}

# Key Vault
module "keyvault" {
  source = "./modules/keyvault"

  resource_group_name  = azurerm_resource_group.main.name
  location             = var.location
  resource_name_prefix = local.resource_name_prefix
  tenant_id            = data.azurerm_client_config.current.tenant_id
  object_id            = data.azurerm_client_config.current.object_id
  tags                 = local.common_tags

  depends_on = [module.database]
}

# After Key Vault is created, store database credentials as secrets
resource "azurerm_key_vault_secret" "db_host" {
  name         = "db-host"
  value        = module.database.server_fqdn
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault, module.database]
}

resource "azurerm_key_vault_secret" "db_username" {
  name         = "db-username"
  value        = module.database.administrator_login
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault, module.database]
}

resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = module.database.administrator_password
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault, module.database]
}

resource "azurerm_key_vault_secret" "db_name" {
  name         = "db-name"
  value        = var.postgres_db_name
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault]
}

# Add DB port and SSL mode to Key Vault
resource "azurerm_key_vault_secret" "db_port" {
  name         = "db-port"
  value        = tostring(var.postgres_db_port)
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault]
}

resource "azurerm_key_vault_secret" "db_sslmode" {
  name         = "db-sslmode"
  value        = var.postgres_db_sslmode
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault]
}

# Store Docker Hub credentials in Key Vault
resource "azurerm_key_vault_secret" "dockerhub_username" {
  name         = "dockerhub-username"
  value        = var.dockerhub_username
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault]
}

resource "azurerm_key_vault_secret" "dockerhub_pat" {
  name         = "dockerhub-pat"
  value        = var.dockerhub_password
  key_vault_id = module.keyvault.key_vault_id

  depends_on = [module.keyvault]
}

# Database
module "database" {
  source = "./modules/database"

  resource_group_name  = azurerm_resource_group.main.name
  location             = var.location
  resource_name_prefix = local.resource_name_prefix
  database_subnet_ids  = module.networking.database_subnet_ids
  private_dns_zone_id  = module.dns.private_dns_zone_id
  postgres_sku_name    = var.postgres_sku_name
  postgres_version     = var.postgres_version
  postgres_storage_mb  = var.postgres_storage_mb
  postgres_db_name     = var.postgres_db_name
  tags                 = local.common_tags

  depends_on = [module.dns]
}

# DNS for Private Endpoints
module "dns" {
  source = "./modules/dns"

  resource_group_name = azurerm_resource_group.main.name
  vnet_id             = module.networking.vnet_id
  tags                = local.common_tags
}

# Compute - Backend VMSS (deploy first)
module "backend" {
  count  = var.deploy_compute ? 1 : 0
  source = "./modules/compute"

  resource_group_name  = azurerm_resource_group.main.name
  location             = var.location
  resource_name_prefix = local.resource_name_prefix
  subnet_id            = module.networking.private_subnet_ids[0]
  appgw_subnet_id      = module.networking.appgw_subnet_id
  vm_size              = var.backend_vm_size
  instance_count       = var.backend_instances
  admin_username       = var.admin_username
  dockerhub_username   = var.dockerhub_username
  dockerhub_password   = var.dockerhub_password
  docker_image         = var.backend_image
  is_frontend          = false
  application_port     = 8080
  health_probe_path    = "/health"
  key_vault_id         = module.keyvault.key_vault_id
  backend_load_balancer_ip = null
  tags                 = local.common_tags

  database_connection = {
    host     = module.database.server_fqdn
    port     = var.postgres_db_port
    username = module.database.administrator_login
    password = module.database.administrator_password
    dbname   = var.postgres_db_name
    sslmode  = var.postgres_db_sslmode
  }

  depends_on = [
    module.keyvault,
    module.database
  ]
}

# Compute - Frontend VMSS
module "frontend" {
  count  = var.deploy_compute ? 1 : 0
  source = "./modules/compute"

  resource_group_name  = azurerm_resource_group.main.name
  location             = var.location
  resource_name_prefix = local.resource_name_prefix
  subnet_id            = module.networking.public_subnet_ids[0]
  appgw_subnet_id      = module.networking.appgw_subnet_id
  vm_size              = var.frontend_vm_size
  instance_count       = var.frontend_instances
  admin_username       = var.admin_username
  dockerhub_username   = var.dockerhub_username
  dockerhub_password   = var.dockerhub_password
  docker_image         = var.frontend_image
  is_frontend          = true
  application_port     = 3000
  health_probe_path    = "/"
  key_vault_id         = module.keyvault.key_vault_id
  backend_load_balancer_ip = var.deploy_compute ? module.backend[0].load_balancer_private_ip : null
  tags                 = local.common_tags

  depends_on = [
    module.keyvault,
    module.backend
  ]
}

# Update Key Vault with backend identity
resource "azurerm_key_vault_access_policy" "backend_policy" {
  count        = var.deploy_compute ? 1 : 0
  key_vault_id = module.keyvault.key_vault_id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = module.backend[0].identity_principal_id

  secret_permissions = [
    "Get", "List"
  ]

  depends_on = [
    module.keyvault,
    module.backend
  ]
}

# ============================================================================
# Application Gateway (moved from compute module to prevent Terraform resets)
# ============================================================================

# Public IP for Application Gateway
resource "azurerm_public_ip" "appgw_pip" {
  count               = var.deploy_compute ? 1 : 0
  name                = "${local.resource_name_prefix}-appgw-pip"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.common_tags
}

# Application Gateway
resource "azurerm_application_gateway" "appgw" {
  count               = var.deploy_compute ? 1 : 0
  name                = "${local.resource_name_prefix}-appgw"
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  tags                = local.common_tags

  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "gateway-ip-config"
    subnet_id = module.networking.appgw_subnet_id
  }

  frontend_port {
    name = "http-port"
    port = 80
  }

  frontend_ip_configuration {
    name                 = "frontend-ip-config"
    public_ip_address_id = azurerm_public_ip.appgw_pip[0].id
  }

  backend_address_pool {
    name = "backend-pool"
  }

  backend_http_settings {
    name                  = "http-settings"
    cookie_based_affinity = "Disabled"
    port                  = 8080
    protocol              = "Http"
    request_timeout       = 60
    probe_name            = "health-probe"
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "frontend-ip-config"
    frontend_port_name             = "http-port"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "routing-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 1
  }

  probe {
    name                = "health-probe"
    host                = "10.0.3.4"
    interval            = 30
    timeout             = 30
    unhealthy_threshold = 3
    protocol            = "Http"
    port                = 8080
    path                = "/health"
  }

  waf_configuration {
    enabled          = true
    firewall_mode    = "Prevention"
    rule_set_type    = "OWASP"
    rule_set_version = "3.2"
  }

  depends_on = [module.backend, module.frontend]
}
