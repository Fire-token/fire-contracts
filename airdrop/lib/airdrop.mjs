/**
 * FIRE 에어드롭 Merkle 도구 공통 모듈 (generate.mjs / verify.mjs / fixture.mjs가 공유).
 *
 * - leaf 형식은 OpenZeppelin StandardMerkleTree ["address","uint256"]이며,
 *   FireMerkleDistributor.sol의 keccak256(bytes.concat(keccak256(abi.encode(account, amount))))와 같다.
 * - 같은 (주소, 수량) 집합이면 CSV 행 순서와 무관하게 항상 같은 root와 바이트 단위로 같은 출력 파일이 나온다.
 *   (주소 오름차순으로 정렬한 뒤 트리를 만들고, StandardMerkleTree도 leaf 해시를 정렬한다)
 * - 수량은 처음부터 끝까지 bigint(wei)로만 다루며 부동소수점을 쓰지 않는다.
 * - 수령자 정책: claim은 누구나 대신 제출할 수 있으므로(FireMerkleDistributor) 개인 키가 있을 수 없는 주소의 몫은 마감 전에
 *   그 주소로 보내져 영구히 사라진다. 그래서 FireBatchSender의 수령자 정책과 같은 예약 대역을 거부한다:
 *   0x0000…0000 ~ 0x0000…FFFF(0 주소·프리컴파일·0x…dEaD 등), 0x4200…0000 ~ 0x4200…FFFF(OP Stack·Base 프리디플로이).
 *   FIRE 토큰·베스팅·이전 회차 분배 컨트랙트·트레저리 같은 알려진 주소는 --deny 목록으로 거부한다.
 */
import { StandardMerkleTree } from '@openzeppelin/merkle-tree';
import {
  concat,
  encodeAbiParameters,
  formatUnits,
  getAddress,
  isAddress,
  keccak256,
  parseUnits,
  zeroAddress,
} from 'viem';

export const FIRE_DECIMALS = 18;
export const LEAF_ENCODING = Object.freeze(['address', 'uint256']);
export const CSV_HEADER = 'address,amount';
/** FIRE 총 발행량 1,000,000,000 FIRE (wei). 개별 수량과 합계의 상한으로 사용 */
export const MAX_SUPPLY_WEI = 1_000_000_000n * 10n ** 18n;
/** generate.mjs가 쓰는 출력 파일 이름 */
export const OUTPUT_FILES = Object.freeze(['tree.json', 'merkle.json', 'recipients.csv']);

const AMOUNT_PATTERN = /^[0-9]+(\.[0-9]+)?$/;
/** 예약 대역 (1): 0 주소·프리컴파일·하위 예약 대역의 마지막 주소 0x…FFFF (FireBatchSender와 같은 정책) */
const LAST_RESERVED_ADDRESS = 0xffffn;
/** 예약 대역 (2): OP Stack(Base) 프리디플로이 네임스페이스 0x4200…0000 ~ 0x4200…FFFF (WETH·L2ToL1MessagePasser 등) */
const OP_PREDEPLOY_NAMESPACE = 0x4200000000000000000000000000000000000000n >> 16n;
const ROUND_PATTERN = /^[1-9][0-9]{0,5}$/;
const WEI_PATTERN = /^[0-9]+$/;
const BYTES32_PATTERN = /^0x[0-9a-fA-F]{64}$/;

/** 입력값 검증 실패. code는 테스트·자동화용 식별자, line은 CSV 행 번호(1부터, 헤더 = 1행) */
export class AirdropInputError extends Error {
  constructor(code, message, line) {
    super(message);
    this.name = 'AirdropInputError';
    this.code = code;
    this.line = line;
  }
}

/**
 * FIRE 단위 10진 문자열 → wei(bigint). 소수점 이하 최대 18자리, 0 초과, 총 발행량 이하.
 * viem parseUnits는 18자리를 넘는 소수를 조용히 반올림하므로 자릿수를 먼저 직접 검사한다.
 */
