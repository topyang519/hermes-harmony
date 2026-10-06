/** Credentials stored with AssetStoreKit; preferences would store passwords in plaintext. */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';

export interface SecretKeys {
  gatewayUrl: string;
  gatewayPassword: string;
  cfId: string;
  cfSecret: string;
}

export interface SecretBag {
  gatewayUrl: string;
  password: string;
  cfId: string;
  cfSecret: string;
}

const KEYS: SecretKeys = {
  gatewayUrl: 'gateway_url',
  gatewayPassword: 'gateway_password',
  cfId: 'cf_access_client_id',
  cfSecret: 'cf_access_client_secret'
};

/** New installs pair with their own computer; existing saved connections still load. */
export const DEFAULT_GATEWAY_URL = '';

function validPort(port: string): boolean {
  if (!port) { return true; }
  if (!/^[0-9]{1,5}$/.test(port)) { return false; }
  const number = Number(port);
  return number > 0 && number <= 65535;
}

function validIpv4(host: string): number[] | null {
  const parts = host.split('.');
  if (parts.length !== 4) { return null; }
  const octets: number[] = [];
  for (let i = 0; i < parts.length; i++) {
    if (!/^(?:0|[1-9][0-9]{0,2})$/.test(parts[i])) { return null; }
    const octet = Number(parts[i]);
    if (octet > 255) { return null; }
    octets.push(octet);
  }
  return octets;
}

function validIpv6(host: string): boolean {
  if (!host || host.indexOf(':::') >= 0 || !/^[0-9a-fA-F:]+$/.test(host) || host.indexOf(':') < 0) { return false; }
  const compressedAt = host.indexOf('::');
  if (compressedAt >= 0 && host.indexOf('::', compressedAt + 2) >= 0) { return false; }
  const pieces = host.split(':');
  let units = 0;
  for (let i = 0; i < pieces.length; i++) {
    if (pieces[i].length === 0) { continue; }
    if (pieces[i].length > 4 || !/^[0-9a-fA-F]{1,4}$/.test(pieces[i])) { return false; }
    units++;
  }
  return compressedAt >= 0 ? units < 8 : units === 8;
}

function localAuthority(authority: string): boolean {
  let host = '';
  let port = '';
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']');
    if (close < 0) { return false; }
    host = authority.slice(1, close).toLowerCase();
    const suffix = authority.slice(close + 1);
    if (suffix.length > 0) {
      if (!suffix.startsWith(':') || suffix.length === 1) { return false; }
      port = suffix.slice(1);
    }
    if (!validPort(port) || !validIpv6(host)) { return false; }
    return host === '::1' || host.startsWith('fc') || host.startsWith('fd') ||
      host.startsWith('fe8') || host.startsWith('fe9') || host.startsWith('fea') || host.startsWith('feb');
  }

  const colon = authority.lastIndexOf(':');
  if (colon >= 0) {
    if (authority.indexOf(':') !== colon || colon === authority.length - 1) { return false; }
    host = authority.slice(0, colon).toLowerCase();
    port = authority.slice(colon + 1);
  } else {
    host = authority.toLowerCase();
  }
  if (!validPort(port)) { return false; }
  if (/^(?:localhost|(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+(?:localhost|local))$/.test(host)) {
    return true;
  }
  const octets = validIpv4(host);
  if (!octets) { return false; }
  return octets[0] === 10 || octets[0] === 127 ||
    (octets[0] === 172 && octets[1] >= 16 && octets[1] <= 31) ||
    (octets[0] === 192 && octets[1] === 168) ||
    (octets[0] === 169 && octets[1] === 254);
}

/** Accept supported bridge paths; plaintext sockets are restricted to local networks. */
export function isValidGatewayUrl(url: string): boolean {
  const match = /^(wss?):\/\/([^\s/?#@]+)\/(?:v2\/app|relay\/phone\/[a-f0-9]{32})$/.exec(url);
  if (!match) { return false; }
  return match[1] === 'wss' || localAuthority(match[2]);
}

function stringToUint8Array(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

function fromBytes(buf: Uint8Array): string {
  const decoder = util.TextDecoder.create('utf-8');
  return decoder.decodeToString(buf);
}

function secretFromMap(row: asset.AssetMap): string {
  const value: asset.Value | undefined = row.get(asset.Tag.SECRET);
  if (value === undefined) {
    return '';
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return '';
  }
  return fromBytes(value);
}

async function write(name: string, value: string): Promise<void> {
  const removeMap: asset.AssetMap = new Map();
  removeMap.set(asset.Tag.ALIAS, stringToUint8Array(name));
  try {
    await asset.remove(removeMap);
  } catch (_err) {
    // first write
  }
  // AssetStore requires SECRET to contain at least one byte. Empty optional
  // credentials are represented by the absence of an asset.
  if (value.length === 0) {
    return;
  }
  const addMap: asset.AssetMap = new Map();
  addMap.set(asset.Tag.ALIAS, stringToUint8Array(name));
  addMap.set(asset.Tag.SECRET, stringToUint8Array(value));
  addMap.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
  await asset.add(addMap);
}

async function read(name: string): Promise<string> {
  try {
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, stringToUint8Array(name));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    const result = await asset.query(query);
    if (result.length === 0) {
      return '';
    }
    return secretFromMap(result[0]);
  } catch (_err) {
    return '';
  }
}

export class Secrets {
  static async save(values: SecretBag): Promise<void> {
    await write(KEYS.gatewayUrl, values.gatewayUrl);
    await write(KEYS.gatewayPassword, values.password);
    await write(KEYS.cfId, values.cfId);
    await write(KEYS.cfSecret, values.cfSecret);
  }

  static async load(): Promise<SecretBag> {
    const storedUrl = await read(KEYS.gatewayUrl);
    const bag: SecretBag = {
      gatewayUrl: storedUrl.length > 0 ? storedUrl : DEFAULT_GATEWAY_URL,
      password: await read(KEYS.gatewayPassword),
      cfId: await read(KEYS.cfId),
      cfSecret: await read(KEYS.cfSecret)
    };
    return bag;
  }
}
