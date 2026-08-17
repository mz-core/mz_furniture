# Fase 7 — rollout e rollback

Status: implementação concluída; validação dentro do FiveM pendente.

## Pré-requisitos

- backup das tabelas `mz_owned_furniture`, `mz_property_furniture` e
  `mz_furniture_transactions`;
- `mz_core`, `mz_interiors`, `mz_houses`, `mz_menu`, `mz_world_editor` e
  `mz_furniture` iniciados nessa ordem;
- pelo menos uma propriedade com `furniture=true` usando `shell_test`;
- dois personagens de teste e um Staff com `staff.furniture.recovery`.

## Smoke test obrigatório

1. O owner A compra dois móveis e coloca ambos na casa.
2. Um visitante entra e confirma que recebe o mesmo layout.
3. Staff troca o owner da casa de A para B.
4. As entidades desaparecem da instância e os dois itens voltam ao depósito de A.
5. A entra novamente, inclusive após reconnect, e encontra os itens no depósito.
6. B entra na casa e recebe snapshot vazio.
7. Repetir a mesma atribuição de owner não altera revisões nem duplica itens.
8. Reiniciar `mz_furniture` e executar `Recuperação e consistência` no `mz_admin`;
   todos os contadores devem ficar em zero.
9. Forçar uma compra/revenda ambígua somente em staging e confirmar que ela aparece
   em `manual_review`; a conciliação do jogador online deve consultar o banco antes
   de alterar o estado.

## Carga e observação

- testar uma propriedade com 100 móveis, que é o limite padrão;
- entrar com dois jogadores e observar criação em lotes, uso de CPU e tempo do
  snapshot;
- executar troca de owner e confirmar recolhimento único de todas as unidades;
- observar logs `furniture.owner_reconciled` e
  `furniture.consistency_reconciliation`;
- manter o job em lotes de até `OwnerReconciliationBatchSize=100` e intervalo
  mínimo efetivo de 60 segundos.

## Rollback seguro

1. Definir `OwnerReconciliationEnabled=false` para parar evento e job automático.
2. Reiniciar apenas `mz_furniture`.
3. Não apagar linhas de ownership, placement ou transação.
4. Manter compra/revenda bloqueadas se existir qualquer `manual_review`.
5. Corrigir a causa, reativar a flag e usar o painel Staff para uma nova varredura.

O rollback não recoloca automaticamente um layout antigo dentro da casa. Itens já
recolhidos permanecem, com segurança, no depósito do proprietário anterior.