export function parseFireAmount(text, label = 'amount') {
  const value = String(text ?? '').trim();
  if (!AMOUNT_PATTERN.test(value)) {
    throw new AirdropInputError(
      'AMOUNT_FORMAT',
      `${label} 형식 오류 "${value}": FIRE 단위 10진수만 허용 (예: 1500, 0.25). 부호·지수 표기·천 단위 구분 기호 불가`,
    );
  }
  const fraction = value.split('.')[1] ?? '';
  if (fraction.length > FIRE_DECIMALS) {
    throw new AirdropInputError(
      'AMOUNT_DECIMALS',
      `${label} "${value}": 소수점 이하 ${fraction.length}자리 (최대 ${FIRE_DECIMALS}자리)`,
    );
  }
  const wei = parseUnits(value, FIRE_DECIMALS);
  if (wei === 0n) {
    throw new AirdropInputError('AMOUNT_ZERO', `${label} "${value}": 0보다 커야 합니다`);
  }
  if (wei > MAX_SUPPLY_WEI) {
    throw new AirdropInputError(
      'AMOUNT_TOO_LARGE',
      `${label} "${value}": FIRE 총 발행량(1,000,000,000 FIRE)을 초과합니다`,
    );
  }
  return wei;
}

/**
 * 주소 형식·체크섬만 검증하고 EIP-55 체크섬 표기로 정규화 (수령자 정책은 보지 않음 → --deny 목록 등에 사용).
 * - 전부 소문자 또는 전부 대문자(체크섬 정보 없음)는 허용
 * - 대소문자가 섞인 주소는 EIP-55 체크섬이 정확히 맞아야 함 (오타 탐지)
 */
export function checksumAddress(text) {
  const value = String(text ?? '').trim();
  if (!isAddress(value, { strict: false })) {
    throw new AirdropInputError('ADDRESS_FORMAT', `주소 형식 오류 "${value}": 0x + 16진수 40자리여야 합니다`);
  }
  const hex = value.slice(2);
  const mixedCase = hex !== hex.toLowerCase() && hex !== hex.toUpperCase();
  const checksummed = getAddress(value);
  if (mixedCase && checksummed !== value) {
    // 올바른 체크섬 표기를 출력하지 않는다: 오타 난 주소의 "올바른 대소문자"를 알려주면 오타를 그대로 확정하게 됨
    throw new AirdropInputError(
      'ADDRESS_CHECKSUM',
      `EIP-55 체크섬 불일치 "${value}": 주소 오타일 가능성이 높습니다. 대소문자만 고치지 말고 원본 출처에서 주소를 다시 확인하십시오`,
    );
  }
  return checksummed;
}

/**
 * 수령자 주소 검증 후 EIP-55 체크섬 표기로 정규화.
 * - checksumAddress의 형식·체크섬 검사
 * - 0 주소 거부
 * - 예약 대역 거부 (개인 키가 있을 수 없어 누구나 대신 claim하면 그 몫이 영구히 사라지는 주소)
 */
export function normalizeAddress(text) {
  const checksummed = checksumAddress(text);
  if (checksummed === zeroAddress) {
    throw new AirdropInputError('ADDRESS_ZERO', '0 주소(0x0000…0000)는 수령자가 될 수 없습니다');
  }
  const value = BigInt(checksummed);
  if (value <= LAST_RESERVED_ADDRESS) {
    throw new AirdropInputError(
      'ADDRESS_RESERVED',
      `예약 대역 주소 ${checksummed}: 0x0000…0000 ~ 0x0000…FFFF(프리컴파일, 0x…dEaD 같은 소각용 주소 등)에는 개인 키가 없어 누구나 대신 claim하면 그 몫이 영구히 사라집니다`,
    );
  }
  if (value >> 16n === OP_PREDEPLOY_NAMESPACE) {
    throw new AirdropInputError(
      'ADDRESS_RESERVED',
      `예약 대역 주소 ${checksummed}: 0x4200…0000 ~ 0x4200…FFFF는 Base(OP Stack) 시스템 컨트랙트 대역입니다(WETH·L2ToL1MessagePasser 등). 보낸 FIRE가 동결되거나 사라집니다`,
    );
  }
  return checksummed;
}

