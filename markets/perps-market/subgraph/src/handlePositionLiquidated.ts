import { BigInt } from '@graphprotocol/graph-ts';
import { PositionLiquidated as PositionLiquidatedEvent } from './generated/PerpsMarketProxy/PerpsMarketProxy';
import { Position, PositionLiquidated } from './generated/schema';

export function handlePositionLiquidated(event: PositionLiquidatedEvent): void {
  const id =
    event.params.marketId.toString() +
    '-' +
    event.params.accountId.toString() +
    '-' +
    event.block.number.toString();

  const positionLiquidated = new PositionLiquidated(id);

  positionLiquidated.accountId = event.params.accountId;
  positionLiquidated.timestamp = event.block.timestamp;
  positionLiquidated.marketId = event.params.marketId;
  positionLiquidated.amountLiquidated = event.params.amountLiquidated;
  positionLiquidated.currentPositionSize = event.params.currentPositionSize;

  positionLiquidated.save();

  // zero Position on full liquidation
  if (event.params.currentPositionSize.equals(BigInt.fromI32(0))) {
    const positionId = event.params.accountId.toString() + '-' + event.params.marketId.toString();

    let position = Position.load(positionId);
    if (position !== null) {
      position.size = BigInt.fromI32(0);
      position.isOpen = false;
      position.updatedAt = event.block.timestamp;
      position.save();
    }
  }
}
