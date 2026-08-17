fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_furniture'
author 'Mazus / MZ Core'
description 'Catalogo e dominio seguro de moveis residenciais e organizacionais'
version '0.10.0'

shared_scripts {
  '@ox_lib/init.lua',
  'shared/config.lua',
  'shared/catalog_seed.lua',
  'shared/logic.lua'
}

client_scripts {
  'client/main.lua',
  'client/placement.lua',
  'client/menu.lua'
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/database.lua',
  'server/repository.lua',
  'server/organization.lua',
  'server/organization_purchase.lua',
  'server/catalog.lua',
  'server/money.lua',
  'server/resale.lua',
  'server/purchase.lua',
  'server/residential.lua',
  'server/placement.lua',
  'server/ownership.lua',
  'server/player.lua',
  'server/main.lua'
}

dependencies {
  'oxmysql',
  'ox_lib',
  'mz_core',
  'mz_interiors',
  'mz_houses',
  'mz_menu',
  'mz_world_editor'
}