/**
 * --deny 값(여러 번 지정 가능, 각 값은 쉼표로 구분한 주소 목록) → 체크섬 주소 Set.
 * 예약 대역은 이미 항상 거부되므로 여기서는 형식·체크섬만 본다.
 */
export function parseDenyList(values) {
  const deny = new Set();
  for (const value of values ?? []) {
    for (const item of String(value).split(',')) {
      if (item.trim() === '') continue;
      deny.add(checksumAddress(item));
    }
  }
  return deny;
}

/** 회차 번호: 1 이상의 정수 */
export function parseRound(text) {
  const value = String(text ?? '').trim();
  if (!ROUND_PATTERN.test(value)) {
    throw new AirdropInputError('ROUND_FORMAT', `--round "${value}": 1 이상의 정수여야 합니다`);
  }
  return Number(value);
}

function lineError(error, line) {
  if (!(error instanceof AirdropInputError)) throw error;
  return { line, code: error.code, message: error.message };
}

/**
 * 수령자 CSV 파싱 + 행 단위 검증. 첫 오류에서 멈추지 않고 모든 오류를 행 번호와 함께 모은다.
 * 형식: 1행 헤더 "address,amount", 이후 "주소,수량(FIRE)". UTF-8 BOM·CRLF·빈 줄은 허용.
 * @param {string} text
 * @param {{deny?: Set<string>}} [options] deny: 수령자가 될 수 없는 체크섬 주소 (FIRE 토큰·베스팅·트레저리 등)
 * @returns {{ entries: {line:number, address:string, amount:bigint}[], errors: {line:number, code:string, message:string}[] }}
 */
export function parseRecipientsCsv(text, { deny = new Set() } = {}) {
  const entries = [];
  const errors = [];
  const lines = String(text).replace(/^﻿/, '').split(/\r?\n/);
  const headerRaw = lines[0] ?? '';
  const header = headerRaw
    .split(',')
    .map((column) => column.trim().toLowerCase())
    .join(',');
  if (header !== CSV_HEADER) {
    errors.push({
      line: 1,
      code: 'HEADER',
      message: `헤더는 "${CSV_HEADER}" 이어야 합니다 (현재: "${headerRaw.trim()}")`,
    });
    return { entries, errors };
  }

  const firstLineByAddress = new Map();
  for (let index = 1; index < lines.length; index++) {
    const line = index + 1;
    const raw = lines[index];
    if (raw.trim() === '') continue;

    const columns = raw.split(',');
    if (columns.length !== 2) {
      errors.push({
        line,
        code: 'COLUMNS',
        message: `열 ${columns.length}개 "${raw.trim()}": "주소,수량" 2개 열이어야 합니다 (천 단위 쉼표·따옴표 금지)`,
      });
      continue;
    }

    let address;
    let amount;
    try {
      address = normalizeAddress(columns[0]);
    } catch (error) {
      errors.push(lineError(error, line));
    }
    if (address !== undefined && deny.has(address)) {
      errors.push({
        line,
        code: 'DENIED',
        message: `${address}: --deny 목록의 주소입니다 (FIRE 토큰·베스팅·분배 컨트랙트·트레저리 등은 수령자가 될 수 없음)`,
      });
      address = undefined;
    }
    try {
      amount = parseFireAmount(columns[1]);
    } catch (error) {
      errors.push(lineError(error, line));
    }

    // 중복은 대소문자를 무시하고 판정. 체크섬 오류가 난 행도 16진수 형식만 맞으면 중복 판정에 포함해
    // 한 번 실행으로 모든 문제를 보여준다.
    const rawAddress = columns[0].trim();
    if (isAddress(rawAddress, { strict: false })) {
      const key = rawAddress.toLowerCase();
      const firstLine = firstLineByAddress.get(key);
      if (firstLine !== undefined) {
        errors.push({
          line,
          code: 'DUPLICATE',
          message: `중복 주소 ${rawAddress}: ${firstLine}행과 같은 주소입니다 (대소문자 무시). 한 주소는 한 번만 올 수 있습니다`,
        });
        continue;
      }
      firstLineByAddress.set(key, line);
    }
    if (address !== undefined && amount !== undefined) entries.push({ line, address, amount });
  }

  if (entries.length === 0 && errors.length === 0) {
    errors.push({ line: 1, code: 'EMPTY', message: '수령자 행이 하나도 없습니다' });
  }
  return { entries, errors };
}

