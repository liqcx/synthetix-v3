import { wei } from '@synthetixio/wei';
import { ethers } from 'ethers';

export const bn = (n: number) => wei(n).toBN();
export const toNum = (n: ethers.BigNumber) => Number(ethers.utils.formatEther(n));
