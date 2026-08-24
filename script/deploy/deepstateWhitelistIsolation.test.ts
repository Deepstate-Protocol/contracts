import {
  describe,
  expect,
  it,
  // eslint-disable-next-line import/no-unresolved
} from 'bun:test'

import deepstateConfig from '../../config/deepstate.json'
import networksConfig from '../../config/networks.json'
import whitelistConfig from '../../config/whitelist.json'
import { type IWhitelistConfig } from '../common/types'

interface ISharedWhitelistEntry {
  source: string
  address: string
}

const EVM_ADDRESS = /^0x[0-9a-fA-F]{40}$/
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

const engines = (deepstateConfig as { engines?: Record<string, string> })
  .engines
const whitelist = whitelistConfig as unknown as IWhitelistConfig

/**
 * Return every shared-whitelist entry that would authorize an address on a
 * network. An entry with no functions/selectors still grants approveTo access,
 * which also sets LibAllowList's legacy global contract permission.
 */
function sharedWhitelistEntries(network: string): ISharedWhitelistEntry[] {
  const entries: ISharedWhitelistEntry[] = []

  for (const dex of whitelist.DEXS)
    for (const contract of dex.contracts?.[network] ?? [])
      entries.push({ source: `DEXS.${dex.key}`, address: contract.address })

  for (const contract of whitelist.PERIPHERY?.[network] ?? [])
    entries.push({
      source: `PERIPHERY.${contract.name}`,
      address: contract.address,
    })

  return entries
}

describe('Deepstate engine shared-whitelist isolation', () => {
  it('configures at least one engine', () => {
    expect(Object.keys(engines ?? {}).length).toBeGreaterThan(0)
  })

  for (const [network, engine] of Object.entries(engines ?? {})) {
    it(`${network} binds a valid engine on a known network`, () => {
      expect(
        EVM_ADDRESS.test(engine),
        `${network} engine is not an EVM address`
      ).toBe(true)
      expect(
        engine.toLowerCase(),
        `${network} engine must not be zero`
      ).not.toBe(ZERO_ADDRESS)
      expect(
        Object.prototype.hasOwnProperty.call(networksConfig, network),
        `${network} is absent from config/networks.json`
      ).toBe(true)
    })

    it(`${network} engine is absent from the shared whitelist`, () => {
      const matches = sharedWhitelistEntries(network).filter(
        (entry) => entry.address.toLowerCase() === engine.toLowerCase()
      )

      expect(
        matches,
        `${engine} is private to DeepstateFacet; shared whitelist access also authorizes generic swap facets`
      ).toEqual([])
    })
  }
})