export function sumAmounts(entries) {
  return entries.reduce((total, entry) => total + entry.amount, 0n);
}

/** wei → FIRE 10진 문자열 (정확한 변환, 불필요한 0 제거) */
export function formatFire(wei) {
  return formatUnits(wei, FIRE_DECIMALS);
}

function compareAddresses(a, b) {
  const x = a.toLowerCase();
  const y = b.toLowerCase();
  return x < y ? -1 : x > y ? 1 : 0;
}

export function toJson(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

/** 공개용 recipients.csv. generate.mjs 입력 형식과 같으므로 누구나 이 파일로 같은 root를 재현할 수 있다 */
export function toRecipientsCsv(entries) {
  const sorted = [...entries].sort((a, b) => compareAddresses(a.address, b.address));
  return `${CSV_HEADER}\n${sorted.map((e) => `${e.address},${formatFire(e.amount)}\n`).join('')}`;
}

/**
 * Merkle 트리와 출력 파일 내용 생성.
 * @param {{address:string, amount:bigint}[]} entries 검증을 통과한 수령자 목록
 * @param {{round:number}} options
 */
export function buildAirdrop(entries, { round }) {
  if (!Number.isSafeInteger(round) || round < 1) throw new Error(`round must be a positive integer: ${round}`);
  if (entries.length === 0) throw new Error('수령자가 없습니다');

  const sorted = [...entries].sort((a, b) => compareAddresses(a.address, b.address));
  for (let i = 0; i < sorted.length; i++) {
    const { address, amount } = sorted[i];
    if (normalizeAddress(address) !== address) throw new Error(`주소가 체크섬 표기가 아닙니다: ${address}`);
    if (typeof amount !== 'bigint' || amount <= 0n) throw new Error(`잘못된 수량: ${address}`);
    if (i > 0 && compareAddresses(sorted[i - 1].address, address) === 0) throw new Error(`중복 주소: ${address}`);
  }

  const values = sorted.map(({ address, amount }) => [address, amount.toString()]);
  const tree = StandardMerkleTree.of(values, [...LEAF_ENCODING]);

  let total = 0n;
  const claims = {};
  for (const [index, [address, amount]] of tree.entries()) {
    claims[address] = { amount, proof: tree.getProof(index) };
    total += BigInt(amount);
  }
  if (total > MAX_SUPPLY_WEI) throw new Error('합계가 FIRE 총 발행량을 초과합니다');

  const merkle = {
    round,
    root: tree.root,
    total: total.toString(),
    totalFire: formatFire(total),
    count: values.length,
    claims,
  };
  return {
    tree,
    merkle,
    files: {
      'tree.json': toJson(tree.dump()),
      'merkle.json': toJson(merkle),
      'recipients.csv': toRecipientsCsv(sorted),
    },
  };
}

/** Solidity와 같은 방식(viem, OZ 라이브러리와 독립)으로 계산한 leaf 해시 */
export function leafHash(address, amount) {
  return keccak256(
    keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [address, BigInt(amount)])),
  );
}

