# mz_furniture

Domínio de móveis do MZ Core. A versão `0.9.0` preserva a implementação residencial
das Fases 0–7 e adiciona a fundação fail-closed de compra coletiva:
catálogo administrável, autoridade residencial owner-only, loja com pagamento
bancário idempotente, depósito pessoal, placement visual, runtime sincronizado e
revenda segura.

O jogador abre a loja com `/moveis` (alias `/furniture`). Dentro da própria
residência, um móvel do depósito pode ser posicionado, movido ou guardado novamente.
O editor controla o objeto sem deslocar o personagem e usa uma câmera temporária
que acompanha o móvel. O mesmo menu também pode ser aberto visualmente pelo painel
`/house` de uma propriedade com a feature `furniture` habilitada.

## Inicialização

O `mz_starter/cfg/resources.cfg` inicia `mz_interiors`, `mz_houses` e
`mz_furniture` depois do `mz_core`. Com `AutoCreateTables = true`, as cinco tabelas
e as migrações idempotentes são aplicadas automaticamente. `install.sql` oferece a
mesma estrutura para instalação manual.

O seed contém 14 itens revisados e habilitados, distribuídos entre sala, cozinha,
quarto, banheiro, escritório e decoração. Em instalações anteriores, o
bootstrap só habilita automaticamente as linhas originais e ainda intocadas do
seed (`system:seed`, revisão 1); alterações administrativas são preservadas.

Em servidores já existentes, os cargos Staff são preservados pelo seed do
`mz_core`. Conceda `staff.furniture.view` ao cargo que deve enxergar o catálogo.
Novas instalações atribuem as permissões de móveis ao cargo `gerente_staff`.

## Ownership e compra organizacional

A tabela de unidades possui agora o escopo genérico `owner_type + owner_key`.
Linhas residenciais existentes são migradas para `player + lower(citizenid)` e
novas compras residenciais gravam os campos antigo e novo na mesma transação.

O schema agora aceita ownership real de organização com `owner_type=org`,
`owner_key=<org_code>` e `owner_citizenid=NULL`. A compra coletiva cria uma cotação
curta no servidor, debita a conta da organização por operação idempotente e entrega
o item diretamente no depósito coletivo. Falha de grant tenta reembolso; resultado
financeiro ambíguo entra em recuperação/manual review.

O código não libera esse gameplay sozinho. As flags
`OrganizationOwnershipEnabled`, `OrganizationPurchasesEnabled` e
`OrganizationPlacementEnabled` continuam desligadas. Todas as mutações e rotinas
de recuperação residenciais exigem explicitamente `owner_type=player`, portanto
uma futura linha `org` não pode ser vendida, guardada ou recolhida pelo fluxo de
uma casa.

Após o primeiro restart com a migração, execute no console do servidor:

```txt
mfurniture_owner_schema
```

O resultado aprovado contém `ready=yes`, `org_ready=yes`, `invalid_rows=0`,
`org_gameplay=disabled` e `error=none`.

## Depósito organizacional somente leitura

Membros com `facility.furniture.view` recebem no `/moveis` o contexto de suas
organizações. A abertura é revalidada no servidor e exige vínculo ativo, capability,
schema de owner aprovado e ao menos uma facility ativa confirmada pelo
`mz_org_activities`.

Com as flags atuais, o depósito não oferece compra, placement, movimentação,
armazenamento ou revenda.
O payload enviado ao client omite IDs técnicos e dados de modelo. Tentativas
negadas são auditadas e o callback possui rate limit.

Diagnóstico pelo console:

```txt
mfurniture_org_warehouse <player_id> mafia
mfurniture_org_purchase_status <player_id> mafia
```

Enquanto as facilities reais continuarem desligadas, o resultado seguro é
`available=no reason=organization_facility_unavailable`. Com uma facility ativa,
mas sem liberar compra, o resultado passa a
`available=yes read_only=yes purchases=no`.

Quando a facility real estiver calibrada e as flags de ownership/compra forem
habilitadas, membros com `facility.furniture.buy` verão a loja coletiva. A compra
usa exclusivamente a conta da organização e nunca cria placement automaticamente.
O checklist completo está em
`docs/MZ_ORG_FACILITIES_PHASE_4_ORG_PURCHASE.md`.

## Fluxo de compra

1. O servidor entrega ao jogador um catálogo sem nomes ou hashes de modelos.
2. Ao selecionar um item, o servidor cria uma cotação curta vinculada ao cidadão.
3. Na confirmação, preço, revisão, validade e ownership da cotação são revalidados.
4. O débito usa exclusivamente a conta bancária e uma chave idempotente.
5. A transação financeira e o móvel criado ficam relacionados por chave única.
6. Se o grant falhar após o débito, o sistema tenta reembolso idempotente.
7. Resultado financeiro ambíguo entra em `manual_review`; novas compras ficam
   bloqueadas até a reconciliação automática confirmar débito ou reembolso.

O reconnect relê o depósito do banco. Duplo clique ou reenvio do mesmo token não
gera uma segunda cobrança nem uma segunda unidade.

## Flags

- `Enabled`: chave geral do domínio.
- `CatalogEnabled`: expõe apenas itens habilitados e não arquivados.
- `PurchasesEnabled`: autoriza cotação, débito bancário e depósito.
- `PlacementEnabled`: autoriza placement owner-only dentro de shells calibrados.
- `RuntimeSyncEnabled`: envia snapshots e updates aos ocupantes da mesma instância.
- `ResaleEnabled`: autoriza revenda somente de unidades guardadas no depósito.
- `OwnerReconciliationEnabled`: recolhe móveis quando o owner da casa muda e ativa
  a verificação periódica de consistência.
