MZFurnitureConfig = nil
MZFurnitureLogic = nil

dofile('mz_furniture/shared/config.lua')
dofile('mz_furniture/shared/logic.lua')

local function expect(condition, message)
  if not condition then error(message, 2) end
end

expect(MZFurnitureLogic.IsItemTransitionAllowed('warehouse', 'placed'), 'warehouse -> placed must be allowed')
expect(MZFurnitureLogic.IsItemTransitionAllowed('placed', 'warehouse'), 'placed -> warehouse must be allowed')
expect(MZFurnitureLogic.IsItemTransitionAllowed('selling', 'sold'), 'selling -> sold must be allowed')
expect(not MZFurnitureLogic.IsItemTransitionAllowed('sold', 'warehouse'), 'sold item cannot return without recovery')
expect(not MZFurnitureLogic.IsItemTransitionAllowed('warehouse', 'sold'), 'warehouse cannot skip the selling state')

expect(MZFurnitureLogic.IsTransactionTransitionAllowed('pending', 'initiated'), 'pending -> initiated must be allowed')
expect(MZFurnitureLogic.IsTransactionTransitionAllowed('initiated', 'payment_pending'), 'initiated -> payment_pending must be allowed')
expect(MZFurnitureLogic.IsTransactionTransitionAllowed('payment_pending', 'money_removed'), 'payment_pending -> money_removed must be allowed')
expect(MZFurnitureLogic.IsTransactionTransitionAllowed('money_removed', 'committed'), 'money_removed -> committed must be allowed')
expect(MZFurnitureLogic.IsTransactionTransitionAllowed('committed', 'reversed'), 'committed -> reversed must be allowed')
expect(not MZFurnitureLogic.IsTransactionTransitionAllowed('failed', 'committed'), 'failed transaction is terminal')
expect(not MZFurnitureLogic.IsTransactionTransitionAllowed('pending', 'reversed'), 'pending cannot skip commit')

expect(MZFurnitureLogic.CanApplyRevision(7, 7), 'matching revisions must be accepted')
expect(not MZFurnitureLogic.CanApplyRevision(7, 6), 'stale revision must be rejected')

print('[mz_furniture][test] state machine harness passed')