/** OpenZeppelin MerkleProof.processProof와 같은 계산 (정렬된 쌍 keccak256) */
export function processProof(leaf, proof) {
  let computed = leaf;
  for (const sibling of proof) {
    if (!BYTES32_PATTERN.test(sibling)) throw new Error(`proof 원소 형식 오류: ${sibling}`);
    computed =
      BigInt(computed) < BigInt(sibling)
        ? keccak256(concat([computed, sibling]))
        : keccak256(concat([sibling, computed]));
  }
  return computed.toLowerCase();
}

/** 같은 종류의 불일치가 많을 때 오류 출력이 넘치지 않도록 앞부분만 개별 보고 */
const MAX_DETAILED_MISMATCHES = 20;

/**
 * recipients.csv 항목과 tree.json values를 주소·수량 단위로 전수 대조 (수령자 수·합계 포함).
 * @param {{line:number, address:string, amount:bigint}[]} entries recipients.csv 파싱 결과
 * @param {Map<string, bigint>} treeAmounts tree.json values (체크섬 주소 → wei)
 */
function compareRecipients(entries, treeAmounts, fail) {
  const report = (() => {
    let reported = 0;
    let suppressed = 0;
    return {
      add(message) {
        if (reported < MAX_DETAILED_MISMATCHES) {
          fail('RECIPIENTS_MISMATCH', message);
          reported++;
        } else {
          suppressed++;
        }
      },
      flush() {
        if (suppressed > 0) fail('RECIPIENTS_MISMATCH', `recipients.csv 불일치 ${suppressed}건 더 있음 (생략)`);
      },
    };
  })();

  const csvAmounts = new Map(entries.map((entry) => [entry.address, entry]));
  const csvTotal = sumAmounts(entries);
  let treeTotal = 0n;
  for (const amount of treeAmounts.values()) treeTotal += amount;
  if (entries.length !== treeAmounts.size) {
    report.add(`recipients.csv 수령자 ${entries.length}명 ≠ tree.json(merkle.json) ${treeAmounts.size}명`);
  }
  if (csvTotal !== treeTotal) {
    report.add(`recipients.csv 합계 ${formatFire(csvTotal)} FIRE ≠ tree.json(merkle.json) ${formatFire(treeTotal)} FIRE`);
  }
  for (const { line, address, amount } of entries) {
    const treeAmount = treeAmounts.get(address);
    if (treeAmount === undefined) {
      report.add(`recipients.csv ${line}행 ${address}: tree.json(merkle.json)에 없는 주소입니다`);
    } else if (treeAmount !== amount) {
      report.add(
        `recipients.csv ${line}행 ${address}: ${formatFire(amount)} FIRE ≠ tree.json(merkle.json) ${formatFire(treeAmount)} FIRE`,
      );
    }
  }
  for (const address of treeAmounts.keys()) {
    if (!csvAmounts.has(address)) report.add(`${address}: tree.json(merkle.json)에는 있지만 recipients.csv에 없습니다`);
  }
  report.flush();
}

/**
 * tree.json(StandardMerkleTree dump)과 merkle.json의 일관성을 전수 검증.
 * - tree.json을 다시 로드해 모든 내부 노드를 재계산하고(StandardMerkleTree.load → validate)
 * - 트리가 values만으로 이루어졌는지 확인한다: 노드 수 = 2 × values − 1, values만으로 다시 만든 트리와 노드 단위 일치.
 *   (load()는 values가 제자리에 있는지와 내부 노드 해시만 보므로, values에 없는 leaf를 root에 숨겨도 통과함.
 *    그런 숨은 leaf는 공개 목록에 없는데도 컨트랙트에서 청구할 수 있는 할당이 된다)
 * - 모든 수령자의 proof를 OZ 라이브러리와 독립 구현(Solidity 동일 알고리즘) 두 가지로 검증하며
 * - merkle.json의 root·total·totalFire·count·claims와 (있다면) recipients.csv를 주소·수량 단위로 전수 대조한다.
 * @returns {{errors: {code:string, message:string}[], root?:string, total?:bigint, count?:number, leafCount?:number, round?:number}}
 */