- `ResidentialAuthorityEnabled`: mantém a validação segura de propriedade,
  sessão, bucket e bounds.

## Autoridade residencial

`mz_houses:CanDecorateProperty` exige proprietário real dentro da própria
residência, feature `furniture`, sessão confirmada, bucket correto e shell com
bounds. Chaves, guests, Staff sem ownership, propriedades públicas/organizacionais
e shells sem bounds falham fechados.

O `mz_furniture` revalida essa autoridade a cada consulta. Eventos de entrada e
saída apenas atualizam o cache e nunca são aceitos como prova de acesso.

## Placement

No depósito, selecione um item e use `Posicionar`. Para um item já colocado na casa,
use `Mover` ou `Guardar no depósito`.

Controles:

- `W/A/S/D`: move o objeto;
- mouse: orbita a câmera;
- scroll: aproxima ou afasta;
- setas esquerda/direita: gira;
- segure `Page Up/Page Down`: sobe ou desce continuamente;
- `Shift`: movimento rápido;
- `Ctrl`: movimento preciso;
- `R`: encaixa no ponto central da mira;
- `G`: alinha o objeto ao chão;
- `X`: restaura a rotação inicial;
- `E`: confirma quando o contorno estiver verde;
- `Backspace`: cancela e restaura o estado anterior.

O preview é local, transparente e sem colisão. A confirmação ainda é revalidada no
servidor contra owner, sessão, bucket, revisão, limites e zonas bloqueadas. Apenas
`shell_test` está calibrada no rollout inicial; outros shells falham fechados até
receberem bounds revisados.

## Sincronização residencial

Cada ocupante com sessão interior confirmada recebe o snapshot completo da
propriedade ao entrar. Colocar, mover ou guardar produz updates incrementais apenas
para jogadores no mesmo `propertyId` e routing bucket.

Visitantes, moradores com chave e o proprietário enxergam os mesmos móveis. A
autorização de visualização não concede edição: `beginPlacement`,
`submitPlacement` e `storeFurniture` continuam owner-only.

As entidades são locais por cliente, deduplicadas pela revisão persistida e
removidas imediatamente ao sair. O runtime carrega em pequenos lotes e usa
distância com histerese para evitar criação e remoção repetitiva.

## Revenda

No depósito, selecione o móvel e escolha `Vender para a loja`. A cotação usa o
preço histórico daquela unidade e o percentual configurado no catálogo; alterações
posteriores no preço da loja não aumentam o valor de revenda. Após confirmação, o
crédito vai para a conta bancária e o item passa a `sold`.

O item é reservado como `selling` antes do crédito. Falha bancária confirmada o
devolve ao depósito; resultado ambíguo entra em `manual_review` e é conciliado por
chave idempotente no próximo acesso. O crédito de revenda não conta como renda
produtiva nas métricas econômicas.

## Transferência e recuperação

`mz_houses` emite `propertyOwnershipChanged` com owner anterior, novo owner,
propriedade e motivo. Quando existe owner anterior, todos os móveis colocados por
ele são retirados da residência e devolvidos ao depósito pessoal, mesmo que o
jogador esteja offline. O novo proprietário recebe a casa sem o layout antigo.

O recolhimento é transacional e idempotente. Além do evento imediato, uma
verificação roda no startup e a cada `OwnerReconciliationIntervalSeconds`, limitada
por `OwnerReconciliationBatchSize`. Ela corrige ownership divergente, item marcado
como colocado sem placement e placement ativo sem item compatível.

Staff com `staff.furniture.recovery` pode consultar inconsistências no `mz_admin`,
executar a verificação e conciliar compras/revendas de um jogador online. Operações
financeiras ambíguas continuam visíveis e nunca são forçadas sem consultar o
resultado idempotente do banco.

## Testes

Na raiz do repositório:

```powershell
lua mz_furniture/tests/catalog_logic_harness.lua
lua mz_furniture/tests/catalog_seed_harness.lua
lua mz_furniture/tests/state_machine_harness.lua
lua mz_furniture/tests/placement_logic_harness.lua
lua mz_furniture/tests/schema_contract_harness.lua
lua mz_furniture/tests/residential_contract_harness.lua
lua mz_furniture/tests/financial_contract_harness.lua
lua mz_furniture/tests/purchase_flow_harness.lua
lua mz_furniture/tests/resale_flow_harness.lua
lua mz_furniture/tests/player_experience_contract_harness.lua
lua mz_furniture/tests/ownership_reconciliation_harness.lua
lua mz_furniture/tests/phase7_contract_harness.lua
lua mz_furniture/tests/placement_contract_harness.lua
lua mz_furniture/tests/placement_flow_harness.lua
lua mz_furniture/tests/sync_contract_harness.lua
lua mz_furniture/tests/owner_scope_logic_harness.lua
lua mz_furniture/tests/owner_scope_repository_harness.lua
lua mz_furniture/tests/org_owner_foundation_contract_harness.lua
lua mz_furniture/tests/organization_warehouse_read_harness.lua
lua mz_furniture/tests/organization_purchase_flow_harness.lua
lua mz_houses/tests/decoration_policy_harness.lua
lua mz_interiors/tests/furniture_bounds_harness.lua
```
