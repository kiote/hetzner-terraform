resource "azurerm_resource_group" "longlegs" {
  name     = "longlegs-resources"
  location = "North Europe"

  tags = var.common_tags
}

resource "azurerm_virtual_network" "longlegs" {
  name                = "longlegs-network"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.longlegs.location
  resource_group_name = azurerm_resource_group.longlegs.name

  tags = var.common_tags
}

resource "azurerm_subnet" "longlegs" {
  name                 = "longlegs-subnet"
  resource_group_name  = azurerm_resource_group.longlegs.name
  virtual_network_name = azurerm_virtual_network.longlegs.name
  address_prefixes     = ["10.0.2.0/24"]
}

resource "azurerm_network_interface" "longlegs" {
  name                = "longlegs-nic"
  location            = azurerm_resource_group.longlegs.location
  resource_group_name = azurerm_resource_group.longlegs.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.longlegs.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.longlegs.id
  }

  tags = var.common_tags
}

resource "azurerm_public_ip" "longlegs" {
  name                = "longlegs-pip"
  location            = azurerm_resource_group.longlegs.location
  resource_group_name = azurerm_resource_group.longlegs.name
  allocation_method   = "Dynamic"

  tags = var.common_tags
}

resource "azurerm_network_security_group" "longlegs" {
  name                = "longlegs-nsg"
  location            = azurerm_resource_group.longlegs.location
  resource_group_name = azurerm_resource_group.longlegs.name

  security_rule {
    name                       = "allow-https"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-ssh"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  // to allow letsencrypt to validate and renew the certificate
  security_rule {
    name                       = "allow-http"
    priority                   = 1003
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }


  tags = var.common_tags
}

resource "azurerm_network_interface_security_group_association" "longlegs" {
  network_interface_id      = azurerm_network_interface.longlegs.id
  network_security_group_id = azurerm_network_security_group.longlegs.id
}

resource "azurerm_virtual_machine" "longlegs" {
  name                  = "longlegs-vm"
  location              = azurerm_resource_group.longlegs.location
  resource_group_name   = azurerm_resource_group.longlegs.name
  network_interface_ids = [azurerm_network_interface.longlegs.id]
  vm_size               = "Standard_B2s"

  tags = var.common_tags

  storage_os_disk {
    name              = "longlegs-os-disk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS"
  }

  storage_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  os_profile {
    computer_name  = "longlegs-vm"
    admin_username = "${var.ansible_user}"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      path     = "/home/${var.ansible_user}/.ssh/authorized_keys"
      key_data = file("~/.ssh/id_ed25519.pub")
    }
  }
}

resource "azurerm_key_vault" "longlegs" {
  name                        = "longlegs-keyvault"
  location                    = azurerm_resource_group.longlegs.location
  resource_group_name         = azurerm_resource_group.longlegs.name
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  purge_protection_enabled    = true

  tags = var.common_tags
}

resource "azurerm_key_vault_access_policy" "longlegs" {
  key_vault_id = azurerm_key_vault.longlegs.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Recover",
    "Backup",
    "Restore",
  ]
}

resource "azurerm_key_vault_secret" "license_file" {
  name         = "license-file"
  value        = filebase64("${var.path_to_license_file}")
  key_vault_id = azurerm_key_vault.longlegs.id

  tags = var.common_tags

  depends_on = [
    azurerm_key_vault_access_policy.longlegs
  ]
}

resource "null_resource" "copy_license_to_remote" {
  provisioner "local-exec" {
    command = <<EOT
      echo "${base64decode(azurerm_key_vault_secret.license_file.value)}" > /tmp/pysmile_license.py
    EOT
  }

  provisioner "file" {
    source      = "/tmp/pysmile_license.py"
    destination = "/tmp/pysmile_license.py"

    connection {
      type        = "ssh"
      user        = var.ansible_user
      private_key = file("~/.ssh/id_ed25519")
      host        = azurerm_public_ip.longlegs.ip_address
    }
  }

  depends_on = [
    azurerm_key_vault_secret.license_file
  ]
}

# Create a subnet for PostgreSQL
resource "azurerm_subnet" "postgres" {
  name                 = "postgres-subnet"
  resource_group_name  = azurerm_resource_group.longlegs.name
  virtual_network_name = azurerm_virtual_network.longlegs.name
  address_prefixes     = ["10.0.3.0/24"]
  
  delegation {
    name = "fs"
    service_delegation {
      name = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
      ]
    }
  }
}

# Create a private DNS zone for PostgreSQL
resource "azurerm_private_dns_zone" "postgres" {
  name                = "longlegs.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.longlegs.name

  tags = var.common_tags
}

# Link the DNS zone to the virtual network
resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "postgres-dns-link"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  resource_group_name   = azurerm_resource_group.longlegs.name
  virtual_network_id    = azurerm_virtual_network.longlegs.id
  registration_enabled  = true

  tags = var.common_tags
}

# Create PostgreSQL Flexible Server
resource "azurerm_postgresql_flexible_server" "longlegs" {
  name                   = "longlegs-postgres"
  resource_group_name    = azurerm_resource_group.longlegs.name
  location               = azurerm_resource_group.longlegs.location
  version                = "14"
  delegated_subnet_id    = azurerm_subnet.postgres.id
  private_dns_zone_id    = azurerm_private_dns_zone.postgres.id
  
  # Most cost-effective configuration
  sku_name              = "B_Standard_B1ms"
  storage_mb            = 32768 # Minimum storage (32GB)
  
  administrator_login    = "psqladmin"
  administrator_password = random_password.postgres_password.result

  # Disable public network access
  public_network_access_enabled = false

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgres
  ]

  tags = var.common_tags
}

# Generate random password for PostgreSQL
resource "random_password" "postgres_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Store the PostgreSQL password in Key Vault
resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-password"
  value        = random_password.postgres_password.result
  key_vault_id = azurerm_key_vault.longlegs.id

  tags = var.common_tags

  depends_on = [
    azurerm_key_vault_access_policy.longlegs
  ]
}

# Create a database in the PostgreSQL server
resource "azurerm_postgresql_flexible_server_database" "longlegs" {
  name      = "longlegs_db"
  server_id = azurerm_postgresql_flexible_server.longlegs.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}