export function verifyAirdrop({ treeData, merkleData, recipientsText, expectedTotal, expectedRound, deny = new Set() }) {
  const errors = [];
  const fail = (code, message) => errors.push({ code, message });

  let tree;
  try {
    tree = StandardMerkleTree.load(treeData);
  } catch (error) {
    fail('TREE_INVALID', `tree.json 로드·재계산 실패: ${error.message}`);
    return { errors };
  }
  if (JSON.stringify(treeData.leafEncoding) !== JSON.stringify(LEAF_ENCODING)) {
    fail('LEAF_ENCODING', `tree.json leafEncoding이 ${JSON.stringify(LEAF_ENCODING)}가 아닙니다`);
    return { errors };
  }
  if (merkleData === null || typeof merkleData !== 'object' || Array.isArray(merkleData)) {
    fail('MERKLE_INVALID', 'merkle.json이 JSON 객체가 아닙니다');
    return { errors };
  }

  // 숨은 leaf 차단: 트리의 leaf는 정확히 values뿐이어야 한다
  const leafCount = (treeData.tree.length + 1) / 2;
  if (tree.length === 0) fail('TREE_EMPTY', 'tree.json values가 비어 있습니다 (수령자 없음)');
  if (treeData.tree.length !== 2 * tree.length - 1) {
    fail(
      'TREE_EXTRA_LEAVES',
      `tree.json 노드 ${treeData.tree.length}개 ≠ 2 × values ${tree.length}개 − 1: values에 없는 leaf가 트리에 들어 있습니다 ` +
        '(공개 목록에 없는 숨은 할당이 root에 포함됨)',
    );
  }
  if (tree.length > 0) {
    const rebuilt = StandardMerkleTree.of(
      treeData.values.map(({ value }) => value),
      [...LEAF_ENCODING],
    );
    if (rebuilt.root !== tree.root || JSON.stringify(rebuilt.dump().tree) !== JSON.stringify(treeData.tree)) {
      fail(
        'TREE_REBUILD_MISMATCH',
        `values만으로 다시 만든 트리(root ${rebuilt.root})가 tree.json(root ${tree.root})과 다릅니다 ` +
          '(목록에 없는 leaf가 있거나 generate.mjs가 만든 트리가 아님)',
      );
    }
  }

  const root = tree.root;
  if (String(merkleData.root).toLowerCase() !== root) {
    fail('ROOT_MISMATCH', `merkle.json root ${merkleData.root} ≠ tree.json root ${root}`);
  }

  const claims =
    merkleData.claims !== null && typeof merkleData.claims === 'object' && !Array.isArray(merkleData.claims)
      ? merkleData.claims
      : {};
  if (claims !== merkleData.claims) fail('MERKLE_INVALID', 'merkle.json claims가 객체가 아닙니다');

  const treeAddresses = new Set();
  const treeAmounts = new Map();
  let total = 0n;
  for (const [index, value] of tree.entries()) {
    const [address, amountText] = value;
    const where = `tree.json values[${index}] ${address}`;
    let checksummed;
    try {
      checksummed = normalizeAddress(address);
    } catch (error) {
      fail('TREE_ADDRESS', `${where}: ${error.message}`);
      continue;
    }
    if (checksummed !== address) fail('TREE_ADDRESS', `${where}: 체크섬 표기가 아닙니다`);
    if (deny.has(checksummed)) fail('TREE_DENIED', `${where}: --deny 목록의 주소입니다`);
    if (treeAddresses.has(checksummed)) fail('TREE_DUPLICATE', `${where}: 중복 주소`);
    treeAddresses.add(checksummed);

    if (typeof amountText !== 'string' || !WEI_PATTERN.test(amountText) || BigInt(amountText) === 0n) {
      fail('TREE_AMOUNT', `${where}: 수량은 0보다 큰 wei 10진 문자열이어야 합니다 (${amountText})`);
      continue;
    }
    const amount = BigInt(amountText);
    total += amount;
    treeAmounts.set(checksummed, amount);

    const claim = Object.hasOwn(claims, address) ? claims[address] : undefined;
    if (claim === undefined || claim === null || typeof claim !== 'object') {
      fail('CLAIM_MISSING', `${where}: merkle.json claims에 항목이 없습니다`);
      continue;
    }
    if (claim.amount !== amountText) {
      fail('CLAIM_AMOUNT', `${address}: merkle.json amount ${claim.amount} ≠ tree.json ${amountText}`);
    }
    const expectedProof = tree.getProof(index);
    const proof = Array.isArray(claim.proof) ? claim.proof : [];
    if (
      proof.length !== expectedProof.length ||
      proof.some((node, i) => typeof node !== 'string' || node.toLowerCase() !== expectedProof[i])
    ) {
      fail('CLAIM_PROOF', `${address}: merkle.json proof가 tree.json에서 계산한 proof와 다릅니다`);
    }
    try {
      if (!StandardMerkleTree.verify(root, [...LEAF_ENCODING], [address, amountText], proof)) {
        fail('PROOF_INVALID', `${address}: proof가 root에 대해 유효하지 않습니다 (OZ 라이브러리)`);
      }
      if (processProof(leafHash(address, amount), proof) !== root) {
        fail('PROOF_INVALID', `${address}: proof가 root에 대해 유효하지 않습니다 (Solidity 동일 계산)`);
      }
    } catch (error) {
      fail('PROOF_INVALID', `${address}: proof 검증 중 오류: ${error.message}`);
    }
  }

  for (const key of Object.keys(claims)) {
    if (!treeAddresses.has(key)) fail('CLAIM_EXTRA', `merkle.json claims에 트리에 없는 항목: ${key}`);
  }
  if (merkleData.count !== tree.length) {
    fail('COUNT_MISMATCH', `merkle.json count ${merkleData.count} ≠ 실제 수령자 수 ${tree.length}`);
  }
  if (merkleData.total !== total.toString()) {
    fail('TOTAL_MISMATCH', `merkle.json total ${merkleData.total} ≠ 실제 합계 ${total} wei`);
  }
  if (merkleData.totalFire !== formatFire(total)) {
    fail('TOTAL_FIRE_MISMATCH', `merkle.json totalFire ${merkleData.totalFire} ≠ 실제 합계 ${formatFire(total)} FIRE`);
  }
  if (!Number.isSafeInteger(merkleData.round) || merkleData.round < 1) {
    fail('ROUND_INVALID', `merkle.json round ${merkleData.round}: 1 이상의 정수여야 합니다`);
  }
  if (expectedRound !== undefined && merkleData.round !== expectedRound) {
    fail('ROUND_MISMATCH', `merkle.json round ${merkleData.round} ≠ 기대값 ${expectedRound}`);
  }
  if (expectedTotal !== undefined && total !== expectedTotal) {
    fail('EXPECTED_TOTAL_MISMATCH', `합계 ${formatFire(total)} FIRE ≠ 기대값 ${formatFire(expectedTotal)} FIRE`);
  }

  if (recipientsText !== undefined) {
    const parsed = parseRecipientsCsv(recipientsText, { deny });
    for (const error of parsed.errors) {
      fail('RECIPIENTS_INVALID', `recipients.csv ${error.line}행 [${error.code}] ${error.message}`);
    }
    if (parsed.errors.length === 0) {
      compareRecipients(parsed.entries, treeAmounts, fail);
      const rebuilt = buildAirdrop(parsed.entries, { round: 1 });
      if (rebuilt.merkle.root !== root) {
        fail('RECIPIENTS_MISMATCH', `recipients.csv로 다시 만든 root ${rebuilt.merkle.root} ≠ ${root}`);
      }
    }
  }

  return { errors, root, total, count: tree.length, leafCount, round: merkleData.round };
}
