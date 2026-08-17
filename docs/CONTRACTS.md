# Contratos do domínio

## Catálogo

O servidor é a autoridade para código, modelo, preço, percentual de revenda,
footprint, limite por propriedade e estado habilitado. Entradas são normalizadas
por `MZFurnitureLogic.NormalizeCatalog`.

`ListCatalogForAdmin(source)` exige `staff.furniture.view` e retorna itens ativos,
arquivados, contadores e flags do rollout. O catálogo público contém apenas dados
de apresentação e preço; nomes e hashes dos objetos não chegam ao jogador antes
do placement.

## Compra e depósito

O callback de compra recebe somente o token da cotação. A cotação:

- pertence ao `citizenid` resolvido no servidor;
- expira em poucos segundos;
- contém `catalog_id`, preço e revisão capturados no servidor;
- é invalidada quando o item, o preço ou a revisão mudam;
- vira o `request_id` único da transação e a chave idempotente do banco.

Uma compra confirmada cria exatamente uma linha em `mz_owned_furniture`, inicialmente
em `warehouse`. A unidade mantém o preço histórico e uma relação única com
`purchase_transaction_id`. O depósito é do domínio de móveis e não ocupa peso ou
slots do inventário pessoal.

## Estados de item

Fluxo normal:

`warehouse -> placed -> warehouse -> selling -> sold`

`archived` é administrativo e só volta para `warehouse`. `sold` é terminal no fluxo
normal; recuperação exige auditoria própria.

## Estados financeiros

Fluxo de compra:

`pending -> initiated -> payment_pending -> money_removed -> committed`

Saídas de segurança:

- antes do débito: `cancelled` ou `failed`;
- depois de débito confirmado: `refunded` quando o grant falha;
- resultado bancário desconhecido: `manual_review`;
- reversão administrativa futura: `committed -> reversed`.

Débito e reembolso usam conta `bank`, `source_resource=mz_furniture`,
`source_type=furniture_store` e chaves idempotentes distintas. Uma exceção no
export financeiro é consultada em `GetOperationResult`; o sistema nunca devolve
dinheiro às cegas quando não sabe se o débito aconteceu.

No restart, estados anteriores ao pagamento falham com segurança. Estados que
podem ter movimentado dinheiro entram em reconciliação. Enquanto restar uma
transação recuperável, o cidadão pode consultar o depósito, mas não iniciar outra
compra.

## Revenda

A revenda aceita apenas uma unidade pertencente ao cidadão, em `warehouse`, sem
propriedade atual. A cotação é curta, vinculada ao owner e registra revisão do item,
preço histórico, percentual e valor calculado no servidor.

Antes de creditar o banco, uma transação atômica muda o item para `selling` e a
transação para `payment_pending`. Crédito confirmado finaliza ambos como `sold` e
`committed`. Falha confirmada devolve o item ao depósito; retorno desconhecido
mantém a reserva em `manual_review` até `GetOperationResult` confirmar se o crédito
existiu. Reenvio do token apenas reproduz o resultado e nunca credita novamente.

O ledger usa categoria `furniture_resale`, chave `<request_id>_resale`, e marca
`counts_as_income=false` e `counts_as_expense=false`, pois o valor recupera parte de
um gasto anterior e não representa renda produtiva.

## Placement

Transforms persistidos são relativos ao referencial da propriedade. Cada eixo deve
ser finito; offsets são limitados por `MaxPlacementOffset` e rotações por
`MaxAbsoluteRotation`.

O servidor emite um token temporário somente após confirmar:

- proprietário e `citizenid`;
- sessão interior e routing bucket;
- feature `furniture`;
- ownership e revisão do móvel;
- status `warehouse` para colocar ou `placed` na propriedade atual para mover;
- limites total e por item do catálogo.

O preview converte world → offset no client apenas para experiência visual. A
confirmação revalida todo o contexto, normaliza o transform e consulta
`ValidateFurniturePlacement` server-side. O token é consumido antes da mutação e
place/store usam transações; move usa compare-and-set da revisão.

`place`, `move` e `store` mantêm a máquina:

`warehouse -> placed -> warehouse`

Guardar marca o placement como removido sem apagar histórico. Reposicionar a mesma
unidade reativa a linha com uma nova revisão.

## Autoridade residencial

`CanDecorateProperty` é owner-only e não aceita bypass Staff. A autorização exige
residência de player (`house`, `apartment` ou `apartment_unit`), feature habilitada,
sessão interior confirmada, routing bucket inalterado e bounds válidos no shell.

`mz_houses:server:interiorSessionConfirmed` e
`mz_houses:server:interiorSessionEnded` são sinais internos de ciclo de vida. O
`mz_furniture` sempre reconsulta o export server-side antes de usar um contexto.

`ValidateResidentialOffset` combina a autoridade da propriedade com
`mz_interiors:ValidateFurniturePlacement`. Nenhuma mutação aceita somente a
validação visual do cliente.

## Runtime compartilhado

Há duas autoridades independentes:

- `CanViewPropertyFurniture`: exige sessão interior confirmada, bucket correto,
  propriedade residencial ativa, feature `furniture` e shell calibrado; aceita
  ocupantes legítimos, inclusive visitantes;
- `CanDecorateProperty`: mantém a exigência owner-only para qualquer mutação.

Na entrada, o servidor envia um snapshot apenas ao ocupante autorizado. Depois,
`upsertPlacement` e `removePlacement` são enviados somente às sessões cacheadas do
mesmo `propertyId` e bucket, com nova conferência do routing bucket.

O cliente mantém uma entidade local por `owned_furniture_id`. Revisões menores ou
iguais à já aplicada são ignoradas, inclusive remoções atrasadas. Ao sair da casa,
trocar de contexto ou parar um resource relacionado, todas as entidades locais e o
editor ativo são limpos.

## Mudança de proprietário e consistência

Após uma mutação confirmada, `mz_houses` emite
`mz_houses:server:propertyOwnershipChanged` com `houseCode`, `propertyId`,
`previousOwner`, `newOwner`, motivo e ator. O evento é informativo: a autoridade
continua sendo o owner persistido em `mz_houses`.

Quando o owner anterior existe e difere do novo, `mz_furniture` encerra os
placements ativos daquele cidadão e muda suas unidades de `placed` para
`warehouse` na mesma transação. O processo opera por `citizenid`, portanto não
depende de o antigo proprietário estar online. Repetir o mesmo evento resulta em
zero alterações.

Eventos perdidos não deixam o sistema inconsistente permanentemente. No startup e
periodicamente, um job limitado por lote compara owner do item, owner da casa,
status da unidade e placement ativo. O reparo cobre:

- móveis colocados em propriedade cujo owner mudou;
- unidade `placed` sem placement ativo correspondente;
- placement ativo cujo item não está `placed` naquela propriedade.

O painel Staff apenas inicia reparos idempotentes e concilia finanças consultando
as chaves bancárias existentes. Não existe ação de “aprovar dinheiro” manualmente.
