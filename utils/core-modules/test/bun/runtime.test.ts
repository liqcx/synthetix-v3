import assert from 'assert/strict';
import hre from 'hardhat';

describe('the bun runtime hosts hardhat', function () {
  it('loaded the cannon plugin', function () {
    // hardhat.config.ts -> hardhat-cannon -> @usecannon/builder -> ses. Without
    // the ses patch this file never gets here: ses.cjs throws SES_NO_SLOPPY
    // while hardhat is loading, because bun drops its 'use strict' directive.
    assert.ok('cannon:build' in hre.tasks, 'hardhat-cannon did not register its tasks');
  });
});
